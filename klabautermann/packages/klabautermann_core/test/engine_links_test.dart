import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:klabautermann_core/src/links/link_connector.dart';
import 'package:seance_core/seance_core.dart'
    show
        HostKey,
        HostKeyPrompter,
        KeyboardInteractiveResponder,
        ServerConfig,
        SshConnectException,
        SshConnectionLog,
        SshCredentials,
        SshJumpHostResolver,
        SshLink,
        SshLinkReady,
        SshLinkSeen,
        SshLinkState,
        TofuVerifier;
import 'package:test/test.dart';

const _web = 'ssh-config:web';
const _webConfig = 'Host web\n  HostName 192.0.2.10\n  User me\n';
const _otherConfig = 'Host other\n  HostName 192.0.2.11\n  User me\n';

/// A [LinkState] of [serverId] with [status].
Matcher _state(LinkStatus status, {String serverId = _web}) => isA<LinkState>()
    .having((event) => event.serverId, 'serverId', serverId)
    .having((event) => event.status, 'status', status);

final _connecting = _state(const LinkConnecting());
final _authenticating = _state(const LinkAuthenticating());
final _ready = _state(const LinkReady());

/// What the engine's connector handed one dial.
typedef _Dial = ({
  ServerConfig config,
  TofuVerifier tofu,
  HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
});

final class _Link implements SshLink {
  int closes = 0;

  @override
  Stream<SshLinkState> get states =>
      Stream.value(const SshLinkReady(SshLinkSeen()));

  @override
  Future<void> close() async => closes++;

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// The engine run in this isolate rather than spawned, so a test holds
/// the links its fake dial hands out. It is never sent [Shutdown], whose
/// `Isolate.exit` would end the test isolate; its port dies with it.
final class _Engine {
  _Engine._(this._commands, this._messages);

  final SendPort _commands;
  final StreamIterator<Object?> _messages;

  static Future<_Engine> start(
    String supportDirectory, {
    required bool linksEnabled,
    required LinkDialer dial,
  }) async {
    final port = ReceivePort();
    final messages = StreamIterator<Object?>(port);
    addTearDown(port.close);
    engineMain(
      EngineStart(
        uiPort: port.sendPort,
        supportDirectory: supportDirectory,
        linksEnabled: linksEnabled,
      ),
      dial: dial,
    );
    expect(await messages.moveNext(), isTrue);
    final engine = _Engine._(messages.current as SendPort, messages)
      ..send(const Hello());
    expect(await engine.next(), isA<EngineReady>());
    expect(await engine.next(), isA<CatalogReplaced>());
    return engine;
  }

  void send(EngineRequest request) => _commands.send(request);

  Future<EngineEvent> next() async {
    final arrived = await _messages.moveNext().timeout(
      const Duration(seconds: 5),
    );
    expect(arrived, isTrue);
    return _messages.current as EngineEvent;
  }

  /// Imports [config] and returns the fleet's server ids.
  Future<List<String>> import(String config) async {
    send(ImportSshConfig(config));
    final fleet = await next() as CatalogReplaced;
    expect(await next(), isA<SshConfigImported>());
    return [for (final entry in fleet.entries) entry.serverId];
  }

