import 'dart:async';
import 'dart:io' show SocketException;

import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        CredentialDraft,
        CredentialMissingException,
        CredentialResolver,
        CredentialSource,
        HostKey,
        HostKeyDecision,
        HostKeyPrompter,
        HostKeyStore,
        HostKeyVerdict,
        KeyboardInteractiveResponder,
        ResolvedSshHost,
        Secret,
        SecretKind,
        ServerConfig,
        SshConnectException,
        SshConnectFailureKind,
        SshCredentials,
        SshJumpHostResolver,
        SshLink,
        TofuVerifier,
        privateKeyNeedsPassphrase;

import '../catalog/engine_vault.dart' show VaultUnavailableException;
import '../engine/protocol.dart';
import 'credential_source.dart';
import 'prompt_broker.dart';

/// The OS error codes of a connect that timed out: ETIMEDOUT as Linux (110)
/// and macOS or iOS (60) number it, and Windows' WSAETIMEDOUT (10060), as
/// seance_core classifies them. Dart's own connect timeout carries 110 or
/// 10060 on every platform (`socket_patch.dart` in the Dart SDK); one the
/// OS raises carries its own number.
const Set<int> _connectTimedOutCodes = {60, 110, 10060};

/// Who a connect is for, which decides whether it may ask the user.
enum ConnectPurpose {
  /// The user opened the server: a first-seen host key, a
  /// keyboard-interactive challenge, a missing password and an encrypted
  /// key's passphrase become [Prompt]s.
  interactive,

  /// Work the user did not start, such as background sampling (03 §4.5,
  /// §5.1): nothing prompts. A first-seen host key is declined,
  /// keyboard-interactive is not offered and an encrypted key without a
  /// stored passphrase stays closed, so a server that needs any of them
  /// fails and waits for the user.
  background,
}

/// What an interactive connect does with a host key other than the pinned
/// one (03 §4.6, D61). An unattended connect never asks either way.
enum ChangedHostKey {
  /// Refuse it, so the link is [LinkBlocked]: every connect but a review.
  block,

  /// Ask the user, with the pinned key beside the presented one; trusting
  /// it re-pins (`TofuVerifier.pin`). Only the user's connect to a server
  /// a changed key blocked reviews it.
  review,
}

/// [SshLink.connect] as the connector calls it; tests pass a fake.
typedef LinkDialer =
    Future<SshLink> Function({
      required ServerConfig config,
      required SshCredentials credentials,
      required TofuVerifier tofu,
      required HostKeyPrompter onHostKey,
      KeyboardInteractiveResponder? onKeyboardInteractive,
      SshJumpHostResolver? resolveJumpHost,
    });

/// How one [LinkConnector.connect] ended.
sealed class LinkConnectResult {
  const LinkConnectResult();
}

/// Connected and authenticated; the caller owns [link].
final class LinkConnected extends LinkConnectResult {
  const LinkConnected(this.link, {this.keyboardInteractive = false});

  final SshLink link;

  /// The server or a jump host asked keyboard-interactive questions the
  /// user answered, so a new connection would ask again: such a server
  /// gets one connection and is never redialed unattended (03 §4.5, §5.2;
  /// c2 R10).
  final bool keyboardInteractive;
}

/// The server, or a jump host on its route, presented a key other than
/// the pinned one (03 §4.6). The engine does not dial again until the user
/// decides, so the link is [LinkBlocked] with [reason].
final class LinkConnectBlocked extends LinkConnectResult {
  const LinkConnectBlocked(this.reason, this.error);

  final LinkBlockedReason reason;

  /// The error the attempt ended with, for logs; never sent to the app.
  final Object error;
}

/// The attempt failed. [failure] is what the connector could classify, or
/// null; [identityFile] says why a key file could not be read when that
/// is the failure.
final class LinkConnectFailed extends LinkConnectResult {
  const LinkConnectFailed(this.error, {this.failure, this.identityFile});

  /// The error the attempt ended with, for logs; never sent to the app.
  final Object error;
  final LinkFailureKind? failure;
  final IdentityFileFailure? identityFile;
}

