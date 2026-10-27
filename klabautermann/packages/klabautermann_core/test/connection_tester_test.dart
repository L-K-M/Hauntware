import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/links/connection_tester.dart';
import 'package:klabautermann_core/src/links/prompt_broker.dart';
import 'package:seance_core/seance_core.dart'
    show
        AuthKind,
        AuthMethod,
        CredentialDraft,
        CredentialSource,
        HostKey,
        HostKeyDecision,
        HostKeyPrompter,
        HostKeyStore,
        InMemoryHostKeyStore,
        KeyboardInteractiveChallenge,
        KeyboardInteractiveResponder,
        Secret,
        SecretKind,
        ServerConfig,
        SshConnectionLog,
        SshCredentials,
        SshJumpHostResolver,
        TofuVerifier;
import 'package:test/test.dart';

/// A vault of [secrets] and no key files.
final class _Credentials implements CredentialSource {
  _Credentials(this.secrets);

  final Map<String, Secret> secrets;

  @override
  Future<Secret?> storedSecret(String secretRef) async => secrets[secretRef];

  @override
  Future<String> identityFile(ServerConfig config, CredentialDraft? draft) =>
      throw StateError('no key files here');
}

ServerConfig _server({
  AuthMethod authMethod = AuthMethod.password,
  String? secretRef = 'secret-1',
}) => ServerConfig(
  id: 'draft-1',
  label: 'web',
  host: '192.0.2.10',
  port: 22,
  username: 'me',
  authMethod: authMethod,
  secretRef: secretRef,
  createdAt: 0,
  updatedAt: 0,
);

final _key = HostKey(
  host: '192.0.2.10',
  type: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:presented',
  pinnedAt: 0,
);