  /// The name of the request the next event rejects.
  Future<String> rejected() async =>
      (await next() as RequestRejected).requestName;
}

void main() {
  late Directory support;
  late List<_Dial> dials;
  late List<_Link> links;

  setUp(() {
    support = Directory.systemTemp.createTempSync('klab-engine-links-');
    dials = [];
    links = [];
  });

  tearDown(() => support.deleteSync(recursive: true));

  /// Dials as `SshLink.connect` does with a first-seen key: a pinned key
  /// passes, any other asks, a trusted one is pinned, and a refusal ends
  /// the connect.
  Future<SshLink> dial({
    required ServerConfig config,
    required SshCredentials credentials,
    required TofuVerifier tofu,
    required HostKeyPrompter onHostKey,
    KeyboardInteractiveResponder? onKeyboardInteractive,
    SshJumpHostResolver? resolveJumpHost,
  }) async {
    dials.add((
      config: config,
      tofu: tofu,
      onHostKey: onHostKey,
      onKeyboardInteractive: onKeyboardInteractive,
    ));
    final key = HostKey(
      host: config.host,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:web',
      pinnedAt: 0,
    );
    final decision = await tofu.check(key);
    if (!decision.isTrusted) {
      if (!await onHostKey(decision)) {
        throw SshConnectException(
          'declined',
          Exception('key'),
          SshConnectionLog(),
        );
      }
      await tofu.pin(key);
    }
    final link = _Link();
    links.add(link);
    return link;
  }

  Future<_Engine> startEngine({bool linksEnabled = true}) =>
      _Engine.start(support.path, linksEnabled: linksEnabled, dial: dial);

  /// Connects web from its host-key prompt to a ready link.
  Future<void> connectWeb(_Engine engine) async {
    engine.send(const Connect(_web));
    expect(await engine.next(), _connecting);
    final prompt = await engine.next() as Prompt;
    expect(
      await engine.next(),
      _state(
        LinkNeedsUser(promptId: prompt.promptId, kind: PromptKind.hostKey),
      ),
    );
    engine.send(AnswerPrompt(prompt.promptId, const PromptTrustAnswer(true)));
    expect(await engine.next(), _authenticating);
    expect(await engine.next(), _ready);
  }

  test('with links off, Connect is rejected and nothing dials', () async {
    final engine = await startEngine(linksEnabled: false);
    await engine.import(_webConfig);

    engine
      ..send(const Connect(_web))
      ..send(const Disconnect(_web))
      ..send(const SetAppActivity(AppActivity.background))
      ..send(const AnswerPrompt('p1', PromptTrustAnswer(true)));

    // Disconnect and SetAppActivity change nothing and get no answer.
    expect(await engine.rejected(), 'Connect');
    expect(await engine.rejected(), 'AnswerPrompt');
    expect(dials, isEmpty);
  });

  test('Connect dials the fleet server as the user\'s connect, and its '
      'prompt is answered through AnswerPrompt', () async {
    final engine = await startEngine();
    await engine.import(_webConfig);

    engine.send(const Connect(_web));
    expect(await engine.next(), _connecting);
    final prompt = await engine.next() as Prompt;
    expect(
      (prompt.serverId, prompt.host, prompt.port),
      (_web, '192.0.2.10', 22),
    );
    expect(prompt.request, isA<HostKeyPromptRequest>());
    expect(await engine.next(), isA<LinkState>());

    // Answers that open no prompt, or do not fit it, are refused.
    engine
      ..send(const AnswerPrompt('p1', PromptTrustAnswer(true)))
      ..send(AnswerPrompt(prompt.promptId, const PromptResponsesAnswer([])))
      ..send(AnswerPrompt(prompt.promptId, const PromptTrustAnswer(true)));
    expect(await engine.rejected(), 'AnswerPrompt');
    expect(await engine.rejected(), 'AnswerPrompt');
    expect(await engine.next(), _authenticating);
    expect(await engine.next(), _ready);

    final dialed = dials.single;
    expect((dialed.config.host, dialed.config.username), ('192.0.2.10', 'me'));
    expect(dialed.onKeyboardInteractive, isNotNull, reason: 'interactive');
  });

  test('Connect for a server outside the fleet is rejected', () async {
    final engine = await startEngine();
    await engine.import(_webConfig);

    engine.send(const Connect('ssh-config:gone'));
    expect(await engine.rejected(), 'Connect');
    expect(dials, isEmpty);
  });

  test('Disconnect closes the link', () async {
    final engine = await startEngine();
    await engine.import(_webConfig);
    await connectWeb(engine);

    engine.send(const Disconnect(_web));
    expect(
      await engine.next(),
      _state(const LinkClosed(LinkClosedReason.closedByOwner)),
    );
    expect(links.single.closes, 1);
  });

  test('SetAppActivity reaches the supervisor: no attempt starts in the '
      'background', () async {
    final engine = await startEngine();
    await engine.import(_webConfig);

    engine
      ..send(const SetAppActivity(AppActivity.background))
      ..send(const Connect(_web))
      // Answered after the engine handled the Connect.
      ..send(const Connect('ssh-config:gone'));
    expect(await engine.next(), _connecting);
    expect(await engine.rejected(), 'Connect');
    await pumpEventQueue();
    expect(dials, isEmpty);

    engine.send(const SetAppActivity(AppActivity.foreground));
    expect(await engine.next(), isA<Prompt>());
    expect(dials, hasLength(1));
  });

  group('a server that leaves the fleet (03 §5.1)', () {
    test('loses its link without a LinkState, and connects anew when it '
        'comes back, its pin kept', () async {
      final engine = await startEngine();
      await engine.import(_webConfig);
      await connectWeb(engine);

      expect(await engine.import(_otherConfig), ['ssh-config:other']);
      expect(links.single.closes, 1);
      engine.send(const Connect(_web));
      expect(await engine.rejected(), 'Connect');

      await engine.import(_webConfig);
      engine.send(const Connect(_web));
      // The pin made by the first connect still holds: no prompt.
      expect(await engine.next(), _connecting);
      expect(await engine.next(), _authenticating);
      expect(await engine.next(), _ready);
      expect(dials, hasLength(2));
    });

    test('withdraws the prompt its attempt waits on', () async {
      final engine = await startEngine();
      await engine.import(_webConfig);
      engine.send(const Connect(_web));
      await engine.next();
      final prompt = await engine.next() as Prompt;
      await engine.next();

      engine.send(const ImportSshConfig(_otherConfig));
      expect(await engine.next(), isA<CatalogReplaced>());
      expect(await engine.next(), isA<SshConfigImported>());
      final withdrawn = await engine.next() as PromptWithdrawn;
      expect(withdrawn.promptId, prompt.promptId);
      expect(withdrawn.reason, PromptWithdrawnReason.attemptEnded);
      engine.send(AnswerPrompt(prompt.promptId, const PromptTrustAnswer(true)));
      expect(await engine.rejected(), 'AnswerPrompt');
      expect(links, isEmpty);
    });
  });
}