/// Dials one server with [SshLink.connect] (03 §5.1): resolves its
/// credentials and its jump hops' through `CredentialResolver`, verifies
/// host keys with `TofuVerifier` over the pin store it is given, and asks
/// the user through the [PromptBroker] only on an interactive connect.
/// Each attempt's prompts are withdrawn when it ends. An interactive
/// connect to a password server whose password the vault lacks asks for
/// it, and keeps it in the vault when the user says so and the server
/// accepts it (03 §4.5). An interactive connect also asks for the
/// passphrase of each encrypted key on the route that none it has opens,
/// and keeps it for that attempt only (D70). A changed host key
/// blocks the link (03 §10.1) unless the connect reviews it
/// ([ChangedHostKey.review]). Reconnects, backoff and
/// the connect cap belong to the link supervisor above it, which hears
/// the attempt's phases through `onPhase` and gives it up through
/// `abandoned`.
final class LinkConnector {
  /// [hostKeys] holds the pins: the engine's one store, which
  /// `openHostKeyPins` opens and its sync shares (D61, D63, P14).
  /// `hopConfig` looks up a jump hop's config by id, such as
  /// `ImportedFleet.serverConfig`. [saveSecret] keeps a prompted password
  /// in the vault, `EngineVault.save`; without it no prompt offers to.
  LinkConnector({
    required CredentialSource credentials,
    required this._hostKeys,
    required this._prompts,
    required this._hopConfig,
    this._saveSecret,
    this._dial = SshLink.connect,
  }) : _credentials = CredentialResolver(credentials);

  final CredentialResolver _credentials;
  final Future<void> Function(Secret secret)? _saveSecret;
  final HostKeyStore _hostKeys;
  final PromptBroker _prompts;
  final ServerConfig? Function(String id) _hopConfig;
  final LinkDialer _dial;

