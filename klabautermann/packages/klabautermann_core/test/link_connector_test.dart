import 'dart:async';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/links/credential_source.dart';
import 'package:klabautermann_core/src/links/link_connector.dart';
import 'package:klabautermann_core/src/links/prompt_broker.dart';
import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        HostKey,
        HostKeyPrompter,
        InMemoryHostKeyStore,
        KeyboardInteractiveChallenge,
        KeyboardInteractiveResponder,
        ResolvedSshHost,
        ServerConfig,
        SshConnectException,
        SshConnectionLog,
        SshJumpHostResolver,
        SshLink,
        TofuVerifier;
import 'package:test/test.dart';

final class _FakeLink implements SshLink {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What the connector handed to one dial.
typedef _Dial = ({
  TofuVerifier tofu,
  HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  SshJumpHostResolver? resolveJumpHost,
});

ServerConfig _server({
  String id = 'ssh-config:web',
  String host = '192.0.2.10',
  int port = 22,
  AuthMethod authMethod = AuthMethod.agent,
  String? identityFilePath,
  String? jumpHostId,
}) => ServerConfig(
  id: id,
  label: id,
  host: host,
  port: port,
  username: 'me',
  authMethod: authMethod,
  identityFilePath: identityFilePath,
  jumpHostId: jumpHostId,
  createdAt: 0,
  updatedAt: 0,
);

ServerConfig _keyedHop() => _server(
  id: 'ssh-config-hop:gw',
  authMethod: AuthMethod.privateKey,
  identityFilePath: '~/.ssh/gw',
);

HostKey _key(String host, {String fingerprint = 'SHA256:first'}) => HostKey(
  host: host,
  type: 'ssh-ed25519',
  fingerprintSha256: fingerprint,
  pinnedAt: 0,
);

SshConnectException _connectError(Object cause) =>
    SshConnectException('failed', cause, SshConnectionLog());

LinkFailureKind? _failure(LinkConnectResult result) =>
    (result as LinkConnectFailed).failure;

void main() {
  late Directory temp;
  late List<EngineEvent> events;
  late InMemoryHostKeyStore pins;
  late List<_Dial> dials;
  late Future<SshLink> Function(_Dial dial) onDial;
  late Map<String, ServerConfig> hops;
  late PromptBroker broker;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('klab-connector-');
    events = [];
    pins = InMemoryHostKeyStore();
    dials = [];
    onDial = (_) async => _FakeLink();
    hops = {};
    broker = PromptBroker(emit: events.add);
  });

  tearDown(() => temp.delete(recursive: true));

  Future<LinkConnectResult> connect({
    ServerConfig? server,
    ConnectPurpose purpose = ConnectPurpose.background,
    bool realDial = false,
  }) => LinkConnector(
    credentials: EngineCredentialSource(
      identityAuditLogIn(temp.path),
      environment: {'HOME': temp.path},
      isMacOS: false,
    ),
    hostKeys: pins,
    prompts: broker,
    hopConfig: (id) => hops[id],
    dial: realDial
        ? SshLink.connect
        : ({
            required config,
            required credentials,
            required tofu,
            required onHostKey,
            onKeyboardInteractive,
            resolveJumpHost,
          }) {
            final dial = (
              tofu: tofu,
              onHostKey: onHostKey,
              onKeyboardInteractive: onKeyboardInteractive,
              resolveJumpHost: resolveJumpHost,
            );
            dials.add(dial);
            return onDial(dial);
          },
  ).connect(server ?? _server(), purpose: purpose);

  /// Dials that present [key] as `SshLink.connect` does (seance_core's
  /// `_verifyHostKey`): a pinned key passes, any other asks, an approved
  /// one is pinned, and a refusal ends the connect.
  void presenting(HostKey key) => onDial = (dial) async {
    final decision = await dial.tofu.check(key);
    if (decision.isTrusted) return _FakeLink();
    if (!await dial.onHostKey(decision)) {
      throw _connectError(Exception('host key'));
    }
    await dial.tofu.pin(key);
    return _FakeLink();
  };

  /// Answers the prompt the connect waits on, once it has been sent.
  Future<Prompt> answerNext(PromptAnswer answer) async {
    await pumpEventQueue();
    final prompt = events.whereType<Prompt>().last;
    expect(broker.answer(prompt.promptId, answer), PromptAnswerResult.answered);
    return prompt;
  }

  group('a background connect', () {
    test('declines a first-seen key without a prompt and offers no '
        'keyboard-interactive', () async {
      presenting(_key('192.0.2.10'));

      expect(_failure(await connect()), LinkFailureKind.hostKeyDeclined);
      expect(dials.single.onKeyboardInteractive, isNull);
      expect(events, isEmpty);
      expect(await pins.all(), isEmpty);
    });

    test('passes a key pinned in the injected store', () async {
      await pins.put(_key('192.0.2.10'));
      presenting(_key('192.0.2.10'));

      expect(await connect(), isA<LinkConnected>());
      expect(dials.single.tofu.store, same(pins));
    });
  });

  test('a changed key blocks the link without a prompt', () async {
    await pins.put(_key('192.0.2.10'));
    presenting(_key('192.0.2.10', fingerprint: 'SHA256:new'));

    for (final purpose in ConnectPurpose.values) {
      final result = await connect(purpose: purpose);
      expect(
        (result as LinkConnectBlocked).reason,
        LinkBlockedReason.hostKeyChanged,
      );
    }
    expect(events, isEmpty);
  });

  group('an interactive connect', () {
    test('asks about a first-seen key and pins it when trusted', () async {
      presenting(_key('198.51.100.1'));

      final result = connect(purpose: ConnectPurpose.interactive);
      final prompt = await answerNext(const PromptTrustAnswer(true));

      expect(await result, isA<LinkConnected>());
      expect(
        (prompt.serverId, prompt.host),
        ('ssh-config:web', '198.51.100.1'),
      );
      expect(
        (prompt.request as HostKeyPromptRequest).fingerprintSha256,
        'SHA256:first',
      );
      expect(await pins.get('198.51.100.1', 22), isNotNull);
    });

    test('fails as declined when the key is not trusted', () async {
      presenting(_key('192.0.2.10'));

      final result = connect(purpose: ConnectPurpose.interactive);
      await answerNext(const PromptTrustAnswer(false));

      expect(_failure(await result), LinkFailureKind.hostKeyDeclined);
      expect(await pins.all(), isEmpty);
    });

    test(
      'asks a keyboard-interactive challenge from the asking machine',
      () async {
        late List<String> responses;
        onDial = (dial) async {
          responses = await dial.onKeyboardInteractive!(
            KeyboardInteractiveChallenge(
              server: _server(host: '198.51.100.7', port: 2222),
              prompts: ['Code:'],
              name: 'otp',
              instruction: 'Enter the code',
            ),
          );
          return _FakeLink();
        };

        final result = connect(purpose: ConnectPurpose.interactive);
        final prompt = await answerNext(
          const PromptResponsesAnswer(['123456']),
        );

        expect(await result, isA<LinkConnected>());
        expect(responses, ['123456']);
        expect((prompt.host, prompt.port), ('198.51.100.7', 2222));
        final request = prompt.request as KeyboardInteractivePromptRequest;
        expect((request.name, request.instruction), ('otp', 'Enter the code'));
        expect(request.questions, ['Code:']);
      },
    );

    test('withdraws prompts still open when the attempt ends', () async {
      onDial = (dial) async {
        unawaited(dial.onHostKey(await dial.tofu.check(_key('192.0.2.10'))));
        await pumpEventQueue();
        throw _connectError(TimeoutException('handshake'));
      };

      final result = await connect(purpose: ConnectPurpose.interactive);

      expect(_failure(result), LinkFailureKind.timedOut);
      final [prompt as Prompt, withdrawn as PromptWithdrawn] = events;
      expect(withdrawn.promptId, prompt.promptId);
      expect(withdrawn.reason, PromptWithdrawnReason.attemptEnded);
    });
  });

  group('credentials', () {
    test('a key that cannot be read fails before dialing', () async {
      final result = await connect(
        server: _server(
          authMethod: AuthMethod.privateKey,
          identityFilePath: '~/.ssh/missing',
        ),
      );

      expect(_failure(result), LinkFailureKind.credentialUnavailable);
      expect(
        (result as LinkConnectFailed).identityFile,
        IdentityFileFailure.notFound,
      );
      expect(dials, isEmpty);
    });

    test('jump hops resolve through hopConfig with their own keys', () async {
      await Directory('${temp.path}/.ssh').create();
      await File('${temp.path}/.ssh/gw').writeAsString('gw key');
      hops['ssh-config-hop:gw'] = _keyedHop();
      late ResolvedSshHost? resolved;
      late ResolvedSshHost? unknown;
      onDial = (dial) async {
        resolved = await dial.resolveJumpHost!('ssh-config-hop:gw');
        unknown = await dial.resolveJumpHost!('ssh-config-hop:other');
        return _FakeLink();
      };

      await connect(server: _server(jumpHostId: 'ssh-config-hop:gw'));

      expect(resolved!.config.id, 'ssh-config-hop:gw');
      expect(resolved!.credentials.privateKeyPem, 'gw key');
      expect(unknown, isNull);
    });

    test('a hop key that cannot be read is a credential failure', () async {
      hops['ssh-config-hop:gw'] = _keyedHop();
      // seance_core wraps a resolver error in its connect exception.
      onDial = (dial) async {
        try {
          await dial.resolveJumpHost!('ssh-config-hop:gw');
        } on Exception catch (error) {
          throw _connectError(error);
        }
        return _FakeLink();
      };

      final result = await connect(
        server: _server(jumpHostId: 'ssh-config-hop:gw'),
      );

      expect(_failure(result), LinkFailureKind.credentialUnavailable);
      expect(
        (result as LinkConnectFailed).identityFile,
        IdentityFileFailure.notFound,
      );
    });
  });

  group('failure kinds', () {
    test('a refused port is unreachable through the real SshLink', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final result = await connect(
        // Password auth reads nothing before the socket opens.
        server: _server(
          host: InternetAddress.loopbackIPv4.address,
          port: port,
          authMethod: AuthMethod.password,
        ),
        realDial: true,
      );

      expect(_failure(result), LinkFailureKind.unreachable);
    });

    for (final (name, cause, kind) in [
      (
        'a connect timeout',
        const SocketException('timed out', osError: OSError('', 110)),
        LinkFailureKind.timedOut,
      ),
      (
        'a handshake timeout',
        TimeoutException('handshake'),
        LinkFailureKind.timedOut,
      ),
      ('anything else', Exception('auth failed'), null),
    ]) {
      test('$name is ${kind?.name ?? 'not classified'}', () async {
        onDial = (_) async => throw _connectError(cause);

        expect(_failure(await connect()), kind);
      });
    }
  });
}
