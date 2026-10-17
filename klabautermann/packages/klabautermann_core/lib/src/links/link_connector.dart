import 'dart:async';
import 'dart:io' show SocketException;

import 'package:seance_core/seance_core.dart'
    show
        CredentialMissingException,
        CredentialResolver,
        CredentialSource,
        HostKey,
        HostKeyDecision,
        HostKeyPrompter,
        HostKeyStore,
        HostKeyVerdict,
        KeyboardInteractiveResponder,
        ServerConfig,
        SshConnectException,
        SshConnectFailureKind,
        SshCredentials,
        SshJumpHostResolver,
        SshLink,
        TofuVerifier;

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
  /// The user opened the server: a first-seen host key and a
  /// keyboard-interactive challenge become [Prompt]s.
  interactive,

  /// Work the user did not start, such as background sampling (03 §4.5,
  /// §5.1): nothing prompts. A first-seen host key is declined and
  /// keyboard-interactive is not offered, so a server that needs either
  /// fails and waits for the user.
  background,
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
/// Each attempt's prompts are withdrawn when it ends. A changed host key
/// never prompts: it blocks the link (03 §10.1). Reconnects, backoff and
/// the connect cap belong to the link supervisor above it, which hears
/// the attempt's phases through `onPhase` and gives it up through
/// `abandoned`.
final class LinkConnector {
  /// [hostKeys] holds the pins. Until the suite's file-backed host-key
  /// store lands (F3b), the engine passes an in-memory one, so pins last
  /// for the engine's lifetime only. `hopConfig` looks up a jump hop's
  /// config by id, such as `ImportedFleet.serverConfig`.
  LinkConnector({
    required CredentialSource credentials,
    required this._hostKeys,
    required this._prompts,
    required this._hopConfig,
    this._dial = SshLink.connect,
  }) : _credentials = CredentialResolver(credentials);

  final CredentialResolver _credentials;
  final HostKeyStore _hostKeys;
  final PromptBroker _prompts;
  final ServerConfig? Function(String id) _hopConfig;
  final LinkDialer _dial;

  /// Connects to [config], a fleet server's config, for [purpose].
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
      final answer = decision.isChanged || !interactive
          ? null
          : await attempt.ask(
              host: presented.host,
              port: presented.port,
              request: HostKeyPromptRequest(
                keyType: presented.type,
                fingerprintSha256: presented.fingerprintSha256,
              ),
            );
      final trusted = answer is PromptTrustAnswer && answer.accepted;
      if (!trusted) refused ??= decision.verdict;
      if (trusted) phase(progress());
      return trusted;
    }

    try {
      final credentials = await _credentials.resolve(config);
      if (gaveUp) return LinkConnectFailed(_abandonedError);
      if (config.jumpHostId == null) onDialing?.call();

      final link = await _dial(
        config: config,
        credentials: credentials,
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
          final hop = await resolveHop(id);
          // Hops resolve before any socket opens: an abandoned attempt
          // stops here, its route left incomplete, instead of dialing.
          if (gaveUp) return null;
          if (hop == null) return null;
          hops++;
          // The first hop to dial ends the route.
          if (hop.config.jumpHostId == null) onDialing?.call();
          return hop;
        },
      );
      return LinkConnected(link, keyboardInteractive: answeredQuestions);
    } on Exception catch (error) {
      return _classify(error, refused, cancelledQuestions: cancelledQuestions);
    } finally {
      attempt.end();
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
      CredentialMissingException() => LinkConnectFailed(
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
      // The client limitations of 03 §5.3 wait for seance_core to type
      // them.
      _ => LinkConnectFailed(error),
    };
  }

  /// The failure behind a typed kind other than `other`, or null where
  /// none of [LinkFailureKind] names it.
  static LinkFailureKind? _failureOf(SshConnectFailureKind kind) =>
      switch (kind) {
        SshConnectFailureKind.unreachable => LinkFailureKind.unreachable,
        SshConnectFailureKind.timedOut => LinkFailureKind.timedOut,
        // A route the fleet's own configs cannot follow, or one given up
        // before it was resolved; nothing was dialed and nothing the user
        // can fix on the server.
        SshConnectFailureKind.routeInvalid => null,
        // One remedy for both, a passphrase that opens the key. Until the
        // passphrase prompt (K45b) the app words it as loading the key
        // into an agent; the prompt can then say a retry, as the password
        // prompt does.
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
        SshConnectFailureKind.other => null,
      };
}

/// What an attempt given up before it dialed fails with; nobody reads it.
final StateError _abandonedError = StateError('connect attempt abandoned');

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