  /// Connects to [config], a fleet server's config, for [purpose]. An
  /// interactive connect handles a changed host key as [changedKey] says.
  ///
  /// `SshLink.connect` shows no state before it returns, so [onPhase]
  /// hears the attempt's own: [LinkNeedsUser] once each prompt is out,
  /// [LinkAuthenticating] once the server's own host key has passed, and
  /// after an answered prompt [LinkAuthenticating], or [LinkConnecting]
  /// while a jump host asked. [onDialing] hears once that the route is
  /// resolved: the dial opens its first socket next. Once [abandoned]
  /// completes, prompts get no answer and an unresolved route opens no
  /// socket; a dial under way can still bring a link, for the caller to
  /// close.
  Future<LinkConnectResult> connect(
    ServerConfig config, {
    required ConnectPurpose purpose,
    ChangedHostKey changedKey = ChangedHostKey.block,
    void Function(LinkStatus phase)? onPhase,
    void Function()? onDialing,
    Future<void>? abandoned,
  }) async {
    final phase = onPhase ?? (_) {};
    final attempt = _prompts.attempt(
      config.id,
      onSent: (prompt) => phase(
        LinkNeedsUser(promptId: prompt.promptId, kind: prompt.request.kind),
      ),
    );
    final interactive = purpose == ConnectPurpose.interactive;
    final reviewsChangedKey =
        interactive && changedKey == ChangedHostKey.review;
    var gaveUp = false;
    unawaited(
      abandoned?.then((_) {
        gaveUp = true;
        attempt.end();
      }),
    );

    // seance_core resolves the whole route, then checks one host key per
    // hop in dial order, the server's last: the check after [hops] of
    // them is the server's own, after which its user authentication runs.
    var hops = 0;
    var checks = 0;
    LinkStatus progress() =>
        checks > hops ? const LinkAuthenticating() : const LinkConnecting();
    final tofu = _ReportingTofu(_hostKeys, (decision) {
      checks++;
      if (checks > hops && decision.isTrusted) phase(progress());
    });
    final resolveHop = _credentials.jumpHostResolver(
      (id) async => _hopConfig(id),
    );
    var answeredQuestions = false;

    // Whether the user declined keyboard-interactive questions: the
    // closed connection that follows says nothing of why.
    var cancelledQuestions = false;

    // The verdict of a host key the attempt refused, declined or expired:
    // only this tells a declined key from a changed one, which
    // SshConnectException's isHostKeyRefusal cannot.
    HostKeyVerdict? refused;
    Future<bool> onHostKey(HostKeyDecision decision) async {
      final presented = decision.presented;
      final asks = interactive && (!decision.isChanged || reviewsChangedKey);
      // A trusted answer pins the presented key: `SshLink.connect` calls
      // `TofuVerifier.pin`, which replaces a changed key's pin.
      final answer = asks
          ? await attempt.ask(
              host: presented.host,
              port: presented.port,
              request: HostKeyPromptRequest(
                keyType: presented.type,
                fingerprintSha256: presented.fingerprintSha256,
                pinnedFingerprintSha256: decision.isChanged
                    ? decision.pinned?.fingerprintSha256
                    : null,
                pinnedKeyType: decision.isChanged
                    ? decision.pinned?.type
                    : null,
              ),
            )
          : null;
      final trusted = answer is PromptTrustAnswer && answer.accepted;
      if (!trusted) refused ??= decision.verdict;
      if (trusted) phase(progress());
      return trusted;
    }

    // A password the user typed for this attempt, and whether to keep it.
    String? typedPassword;
    var savePassword = false;

    // The passphrases of this attempt's encrypted keys; only the user's
    // connect asks for them.
    final passphrases = interactive
        ? _KeyPassphrases(attempt, onAnswered: () => phase(progress()))
        : null;

    try {
      // A password server asks the user, on a connect they started, when it
      // names no vault entry or one this device lacks (03 §4.5).
      SshCredentials? credentials;
      final asksPassword =
          interactive && config.authMethod == AuthMethod.password;
      if (!asksPassword || config.secretRef != null) {
        try {
          credentials = await _credentials.resolve(config);
        } on CredentialMissingException {
          if (!asksPassword) rethrow;
        }
      }
      if (credentials == null) {
        final canSave = _saveSecret != null && config.secretRef != null;
        final answer = await attempt.ask(
          host: config.host,
          port: config.port,
          request: CredentialPromptRequest(
            user: config.username,
            canSave: canSave,
          ),
        );
        if (gaveUp) return LinkConnectFailed(_abandonedError);
        if (answer is! PromptSecretAnswer || (answer.secret ?? '').isEmpty) {
          return LinkConnectFailed(
            _noPasswordError,
            failure: LinkFailureKind.credentialUnavailable,
          );
        }
        typedPassword = answer.secret;
        savePassword = canSave && answer.save;
        phase(progress());
        credentials = await _credentials.resolve(
          config,
          draft: CredentialDraft(password: typedPassword),
        );
      }
      // Each turn dials once; only a key a passphrase did or did not open
      // brings another, which [_KeyPassphrases] decides. Keys are opened
      // before any socket, so a turn that ends that way reached no host.
      while (true) {
        hops = 0;
        checks = 0;
        final dialCredentials =
            await passphrases?.unlock(config, credentials) ?? credentials;
        if (gaveUp) return LinkConnectFailed(_abandonedError);
        if (config.jumpHostId == null) onDialing?.call();

        final SshLink link;
        try {
          link = await _dial(
            config: config,
            credentials: dialCredentials,
            tofu: tofu,
            onHostKey: onHostKey,
            onKeyboardInteractive: interactive
                ? (challenge) async {
                    // A round without questions, which OpenSSH's PAM backend
                    // sends to end a successful login, is answered without
                    // asking, as OpenSSH's client does. No event only shows
                    // text, so its name and instruction go unseen.
                    if (challenge.prompts.isEmpty) return const [];

                    final answer = await attempt.ask(
                      host: challenge.server.host,
                      port: challenge.server.port,
                      request: KeyboardInteractivePromptRequest(
                        user: challenge.server.username,
                        name: challenge.name,
                        instruction: challenge.instruction,
                        questions: challenge.prompts,
                      ),
                    );
                    // A withdrawn or cancelled prompt answers with no
                    // responses: dartssh2 rejects a count other than the
                    // question count by closing the connection, so no made-up
                    // answer reaches the server.
                    if (answer is PromptCancelAnswer) cancelledQuestions = true;
                    if (answer is! PromptResponsesAnswer) return const [];
                    answeredQuestions = true;
                    phase(progress());
                    return answer.responses;
                  }
                : null,
            resolveJumpHost: (id) async {
              final resolved = await resolveHop(id);
              // Hops resolve before any socket opens: an abandoned attempt
              // stops here, its route left incomplete, instead of dialing.
              if (gaveUp) return null;
              if (resolved == null) return null;
              final hop = passphrases == null
                  ? resolved
                  : ResolvedSshHost(
                      resolved.config,
                      await passphrases.unlock(
                        resolved.config,
                        resolved.credentials,
                      ),
                    );
              if (gaveUp) return null;
              hops++;
              // The first hop to dial ends the route.
              if (hop.config.jumpHostId == null) onDialing?.call();
              return hop;
            },
          );
        } on SshConnectException catch (error) {
          if (passphrases?.dialAgainAfter(error.kind) ?? false) continue;
          rethrow;
        }
        if (savePassword) await _save(config, typedPassword!);
        return LinkConnected(link, keyboardInteractive: answeredQuestions);
      }
    } on Exception catch (error) {
      return _classify(error, refused, cancelledQuestions: cancelledQuestions);
    } finally {
      // The callbacks above live on in the link's client, and with them
      // what this scope captured, so the passphrases go now (D70).
      passphrases?.forget();
      attempt.end();
    }
  }

