import 'dart:async';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/imported_fleet.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_entries.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_import_store.dart';
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
        Secret,
        SecretKind,
        ServerConfig,
        SshConnectException,
        SshConnectFailureKind,
        SshConnectionLog,
        SshCredentials,
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
  ServerConfig config,
  SshCredentials credentials,
  TofuVerifier tofu,
  HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  SshJumpHostResolver? resolveJumpHost,
});

ServerConfig _server({
  String id = 'ssh-config:web',
  String host = '192.0.2.10',
  int port = 22,
  String username = 'me',
  AuthMethod authMethod = AuthMethod.agent,
  String? identityFilePath,
  String? jumpHostId,
  String? secretRef,
}) => ServerConfig(
  id: id,
  label: id,
  host: host,
  port: port,
  username: username,
  authMethod: authMethod,
  identityFilePath: identityFilePath,
  jumpHostId: jumpHostId,
  secretRef: secretRef,
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

KeyboardInteractiveChallenge _challenge(List<String> questions) =>
    KeyboardInteractiveChallenge(
      server: _server(),
      prompts: questions,
      name: '',
      instruction: '',
    );

SshConnectException _connectError(
  Object cause, {
  SshConnectFailureKind kind = SshConnectFailureKind.other,
}) => SshConnectException('failed', cause, SshConnectionLog(), kind: kind);

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

  // The vault the connector reads and saves through.
  late Map<String, Secret> vault;
  late List<Secret> saved;
  late bool saveFails;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('klab-connector-');
    events = [];
    pins = InMemoryHostKeyStore();
    dials = [];
    onDial = (_) async => _FakeLink();
    hops = {};
    broker = PromptBroker(emit: events.add);
    vault = {};
    saved = [];
    saveFails = false;
  });

  tearDown(() => temp.delete(recursive: true));

  LinkConnector connector({
    bool realDial = false,
    ServerConfig? Function(String id)? hopConfig,
    Map<String, String> environment = const {},
    bool canSave = true,
  }) => LinkConnector(
    credentials: EngineCredentialSource(
      identityAuditLogIn(temp.path),
      vault: (ref) async => vault[ref],
      environment: {'HOME': temp.path, ...environment},
      isMacOS: false,
    ),
    hostKeys: pins,
    prompts: broker,
    hopConfig: hopConfig ?? (id) => hops[id],
    saveSecret: canSave
        ? (secret) async {
            if (saveFails) throw const FileSystemException('disk full');
            saved.add(secret);
          }
        : null,
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
              config: config,
              credentials: credentials,
              tofu: tofu,
              onHostKey: onHostKey,
              onKeyboardInteractive: onKeyboardInteractive,
              resolveJumpHost: resolveJumpHost,
            );
            dials.add(dial);
            return onDial(dial);
          },
  );

  Future<LinkConnectResult> connect({
    ServerConfig? server,
    ConnectPurpose purpose = ConnectPurpose.background,
    ChangedHostKey changedKey = ChangedHostKey.block,
    bool realDial = false,
    Map<String, String> environment = const {},
    void Function(LinkStatus phase)? onPhase,
    void Function()? onDialing,
    Future<void>? abandoned,
    bool canSave = true,
  }) =>
      connector(
        realDial: realDial,
        environment: environment,
        canSave: canSave,
      ).connect(
        server ?? _server(),
        purpose: purpose,
        changedKey: changedKey,
        onPhase: onPhase,
        onDialing: onDialing,
        abandoned: abandoned,
      );

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

  group('a review of a changed key (D61)', () {
    final changed = HostKey(
      host: '192.0.2.10',
      type: 'ecdsa-sha2-nistp256',
      fingerprintSha256: 'SHA256:new',
      pinnedAt: 0,
    );

    setUp(() async {
      await pins.put(_key('192.0.2.10'));
      presenting(changed);
    });

    test('asks with the pinned key beside the presented one, and trusting '
        'it re-pins', () async {
      final result = connect(
        purpose: ConnectPurpose.interactive,
        changedKey: ChangedHostKey.review,
      );
      final prompt = await answerNext(const PromptTrustAnswer(true));

      expect(await result, isA<LinkConnected>());
      final request = prompt.request as HostKeyPromptRequest;
      expect(
        (
          request.keyType,
          request.fingerprintSha256,
          request.pinnedKeyType,
          request.pinnedFingerprintSha256,
        ),
        ('ecdsa-sha2-nistp256', 'SHA256:new', 'ssh-ed25519', 'SHA256:first'),
      );
      expect(
        (await pins.get('192.0.2.10', 22))?.fingerprintSha256,
        'SHA256:new',
      );
    });

    test('a declined review blocks again and keeps the pin', () async {
      final result = connect(
        purpose: ConnectPurpose.interactive,
        changedKey: ChangedHostKey.review,
      );
      await answerNext(const PromptTrustAnswer(false));

      expect(
        (await result as LinkConnectBlocked).reason,
        LinkBlockedReason.hostKeyChanged,
      );
      expect(
        (await pins.get('192.0.2.10', 22))?.fingerprintSha256,
        'SHA256:first',
      );
    });

    test('an unattended connect never asks, even as a review', () async {
      final result = await connect(changedKey: ChangedHostKey.review);

      expect(
        (result as LinkConnectBlocked).reason,
        LinkBlockedReason.hostKeyChanged,
      );
      expect(events, isEmpty);
    });

    test('a first-seen key asks without a pinned key', () async {
      presenting(_key('198.51.100.1'));

      final result = connect(
        purpose: ConnectPurpose.interactive,
        changedKey: ChangedHostKey.review,
      );
      final prompt = await answerNext(const PromptTrustAnswer(true));

      expect(await result, isA<LinkConnected>());
      final request = prompt.request as HostKeyPromptRequest;
      expect(
        (request.pinnedFingerprintSha256, request.pinnedKeyType),
        (null, null),
      );
    });
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
      final request = prompt.request as HostKeyPromptRequest;
      expect(request.fingerprintSha256, 'SHA256:first');
      expect(request.pinnedFingerprintSha256, isNull, reason: 'first seen');
      expect(await pins.get('198.51.100.1', 22), isNotNull);
    });

    test('fails as declined when the key is not trusted', () async {
      presenting(_key('192.0.2.10'));

      final result = connect(purpose: ConnectPurpose.interactive);
      await answerNext(const PromptTrustAnswer(false));

      expect(_failure(await result), LinkFailureKind.hostKeyDeclined);
      expect(await pins.all(), isEmpty);
    });

    test('fails as declined when the key prompt expires', () async {
      broker = PromptBroker(emit: events.add, expiry: Duration.zero);
      presenting(_key('192.0.2.10'));

      final result = await connect(purpose: ConnectPurpose.interactive);

      expect(_failure(result), LinkFailureKind.hostKeyDeclined);
      expect(
        (events.last as PromptWithdrawn).reason,
        PromptWithdrawnReason.expired,
      );
    });

    test(
      'asks a keyboard-interactive challenge from the asking machine',
      () async {
        late List<String> responses;
        onDial = (dial) async {
          responses = await dial.onKeyboardInteractive!(
            KeyboardInteractiveChallenge(
              server: _server(
                host: '198.51.100.7',
                port: 2222,
                username: 'jump',
              ),
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
        // The asking machine's own user, not the server's.
        expect(request.user, 'jump');
        expect((request.name, request.instruction), ('otp', 'Enter the code'));
        expect(request.questions, ['Code:']);
      },
    );

    test('answers a round without questions without asking', () async {
      late List<String> responses;
      // OpenSSH's PAM backend ends a successful login with such a round.
      onDial = (dial) async {
        await dial.onKeyboardInteractive!(_challenge(['Password:']));
        responses = await dial.onKeyboardInteractive!(_challenge([]));
        return _FakeLink();
      };

      final result = connect(purpose: ConnectPurpose.interactive);
      await answerNext(const PromptResponsesAnswer(['secret']));
      await pumpEventQueue();

      expect(events.whereType<Prompt>(), hasLength(1));
      expect(await result, isA<LinkConnected>());
      expect(responses, isEmpty);
    });

    test('answers an expired challenge with no responses', () async {
      broker = PromptBroker(emit: events.add, expiry: Duration.zero);
      late List<String> responses;
      onDial = (dial) async {
        responses = await dial.onKeyboardInteractive!(_challenge(['Code:']));
        return _FakeLink();
      };

      await connect(purpose: ConnectPurpose.interactive);

      expect(responses, isEmpty);
      expect(events.last, isA<PromptWithdrawn>());
    });

    test('fails as cancelled at once when the user declines the '
        'questions', () async {
      late List<String> responses;
      // dartssh2 closes the connection on a count other than the
      // question count, so the dial fails.
      onDial = (dial) async {
        responses = await dial.onKeyboardInteractive!(_challenge(['Code:']));
        if (responses.isEmpty) throw _connectError(Exception('count'));
        return _FakeLink();
      };

      final result = connect(purpose: ConnectPurpose.interactive);
      await answerNext(const PromptCancelAnswer());

      expect(
        _failure(await result),
        LinkFailureKind.keyboardInteractiveCancelled,
      );
      expect(responses, isEmpty);
      // Answered: nothing was left to withdraw.
      expect(events.single, isA<Prompt>());
    });

    test('an expired challenge is no cancel', () async {
      broker = PromptBroker(emit: events.add, expiry: Duration.zero);
      onDial = (dial) async {
        await dial.onKeyboardInteractive!(_challenge(['Code:']));
        throw _connectError(Exception('count'));
      };

      final result = await connect(purpose: ConnectPurpose.interactive);

      expect(_failure(result), isNull);
    });

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

  group('phases', () {
    test('authenticating follows the server\'s own key, not a hop\'s, and '
        'an answered hop prompt goes back to connecting', () async {
      hops['ssh-config-hop:gw'] = _server(id: 'ssh-config-hop:gw');
      await pins.put(_key('192.0.2.10'));
      final phases = <LinkStatus>[];
      onDial = (dial) async {
        await dial.resolveJumpHost!('ssh-config-hop:gw');
        final hop = await dial.tofu.check(_key('198.51.100.1'));
        if (await dial.onHostKey(hop)) await dial.tofu.pin(hop.presented);
        await dial.tofu.check(_key('192.0.2.10'));
        return _FakeLink();
      };

      final result = connect(
        server: _server(jumpHostId: 'ssh-config-hop:gw'),
        purpose: ConnectPurpose.interactive,
        onPhase: phases.add,
      );
      final prompt = await answerNext(const PromptTrustAnswer(true));
      await result;

      expect(phases, [
        LinkNeedsUser(promptId: prompt.promptId, kind: PromptKind.hostKey),
        const LinkConnecting(),
        const LinkAuthenticating(),
      ]);
    });

    test('a pinned hop key leaves the attempt connecting', () async {
      hops['ssh-config-hop:gw'] = _server(id: 'ssh-config-hop:gw');
      await pins.put(_key('198.51.100.1'));
      await pins.put(_key('192.0.2.10'));
      final seen = <Object>[];
      onDial = (dial) async {
        await dial.resolveJumpHost!('ssh-config-hop:gw');
        await dial.tofu.check(_key('198.51.100.1'));
        seen.add('server key');
        await dial.tofu.check(_key('192.0.2.10'));
        return _FakeLink();
      };

      await connect(
        server: _server(jumpHostId: 'ssh-config-hop:gw'),
        onPhase: seen.add,
      );

      expect(seen, ['server key', const LinkAuthenticating()]);
    });

    test('a keyboard-interactive answer is reported and remembered', () async {
      await pins.put(_key('192.0.2.10'));
      final phases = <LinkStatus>[];
      onDial = (dial) async {
        await dial.tofu.check(_key('192.0.2.10'));
        await dial.onKeyboardInteractive!(_challenge(['Code:']));
        return _FakeLink();
      };

      final result = connect(
        purpose: ConnectPurpose.interactive,
        onPhase: phases.add,
      );
      final prompt = await answerNext(const PromptResponsesAnswer(['1']));

      expect((await result as LinkConnected).keyboardInteractive, isTrue);
      expect(phases, [
        const LinkAuthenticating(),
        LinkNeedsUser(
          promptId: prompt.promptId,
          kind: PromptKind.keyboardInteractive,
        ),
        const LinkAuthenticating(),
      ]);
    });

    test('onDialing hears once the route is resolved', () async {
      hops['ssh-config-hop:gw'] = _server(id: 'ssh-config-hop:gw');
      final seen = <String>[];
      onDial = (dial) async {
        seen.add('dial');
        if (dial.config.jumpHostId case final hop?) {
          await dial.resolveJumpHost!(hop);
          seen.add('route');
        }
        return _FakeLink();
      };

      await connect(onDialing: () => seen.add('dialing'));
      await connect(
        server: _server(jumpHostId: 'ssh-config-hop:gw'),
        onDialing: () => seen.add('dialing'),
      );

      expect(seen, ['dialing', 'dial', 'dial', 'dialing', 'route']);
    });
  });

  group('abandoned', () {
    test('withdraws the open prompt, so the attempt fails', () async {
      final abandon = Completer<void>();
      presenting(_key('192.0.2.10'));

      final result = connect(
        purpose: ConnectPurpose.interactive,
        abandoned: abandon.future,
      );
      await pumpEventQueue();
      abandon.complete();

      expect(_failure(await result), LinkFailureKind.hostKeyDeclined);
      expect(
        (events.last as PromptWithdrawn).reason,
        PromptWithdrawnReason.attemptEnded,
      );
    });

    test('while its key file is read, it never dials', () async {
      await Directory('${temp.path}/.ssh').create();
      await File('${temp.path}/.ssh/id').writeAsString('key');

      final result = await connect(
        server: _server(
          authMethod: AuthMethod.privateKey,
          identityFilePath: '~/.ssh/id',
        ),
        abandoned: Future.value(),
      );

      expect(result, isA<LinkConnectFailed>());
      expect(dials, isEmpty);
    });

    test('before its route resolves, it opens no socket', () async {
      final abandon = Completer<void>();
      hops['ssh-config-hop:gw'] = _server(id: 'ssh-config-hop:gw');
      ResolvedSshHost? hop;
      onDial = (dial) async {
        abandon.complete();
        await pumpEventQueue();
        hop = await dial.resolveJumpHost!('ssh-config-hop:gw');
        throw _connectError(StateError('Missing jump host'));
      };

      var dialing = false;
      await connect(
        server: _server(jumpHostId: 'ssh-config-hop:gw'),
        onDialing: () => dialing = true,
        abandoned: abandon.future,
      );

      expect(hop, isNull);
      expect(dialing, isFalse);
    });
  });

  group('a password the vault lacks (03 §4.5)', () {
    final passwordServer = _server(
      authMethod: AuthMethod.password,
      secretRef: 'secret-web',
    );

    test('is asked for on an interactive connect, dialed, and saved when '
        'the user says so', () async {
      final result = connect(
        server: passwordServer,
        purpose: ConnectPurpose.interactive,
      );
      final prompt = await answerNext(
        const PromptSecretAnswer('hunter2', save: true),
      );

      expect(await result, isA<LinkConnected>());
      final request = prompt.request as CredentialPromptRequest;
      expect((request.user, request.canSave), ('me', true));
      expect(dials.single.credentials.password, 'hunter2');
      expect(saved.single.id, 'secret-web');
      expect(saved.single.kind, SecretKind.password);
      expect(saved.single.value, 'hunter2');
    });

    test('is not saved unless the user says so', () async {
      final result = connect(
        server: passwordServer,
        purpose: ConnectPurpose.interactive,
      );
      await answerNext(const PromptSecretAnswer('hunter2'));

      expect(await result, isA<LinkConnected>());
      expect(saved, isEmpty);
    });

    test('is not saved when the server refuses it', () async {
      onDial = (_) async => throw _connectError(
        Exception('auth'),
        kind: SshConnectFailureKind.authenticationRejected,
      );
      final result = connect(
        server: passwordServer,
        purpose: ConnectPurpose.interactive,
      );
      await answerNext(const PromptSecretAnswer('wrong', save: true));

      expect(_failure(await result), LinkFailureKind.authenticationRejected);
      expect(saved, isEmpty);
    });

    test('a save that fails leaves the link standing', () async {
      saveFails = true;
      final result = connect(
        server: passwordServer,
        purpose: ConnectPurpose.interactive,
      );
      await answerNext(const PromptSecretAnswer('hunter2', save: true));

      expect(await result, isA<LinkConnected>());
    });

    test('offers no save for a server that names no vault entry, or '
        'without a vault to save to', () async {
      for (final (server, canSave) in [
        (_server(authMethod: AuthMethod.password), true),
        (passwordServer, false),
      ]) {
        final result = connect(
          server: server,
          purpose: ConnectPurpose.interactive,
          canSave: canSave,
        );
        final prompt = await answerNext(
          const PromptSecretAnswer('hunter2', save: true),
        );

        expect(await result, isA<LinkConnected>());
        expect((prompt.request as CredentialPromptRequest).canSave, isFalse);
      }
      expect(saved, isEmpty);
    });

    test('a stored password answers without a prompt', () async {
      vault['secret-web'] = const Secret(
        id: 'secret-web',
        kind: SecretKind.password,
        value: 'stored',
      );

      final result = await connect(
        server: passwordServer,
        purpose: ConnectPurpose.interactive,
      );

      expect(result, isA<LinkConnected>());
      expect(events.whereType<Prompt>(), isEmpty);
      expect(dials.single.credentials.password, 'stored');
    });

    test('a background connect never asks', () async {
      final result = await connect(server: passwordServer);

      expect(_failure(result), LinkFailureKind.credentialUnavailable);
      expect(events.whereType<Prompt>(), isEmpty);
      expect(dials, isEmpty);
    });

    test('a dismissed prompt fails before dialing', () async {
      final result = connect(
        server: passwordServer,
        purpose: ConnectPurpose.interactive,
      );
      await answerNext(const PromptSecretAnswer(null));

      expect(_failure(await result), LinkFailureKind.credentialUnavailable);
      expect(dials, isEmpty);
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

    group('inside the Flatpak sandbox', () {
      const flatpak = {'FLATPAK_ID': 'ch.lkmc.klabautermann'};

      test('a key file it hides is its own failure', () async {
        final result = await connect(
          server: _server(
            authMethod: AuthMethod.privateKey,
            identityFilePath: '~/.ssh/id_ed25519',
          ),
          environment: flatpak,
        );

        expect(_failure(result), LinkFailureKind.keyFileHiddenBySandbox);
        expect(
          (result as LinkConnectFailed).identityFile,
          IdentityFileFailure.sandboxDenied,
        );
        expect(dials, isEmpty);
      });

      test('so is a hop key file it hides', () async {
        hops['ssh-config-hop:gw'] = _keyedHop();
        onDial = (dial) async {
          try {
            await dial.resolveJumpHost!('ssh-config-hop:gw');
          } on Exception catch (error) {
            // seance_core types a resolver error as other; its cause says
            // what failed.
            throw _connectError(error);
          }
          return _FakeLink();
        };

        final result = await connect(
          server: _server(jumpHostId: 'ssh-config-hop:gw'),
          environment: flatpak,
        );

        expect(_failure(result), LinkFailureKind.keyFileHiddenBySandbox);
      });
    });
  });

  test('an ssh_config import reaches the dial through the store and '
      'ImportedFleet, each hop with its own key', () async {
    await Directory('${temp.path}/.ssh').create();
    await File('${temp.path}/.ssh/web').writeAsString('web key');
    await File('${temp.path}/.ssh/gw').writeAsString('gw key');
    final file = File('${temp.path}/$sshConfigImportsFileName');
    final imported = importedHostsFromSshConfig("""
Host web
  HostName 10.0.0.5
  User deploy
  IdentityFile ~/.ssh/web
  ProxyJump gw
Host gw
  HostName gw.example.com
  Port 2222
  User jump
  IdentityFile ~/.ssh/gw
""");
    final saved = await (await SshConfigImportStore.open(
      file,
    )).replace(imported.hosts, hops: imported.hops);
    expect(saved, isTrue);

    // What a restarted engine reads back.
    final store = await SshConfigImportStore.open(file);
    final fleet = ImportedFleet(
      store.hosts,
      hops: store.hops,
      localUser: 'me',
      detail: store.detail,
    );
    ResolvedSshHost? gw;
    onDial = (dial) async {
      gw = await dial.resolveJumpHost!(dial.config.jumpHostId!);
      return _FakeLink();
    };
    final result = await connector(hopConfig: fleet.serverConfig).connect(
      fleet.serverConfig('ssh-config:web')!,
      purpose: ConnectPurpose.background,
    );

    expect(result, isA<LinkConnected>());
    final web = dials.single.config;
    expect((web.host, web.port, web.username), ('10.0.0.5', 22, 'deploy'));
    expect(dials.single.credentials.privateKeyPem, 'web key');
    final hop = gw!.config;
    expect(
      (hop.id, hop.host, hop.port, hop.username),
      ('ssh-config-hop:gw', 'gw.example.com', 2222, 'jump'),
    );
    expect(gw!.credentials.privateKeyPem, 'gw key');
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
        'a connect timeout from Darwin',
        const SocketException('timed out', osError: OSError('', 60)),
        LinkFailureKind.timedOut,
      ),
      (
        'a handshake timeout',
        TimeoutException('handshake'),
        LinkFailureKind.timedOut,
      ),
      ('anything else', Exception('auth failed'), null),
    ]) {
      test('untyped, $name is ${kind?.name ?? 'not classified'}', () async {
        onDial = (_) async => throw _connectError(cause);

        expect(_failure(await connect()), kind);
      });
    }

    group('a typed connect failure', () {
      // Each cause alone would classify otherwise, or not at all, so only
      // the kind can give the expected failure.
      const refused = SocketException('Connection refused');
      final typed = <SshConnectFailureKind, (Object, LinkFailureKind?)>{
        SshConnectFailureKind.unreachable: (
          TimeoutException('connect'),
          LinkFailureKind.unreachable,
        ),
        SshConnectFailureKind.timedOut: (refused, LinkFailureKind.timedOut),
        SshConnectFailureKind.routeInvalid: (refused, null),
        SshConnectFailureKind.keyPassphraseRequired: (
          refused,
          LinkFailureKind.keyPassphraseRequired,
        ),
        SshConnectFailureKind.keyPassphraseWrong: (
          refused,
          LinkFailureKind.keyPassphraseRequired,
        ),
        SshConnectFailureKind.keyUnreadable: (
          refused,
          LinkFailureKind.credentialUnavailable,
        ),
        SshConnectFailureKind.agentEmpty: (
          refused,
          LinkFailureKind.credentialUnavailable,
        ),
        SshConnectFailureKind.authenticationRejected: (
          refused,
          LinkFailureKind.authenticationRejected,
        ),
        SshConnectFailureKind.hostKeyRefused: (refused, null),
        SshConnectFailureKind.unsupportedAlgorithm: (
          refused,
          LinkFailureKind.unsupportedAlgorithm,
        ),
        SshConnectFailureKind.insecureAlgorithmsOnly: (
          refused,
          LinkFailureKind.insecureAlgorithmsOnly,
        ),
        SshConnectFailureKind.keyExchangeTimedOut: (
          refused,
          LinkFailureKind.keyExchangeTimedOut,
        ),
      };

      test('covers every kind but other', () {
        expect(
          typed.keys.toSet(),
          SshConnectFailureKind.values.toSet()
            ..remove(SshConnectFailureKind.other),
        );
      });

      for (final MapEntry(key: kind, value: (cause, failure))
          in typed.entries) {
        test('${kind.name} is ${failure?.name ?? 'not classified'}, '
            'whatever its cause', () async {
          onDial = (_) async => throw _connectError(cause, kind: kind);

          expect(_failure(await connect()), failure);
        });
      }

      test('a host key the attempt declined keeps its verdict', () async {
        onDial = (dial) async {
          final decision = await dial.tofu.check(_key('192.0.2.10'));
          await dial.onHostKey(decision);
          throw _connectError(
            Exception('host key'),
            kind: SshConnectFailureKind.hostKeyRefused,
          );
        };

        expect(_failure(await connect()), LinkFailureKind.hostKeyDeclined);
      });

      test('a key file that holds no key fails before dialing, through the '
          'real SshLink', () async {
        final key = File('${temp.path}/.ssh/id_ed25519');
        await key.create(recursive: true);
        await key.writeAsString('not a key');

        final result = await connect(
          // A documentation address: the key is read before any socket.
          server: _server(
            authMethod: AuthMethod.privateKey,
            identityFilePath: '~/.ssh/id_ed25519',
          ),
          realDial: true,
        );

        expect(_failure(result), LinkFailureKind.credentialUnavailable);
        expect((result as LinkConnectFailed).identityFile, isNull);
      });
    });
  });
}