void main() {
  late List<EngineEvent> events;
  late PromptBroker broker;
  late InMemoryHostKeyStore pins;

  // What the fake sign-in was handed, and what it does.
  late List<SshCredentials> signedIn;
  late Future<AuthKind> Function({
    required HostKeyStore hostKeys,
    required HostKeyPrompter onHostKey,
    required KeyboardInteractiveResponder onKeyboardInteractive,
  })
  onSignIn;

  ConnectionTester tester({Map<String, Secret> secrets = const {}}) =>
      ConnectionTester(
        credentials: _Credentials(secrets),
        hostKeys: pins,
        prompts: broker,
        hopConfig: (_) => null,
        authenticator:
            ({
              required HostKeyStore hostKeys,
              required HostKeyPrompter onHostKey,
              required KeyboardInteractiveResponder onKeyboardInteractive,
              required SshJumpHostResolver resolveJumpHost,
            }) {
              Future<AuthKind> authenticate(
                ServerConfig config,
                SshCredentials credentials,
                SshConnectionLog log,
              ) {
                signedIn.add(credentials);
                return onSignIn(
                  hostKeys: hostKeys,
                  onHostKey: onHostKey,
                  onKeyboardInteractive: onKeyboardInteractive,
                );
              }

              return authenticate;
            },
      );

  /// The next prompt the tester sends, once it is out.
  Future<Prompt> nextPrompt() async {
    while (true) {
      await pumpEventQueue();
      for (final event in events) {
        if (event is Prompt) {
          events.remove(event);
          return event;
        }
      }
    }
  }

  setUp(() {
    events = [];
    broker = PromptBroker(emit: events.add);
    pins = InMemoryHostKeyStore();
    signedIn = [];
    onSignIn = ({
      required HostKeyStore hostKeys,
      required HostKeyPrompter onHostKey,
      required KeyboardInteractiveResponder onKeyboardInteractive,
    }) async => AuthKind.storedPassword;
  });

  test('a typed password outranks the stored one, and a blank box falls '
      'back to it', () async {
    final secrets = {
      'secret-1': const Secret(
        id: 'secret-1',
        kind: SecretKind.password,
        value: 'stored',
      ),
    };

    final typed = await tester(secrets: secrets)
        .test(_server(), const CredentialDraft(password: 'typed'));
    final blank = await tester(secrets: secrets)
        .test(_server(), const CredentialDraft(password: ''));

    expect(typed.ok, isTrue);
    expect(typed.summary, contains('me@192.0.2.10:22'));
    expect(blank.ok, isTrue);
    expect([for (final c in signedIn) c.password], ['typed', 'stored']);
  });

  test('a first-seen key is asked about under the draft\'s id, and the '
      'answer decides', () async {
    late bool trusted;
    onSignIn =
        ({
          required HostKeyStore hostKeys,
          required HostKeyPrompter onHostKey,
          required KeyboardInteractiveResponder onKeyboardInteractive,
        }) async {
          final tofu = TofuVerifier(hostKeys);
          trusted = await onHostKey(await tofu.check(_key));
          if (!trusted) throw StateError('host key refused');
          return AuthKind.storedPassword;
        };

    final result = tester().test(
      _server(),
      const CredentialDraft(password: 'typed'),
    );
    final prompt = await nextPrompt();
    expect(prompt.serverId, 'draft-1');
    final request = prompt.request as HostKeyPromptRequest;
    expect(request.fingerprintSha256, 'SHA256:presented');
    expect(request.pinnedFingerprintSha256, isNull);
    broker.answer(prompt.promptId, const PromptTrustAnswer(false));

    final report = await result;
    expect(trusted, isFalse);
    expect(report.ok, isFalse);
    expect(report.log, contains('host key refused'));
  });

  test('a changed key is asked about with the pinned one beside it', () async {
    final pinned = HostKey(
      host: _key.host,
      type: 'ssh-rsa',
      fingerprintSha256: 'SHA256:pinned',
      pinnedAt: 0,
    );
    await pins.put(pinned);
    onSignIn =
        ({
          required HostKeyStore hostKeys,
          required HostKeyPrompter onHostKey,
          required KeyboardInteractiveResponder onKeyboardInteractive,
        }) async {
          final HostKeyDecision decision = await TofuVerifier(hostKeys)
              .check(_key);
          await onHostKey(decision);
          return AuthKind.storedPassword;
        };

    final result = tester().test(
      _server(),
      const CredentialDraft(password: 'typed'),
    );
    final prompt = await nextPrompt();
    final request = prompt.request as HostKeyPromptRequest;
    expect(request.pinnedFingerprintSha256, 'SHA256:pinned');
    expect(request.pinnedKeyType, 'ssh-rsa');
    broker.answer(prompt.promptId, const PromptTrustAnswer(true));

    expect((await result).ok, isTrue);
  });

  test('keyboard-interactive questions are asked, and the prompts end with '
      'the test', () async {
    late List<String> responses;
    final unanswered = Completer<void>();
    onSignIn =
        ({
          required HostKeyStore hostKeys,
          required HostKeyPrompter onHostKey,
          required KeyboardInteractiveResponder onKeyboardInteractive,
        }) async {
          responses = await onKeyboardInteractive(
            KeyboardInteractiveChallenge(
              server: _server(),
              prompts: const ['Code: '],
              name: '',
              instruction: '',
            ),
          );
          // A second question nobody answers before the test ends.
          unawaited(
            onHostKey(await TofuVerifier(hostKeys).check(_key))
                .whenComplete(unanswered.complete),
          );
          await pumpEventQueue();
          return AuthKind.keyboardInteractive;
        };

    final result = tester().test(
      _server(),
      const CredentialDraft(password: 'typed'),
    );
    final question = await nextPrompt();
    final request = question.request as KeyboardInteractivePromptRequest;
    expect(request.questions, ['Code: ']);
    broker.answer(question.promptId, const PromptResponsesAnswer(['123456']));

    expect((await result).ok, isTrue);
    expect(responses, ['123456']);
    await unanswered.future;
    expect(events.whereType<PromptWithdrawn>(), hasLength(1));
  });

  test('a credential that cannot be read is a failed report', () async {
    final report = await tester().test(
      _server(
        authMethod: AuthMethod.privateKey,
        secretRef: null,
      ).copyWith(identityFilePath: '~/.ssh/missing'),
      const CredentialDraft(),
    );

    expect(report.ok, isFalse);
    expect(signedIn, isEmpty);
  });
}