  /// Keeps [password] as [config]'s vault entry. The link stands whether
  /// or not the save does: a failed save only means the next connect
  /// asks again.
  Future<void> _save(ServerConfig config, String password) async {
    try {
      await _saveSecret!(
        Secret(
          id: config.secretRef!,
          kind: SecretKind.password,
          value: password,
        ),
      );
    } on Object {
      // Saving is an offer, as in Poltergeist's prompt (02 §10).
    }
  }

  static LinkConnectResult _classify(
    Exception error,
    HostKeyVerdict? refused, {
    required bool cancelledQuestions,
  }) {
    switch (refused) {
      case HostKeyVerdict.changed:
        return LinkConnectBlocked(LinkBlockedReason.hostKeyChanged, error);
      case HostKeyVerdict.firstUse:
        return LinkConnectFailed(
          error,
          failure: LinkFailureKind.hostKeyDeclined,
        );
      case HostKeyVerdict.trusted || null:
        break;
    }

    // The user's refusal, as a declined host key is.
    if (cancelledQuestions) {
      return LinkConnectFailed(
        error,
        failure: LinkFailureKind.keyboardInteractiveCancelled,
      );
    }

    // seance_core says which step failed; its English summary is never
    // read.
    if (error is SshConnectException &&
        error.kind != SshConnectFailureKind.other) {
      return LinkConnectFailed(error, failure: _failureOf(error.kind));
    }

    // Untyped: a failure before the dial, such as the server's own key
    // file, or seance_core's `other`, whose cause is the error of a jump
    // hop's credential (the hop resolver's) or of a handshake that broke
    // off.
    final cause = error is SshConnectException ? error.cause : error;
    return switch (cause) {
      IdentityFileUnavailable(failure: IdentityFileFailure.sandboxDenied) =>
        LinkConnectFailed(
          error,
          failure: LinkFailureKind.keyFileHiddenBySandbox,
          identityFile: IdentityFileFailure.sandboxDenied,
        ),
      IdentityFileUnavailable(:final failure) => LinkConnectFailed(
        error,
        failure: LinkFailureKind.credentialUnavailable,
        identityFile: failure,
      ),
      // The user dismissed a passphrase prompt or let it expire.
      _PassphraseNotGiven() => LinkConnectFailed(
        error,
        failure: LinkFailureKind.keyPassphraseRequired,
      ),
      CredentialMissingException() ||
      VaultUnavailableException() => LinkConnectFailed(
        error,
        failure: LinkFailureKind.credentialUnavailable,
      ),
      SocketException(:final osError)
          when _connectTimedOutCodes.contains(osError?.errorCode) =>
        LinkConnectFailed(error, failure: LinkFailureKind.timedOut),
      SocketException() => LinkConnectFailed(
        error,
        failure: LinkFailureKind.unreachable,
      ),
      TimeoutException() => LinkConnectFailed(
        error,
        failure: LinkFailureKind.timedOut,
      ),
      // Not classified, among them an ssh-agent that could not be reached.
      _ => LinkConnectFailed(error),
    };
  }

