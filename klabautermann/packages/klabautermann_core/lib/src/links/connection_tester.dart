import 'package:seance_core/seance_core.dart'
    show
        ConnectionTestResult,
        CredentialDraft,
        CredentialResolver,
        CredentialSource,
        HostAuthenticator,
        HostKeyDecision,
        HostKeyPrompter,
        HostKeyStore,
        KeyboardInteractiveResponder,
        ServerConfig,
        SshJumpHostResolver,
        liveHostAuthenticator,
        runConnectionTest;

import '../engine/protocol.dart';
import 'prompt_broker.dart';

/// Builds the sign-in a test runs; tests pass a fake.
typedef TestAuthenticatorFactory =
    HostAuthenticator Function({
      required HostKeyStore hostKeys,
      required HostKeyPrompter onHostKey,
      required KeyboardInteractiveResponder onKeyboardInteractive,
      required SshJumpHostResolver resolveJumpHost,
    });

/// The server editor's Test connection (FL-03, M5 plan M09b): seance_core's
/// `runConnectionTest` over the engine's credentials, pins and prompts, as
/// Séance's and Poltergeist's editors run it. `liveHostAuthenticator`
/// wraps the pins in an `UnpinnedHostKeyStore`, so a key the user trusts
/// holds for the attempt only: the form may still be cancelled or the host
/// retyped, and the first real connect asks again.
final class ConnectionTester {
  /// [hostKeys], [prompts] and `hopConfig` are the link connector's, so a
  /// test asks and verifies as a connect does.
  ConnectionTester({
    required CredentialSource credentials,
    required this._hostKeys,
    required this._prompts,
    required this._hopConfig,
    this._authenticator = liveTestAuthenticator,
  }) : _credentials = CredentialResolver(credentials);

  final CredentialResolver _credentials;
  final HostKeyStore _hostKeys;
  final PromptBroker _prompts;
  final ServerConfig? Function(String id) _hopConfig;
  final TestAuthenticatorFactory _authenticator;

  /// Tries [config] with [draft]'s typed credential, whose blank boxes fall
  /// back to the vault entry [config] names. Every failure, a declined
  /// prompt included, is a report; the prompts end with the attempt.
  Future<ConnectionTestResult> test(
    ServerConfig config,
    CredentialDraft draft,
  ) async {
    final attempt = _prompts.attempt(config.id);
    try {
      return await _run(config, draft, attempt);
    } on Object catch (error) {
      // runConnectionTest reports what it sees; anything past it still
      // answers the editor, which would otherwise wait forever.
      return ConnectionTestResult(ok: false, summary: '$error', log: '');
    } finally {
      attempt.end();
    }
  }

  Future<ConnectionTestResult> _run(
    ServerConfig config,
    CredentialDraft draft,
    PromptAttempt attempt,
  ) => runConnectionTest(
    config: config,
    credentials: () => _credentials.resolve(config, draft: draft),
    authenticate: _authenticator(
      hostKeys: _hostKeys,
      onHostKey: (decision) => _askHostKey(attempt, decision),
      onKeyboardInteractive: (challenge) async {
        // A round without questions ends a PAM login, as in a connect.
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
        return answer is PromptResponsesAnswer ? answer.responses : const [];
      },
      resolveJumpHost: _credentials.jumpHostResolver(
        (id) async => _hopConfig(id),
      ),
    ),
  );

  /// Asks about every key the test meets, a changed one with the pinned
  /// key beside it: a test reviews nothing for good, so asking is safe.
  static Future<bool> _askHostKey(
    PromptAttempt attempt,
    HostKeyDecision decision,
  ) async {
    final presented = decision.presented;
    final answer = await attempt.ask(
      host: presented.host,
      port: presented.port,
      request: HostKeyPromptRequest(
        keyType: presented.type,
        fingerprintSha256: presented.fingerprintSha256,
        pinnedFingerprintSha256: decision.isChanged
            ? decision.pinned?.fingerprintSha256
            : null,
        pinnedKeyType: decision.isChanged ? decision.pinned?.type : null,
      ),
    );
    return answer is PromptTrustAnswer && answer.accepted;
  }
}

/// The real sign-in: seance_core's `liveHostAuthenticator`.
HostAuthenticator liveTestAuthenticator({
  required HostKeyStore hostKeys,
  required HostKeyPrompter onHostKey,
  required KeyboardInteractiveResponder onKeyboardInteractive,
  required SshJumpHostResolver resolveJumpHost,
}) => liveHostAuthenticator(
  hostKeys: hostKeys,
  onHostKey: onHostKey,
  onKeyboardInteractive: onKeyboardInteractive,
  resolveJumpHost: resolveJumpHost,
);
