import 'dart:async';
import 'dart:io' show SocketException;

import 'package:seance_core/seance_core.dart'
    show
        CredentialMissingException,
        CredentialResolver,
        CredentialSource,
        HostKeyDecision,
        HostKeyPrompter,
        HostKeyStore,
        HostKeyVerdict,
        KeyboardInteractiveResponder,
        ServerConfig,
        SshConnectException,
        SshCredentials,
        SshJumpHostResolver,
        SshLink,
        TofuVerifier;

import '../engine/protocol.dart';
import 'credential_source.dart';
import 'prompt_broker.dart';

/// The OS error codes of a connect that timed out: ETIMEDOUT as Linux
/// numbers it, and Windows' WSAETIMEDOUT. Dart's `Socket.connect` gives
/// its own timeout one of these two on every platform (`socket_patch.dart`
/// in the Dart SDK).
const Set<int> _connectTimedOutCodes = {110, 10060};

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
  const LinkConnected(this.link);

  final SshLink link;
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
/// the connect cap belong to the link supervisor above it.
final class LinkConnector {
  /// [hostKeys] holds the pins. Until the suite's file-backed host-key
  /// store lands (F3b), the engine passes an in-memory one, so pins last
  /// for the engine's lifetime only. `hopConfig` looks up a jump hop's
  /// config by id, such as `ImportedFleet.serverConfig`.
  LinkConnector({
    required CredentialSource credentials,
    required HostKeyStore hostKeys,
    required this._prompts,
    required this._hopConfig,
    this._dial = SshLink.connect,
  }) : _credentials = CredentialResolver(credentials),
       _tofu = TofuVerifier(hostKeys);

  final CredentialResolver _credentials;
  final TofuVerifier _tofu;
  final PromptBroker _prompts;
  final ServerConfig? Function(String id) _hopConfig;
  final LinkDialer _dial;

  /// Connects to [config], a fleet server's config, for [purpose].
  Future<LinkConnectResult> connect(
    ServerConfig config, {
    required ConnectPurpose purpose,
  }) async {
    final attempt = _prompts.attempt(config.id);
    final interactive = purpose == ConnectPurpose.interactive;

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
      return trusted;
    }

    try {
      final link = await _dial(
        config: config,
        credentials: await _credentials.resolve(config),
        tofu: _tofu,
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
                    name: challenge.name,
                    instruction: challenge.instruction,
                    questions: challenge.prompts,
                  ),
                );
                // A withdrawn prompt answers with no responses: dartssh2
                // rejects a count other than the question count by closing
                // the connection, so no made-up answer reaches the server.
                return answer is PromptResponsesAnswer
                    ? answer.responses
                    : const [];
              }
            : null,
        resolveJumpHost: _credentials.jumpHostResolver(
          (id) async => _hopConfig(id),
        ),
      );
      return LinkConnected(link);
    } on Exception catch (error) {
      return _classify(error, refused);
    } finally {
      attempt.end();
    }
  }

  static LinkConnectResult _classify(Exception error, HostKeyVerdict? refused) {
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

    // Jump-hop credential failures arrive wrapped, from the hop resolver.
    final cause = error is SshConnectException ? error.cause : error;
    return switch (cause) {
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
      // The handshake's and a jump hop forward's deadlines.
      TimeoutException() => LinkConnectFailed(
        error,
        failure: LinkFailureKind.timedOut,
      ),
      // What only seance_core can classify: a rejected credential, an
      // empty agent, the client limitations of 03 §5.3.
      _ => LinkConnectFailed(error),
    };
  }
}