  /// The failure behind a typed kind other than `other`, or null where
  /// none of [LinkFailureKind] names it.
  static LinkFailureKind? _failureOf(SshConnectFailureKind kind) =>
      switch (kind) {
        SshConnectFailureKind.unreachable => LinkFailureKind.unreachable,
        SshConnectFailureKind.timedOut => LinkFailureKind.timedOut,
        // The SSH service turned the connection away before the handshake
        // began, as a host or container still starting does: a redial may
        // reach it, as one after a refused connection may.
        SshConnectFailureKind.closedBeforeKeyExchange =>
          LinkFailureKind.unreachable,
        // A route the fleet's own configs cannot follow, or one given up
        // before it was resolved; nothing was dialed and nothing the user
        // can fix on the server.
        SshConnectFailureKind.routeInvalid => null,
        // One remedy for both, a passphrase that opens the key: an
        // interactive connect asks for it again with `retry` before it
        // gets here (D70), so either reaches the app only from an
        // unattended connect or a stored passphrase.
        SshConnectFailureKind.keyPassphraseRequired ||
        SshConnectFailureKind.keyPassphraseWrong =>
          LinkFailureKind.keyPassphraseRequired,
        SshConnectFailureKind.keyUnreadable ||
        SshConnectFailureKind.agentEmpty =>
          LinkFailureKind.credentialUnavailable,
        SshConnectFailureKind.authenticationRejected =>
          LinkFailureKind.authenticationRejected,
        // A host key the attempt declined has a verdict, which [_classify]
        // reads first; without one, a key-exchange signature did not
        // verify, which no failure kind names.
        SshConnectFailureKind.hostKeyRefused => null,
        // The client limitations of 03 §5.3, under the same names.
        SshConnectFailureKind.unsupportedAlgorithm =>
          LinkFailureKind.unsupportedAlgorithm,
        SshConnectFailureKind.insecureAlgorithmsOnly =>
          LinkFailureKind.insecureAlgorithmsOnly,
        SshConnectFailureKind.keyExchangeTimedOut =>
          LinkFailureKind.keyExchangeTimedOut,
        SshConnectFailureKind.other => null,
      };
}

/// What an attempt given up before it dialed fails with; nobody reads it.
final StateError _abandonedError = StateError('connect attempt abandoned');

/// What an attempt whose password prompt went unanswered fails with.
final StateError _noPasswordError = StateError('no password was entered');

/// The user dismissed a key passphrase prompt, or it expired or was
/// withdrawn. Thrown from a jump hop's resolver too, which seance_core
/// wraps as the cause of its connect exception.
final class _PassphraseNotGiven implements Exception {
  const _PassphraseNotGiven();

  @override
  String toString() => 'no key passphrase was entered';
}

/// The passphrases of one interactive connect's encrypted keys (03 §4.5,
/// D70), kept for that attempt only and dropped by [forget] when it ends.
/// Keys are told apart by their PEM text, so a key the server and a hop
/// share is asked for once.
///
/// seance_core opens every key of the route before it opens a socket, in
/// route order (the server's, then each hop's toward the first dialed),
/// and stops at the first that does not open, saying only whether that key
/// had a passphrase (`keyPassphraseWrong`) or none
/// (`keyPassphraseRequired`), not whose key it was. So each dial carries
/// at most one passphrase that has not opened its key yet, the trial, on
/// the first key that needs one, and keys after it get none. A wrong
/// passphrase is then the trial's, which is asked for again with `retry`;
/// a missing one means the trial opened its key, and the next dial tries
/// the next key.
final class _KeyPassphrases {
  _KeyPassphrases(this._attempt, {required this._onAnswered});

  final PromptAttempt _attempt;

  /// Called once the user has answered a prompt, so the attempt reports it
  /// goes on.
  final void Function() _onAnswered;

  /// The passphrase that opened each key, by the key's PEM.
  final Map<String, String> _opened = {};

  /// The one passphrase the current dial tries, and whether the user typed
  /// it or the vault held it.
  ({String pem, String passphrase, bool typed})? _trial;

  /// Keys whose stored passphrase did not open them, so the user is asked.
  final Set<String> _storedRefused = {};

  /// The key whose typed passphrase last did not open it.
  String? _typedRefused;

  /// [credentials] for the host [config] names, with the passphrase this
  /// dial gives its key. Asks the user when the key is encrypted, no
  /// passphrase of this attempt has opened it and it is the dial's first
  /// such key; throws [_PassphraseNotGiven] when the prompt gets no
  /// passphrase.
  Future<SshCredentials> unlock(
    ServerConfig config,
    SshCredentials credentials,
  ) async {
    if (credentials.method != AuthMethod.privateKey) return credentials;
    final pem = credentials.privateKeyPem ?? '';
    if (!privateKeyNeedsPassphrase(pem)) return credentials;

    final opened = _opened[pem];
    if (opened != null) return _withPassphrase(credentials, opened);

    // A later key that is the trial's own takes the trial's passphrase:
    // it opens after the trial's, so a wrong one still fails there first.
    final trial = _trial;
    if (trial != null) {
      return _withPassphrase(
        credentials,
        trial.pem == pem ? trial.passphrase : null,
      );
    }

    final stored = credentials.keyPassphrase;
    if (stored != null && !_storedRefused.contains(pem)) {
      _trial = (pem: pem, passphrase: stored, typed: false);
      return credentials;
    }

    final answer = await _attempt.ask(
      host: config.host,
      port: config.port,
      request: KeyPassphrasePromptRequest(
        user: config.username,
        keyPath: config.identityFilePath,
        retry: pem == _typedRefused,
      ),
    );
    final passphrase = answer is PromptSecretAnswer ? answer.secret : null;
    if (passphrase == null || passphrase.isEmpty) {
      throw const _PassphraseNotGiven();
    }

    _onAnswered();
    _trial = (pem: pem, passphrase: passphrase, typed: true);
    return _withPassphrase(credentials, passphrase);
  }

  /// Reads a dial's failure of [kind]: true when it is the trial's verdict,
  /// so another dial gets further, and false for anything else.
  bool dialAgainAfter(SshConnectFailureKind kind) {
    final trial = _trial;
    _trial = null;
    if (trial == null) return false;

    switch (kind) {
      case SshConnectFailureKind.keyPassphraseWrong:
        if (trial.typed) {
          _typedRefused = trial.pem;
        } else {
          _storedRefused.add(trial.pem);
        }
        return true;
      case SshConnectFailureKind.keyPassphraseRequired:
        _opened[trial.pem] = trial.passphrase;
        return true;
      default:
        return false;
    }
  }

  /// Drops every passphrase and key this attempt held.
  void forget() {
    _opened.clear();
    _trial = null;
    _storedRefused.clear();
    _typedRefused = null;
  }

  static SshCredentials _withPassphrase(
    SshCredentials credentials,
    String? passphrase,
  ) => SshCredentials.privateKey(
    credentials.privateKeyPem,
    keyPassphrase: passphrase,
  );
}

/// A [TofuVerifier] that reports each check's decision, so the connector
/// can tell when the server's own key has passed.
final class _ReportingTofu extends TofuVerifier {
  _ReportingTofu(super.store, this._onChecked);

  final void Function(HostKeyDecision decision) _onChecked;

  @override
  Future<HostKeyDecision> check(HostKey presented) async {
    final decision = await super.check(presented);
    _onChecked(decision);
    return decision;
  }
}
