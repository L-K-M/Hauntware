import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:klabautermann_core/src/links/link_connector.dart';
import 'package:klabautermann_core/src/links/link_supervisor.dart'
    show kMaxConnectsInFlight;
import 'package:klabautermann_core/src/sampling/subscriptions.dart';
import 'package:seance_core/seance_core.dart'
    show
        HostKey,
        HostKeyPrompter,
        KeyboardInteractiveChallenge,
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

import 'support/answering_link.dart';
import 'support/forwarding_link.dart';
import 'support/scripted_link.dart';

const _web = 'ssh-config:web';
const _webConfig = 'Host web\n  HostName 192.0.2.10\n  User me\n';
const _otherConfig = 'Host other\n  HostName 192.0.2.11\n  User me\n';
const _bastionConfig = 'Host bastion\n  HostName 192.0.2.1\n  User me\n';

/// A [LinkState] of [serverId] with [status].
Matcher _state(LinkStatus status, {String serverId = _web}) => isA<LinkState>()
    .having((event) => event.serverId, 'serverId', serverId)
    .having((event) => event.status, 'status', status);

final _connecting = _state(const LinkConnecting());
final _waitingForLink = isA<SamplingState>()
    .having((event) => event.serverId, 'serverId', _web)
    .having((event) => event.phase, 'phase', SamplingPhase.waitingForLink);
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
    SamplingSubscriptions? subscriptions,
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
      subscriptions: subscriptions,
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

  /// Reads events until one of type [T].
  Future<T> until<T extends EngineEvent>() async {
    while (true) {
      if (await next() case final T event) return event;
    }
  }
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

  test('the sampling scheduler runs only with links on: off, a Subscribe '
      'gets no answer; on, its server waits for a link', () async {
    for (final linksEnabled in [false, true]) {
      final engine = await startEngine(linksEnabled: linksEnabled);
      await engine.import(_webConfig);
      engine
        ..send(
          const Subscribe(
            serverId: _web,
            subscriptionId: 'rail',
            streams: {SampleStream.overview},
          ),
        )
        // Rejected after the engine handled the Subscribe.
        ..send(const Connect('ssh-config:gone'));
      if (linksEnabled) expect(await engine.next(), _waitingForLink);
      expect(await engine.rejected(), 'Connect');
    }
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

  test('a cancelled keyboard-interactive prompt fails the connect as the '
      'user\'s refusal', () async {
    // The server asks one question; dartssh2 closes the connection on any
    // other response count.
    final engine = await _Engine.start(
      support.path,
      linksEnabled: true,
      dial:
          ({
            required config,
            required credentials,
            required tofu,
            required onHostKey,
            onKeyboardInteractive,
            resolveJumpHost,
          }) async {
            final responses = await onKeyboardInteractive!(
              KeyboardInteractiveChallenge(
                server: config,
                prompts: ['Code:'],
                name: '',
                instruction: '',
              ),
            );
            if (responses.length != 1) {
              throw SshConnectException(
                'closed',
                Exception('count'),
                SshConnectionLog(),
              );
            }
            return _Link();
          },
    );
    await engine.import(_webConfig);

    engine.send(const Connect(_web));
    expect(await engine.next(), _connecting);
    final prompt = await engine.next() as Prompt;
    final request = prompt.request as KeyboardInteractivePromptRequest;
    expect(request.user, 'me');
    expect(request.questions, ['Code:']);
    expect(await engine.next(), isA<LinkState>());

    engine.send(AnswerPrompt(prompt.promptId, const PromptCancelAnswer()));
    expect(
      await engine.next(),
      _state(
        const LinkClosed(
          LinkClosedReason.connectFailed,
          failure: LinkFailureKind.keyboardInteractiveCancelled,
        ),
      ),
    );
  });

  test('Connect for a server outside the fleet is rejected, a jump hop '
      'included', () async {
    final engine = await startEngine();
    await engine.import('$_bastionConfig$_webConfig  ProxyJump bastion\n');

    engine
      ..send(const Connect('ssh-config:gone'))
      // The hop has a config for web's route, but no entry.
      ..send(const Connect('ssh-config-hop:bastion'));
    expect(await engine.rejected(), 'Connect');
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

    test('several leaving together report nothing, one whose attempt '
        'waits for a slot included', () async {
      // Each dial hangs before it resolves its jump route, so its attempt
      // holds a slot that giving it up frees.
      final engine = await _Engine.start(
        support.path,
        linksEnabled: true,
        dial:
            ({
              required config,
              required credentials,
              required tofu,
              required onHostKey,
              onKeyboardInteractive,
              resolveJumpHost,
            }) => Completer<SshLink>().future,
      );
      final hosts = [
        for (var i = 1; i <= kMaxConnectsInFlight + 1; i++) 'ssh-config:s$i',
      ];
      await engine.import(
        [
          _bastionConfig,
          for (final id in hosts)
            'Host ${id.split(':').last}\n  HostName 192.0.2.10\n  User me\n'
                '  ProxyJump bastion\n',
        ].join(),
      );
      for (final id in hosts) {
        engine.send(Connect(id));
        expect(
          await engine.next(),
          _state(const LinkConnecting(), serverId: id),
        );
      }

      engine
        ..send(const ImportSshConfig(_otherConfig))
        // Answered after the import: nothing came for the servers that
        // left.
        ..send(const Connect('ssh-config:gone'));
      expect(await engine.next(), isA<CatalogReplaced>());
      expect(await engine.next(), isA<SshConfigImported>());
      expect(await engine.rejected(), 'Connect');
    });

    test('loses its subscriptions, links on or off', () async {
      for (final linksEnabled in [true, false]) {
        final subscriptions = SamplingSubscriptions();
        final engine = await _Engine.start(
          support.path,
          linksEnabled: linksEnabled,
          dial: dial,
          subscriptions: subscriptions,
        );
        await engine.import(_webConfig);
        engine
          ..send(
            const Subscribe(
              serverId: _web,
              subscriptionId: 'rail',
              streams: {SampleStream.overview},
            ),
          )
          // Rejected after the engine handled the Subscribe.
          ..send(const Connect('ssh-config:gone'));
        if (linksEnabled) expect(await engine.next(), _waitingForLink);
        expect(await engine.rejected(), 'Connect');
        expect(subscriptions.servers, {_web});

        await engine.import(_otherConfig);
        expect(subscriptions.servers, isEmpty);
      }
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

  group('sampling (K22, 03 §6.4)', () {
    late AnsweringLink link;

    /// Connects web over [link], whose processes play a sampler host,
    /// after subscribing it to `core`, as the app does when a view opens.
    Future<_Engine> sampleWeb() async {
      link = AnsweringLink();
      final engine = await _Engine.start(
        support.path,
        linksEnabled: true,
        dial:
            ({
              required config,
              required credentials,
              required tofu,
              required onHostKey,
              onKeyboardInteractive,
              resolveJumpHost,
            }) async => link,
      );
      await engine.import(_webConfig);
      engine.send(
        const Subscribe(
          serverId: _web,
          subscriptionId: 'overview',
          streams: {SampleStream.core},
        ),
      );
      expect(await engine.next(), _waitingForLink);
      engine.send(const Connect(_web));
      return engine;
    }

    test('starts once the link of a server already subscribed is '
        'ready', () async {
      final engine = await sampleWeb();
      final sample = await engine.until<Sample>();
      expect(sample.stream, SampleStream.core);
      expect(link.running, hasLength(2));
    });

    test('stops without an event when the server leaves the fleet', () async {
      final engine = await sampleWeb();
      await engine.until<Sample>();

      engine.send(const ImportSshConfig(_otherConfig));
      // Samples sent before the engine handled the import may still
      // arrive; nothing else comes before its answer.
      while (true) {
        final event = await engine.next();
        if (event is CatalogReplaced) break;
        expect(event, isA<Sample>());
      }
      expect(await engine.next(), isA<SshConfigImported>());
      expect(link.running, isEmpty);
      engine.send(const Connect('ssh-config:gone'));
      expect(await engine.rejected(), 'Connect');
    });
  });

  group('log streams (K25b, 03 §5.2, §7.6)', () {
    late ScriptedLink link;

    Future<_Engine> startEngine() async {
      link = ScriptedLink();
      final engine = await _Engine.start(
        support.path,
        linksEnabled: true,
        dial:
            ({
              required config,
              required credentials,
              required tofu,
              required onHostKey,
              onKeyboardInteractive,
              resolveJumpHost,
            }) async => link,
      );
      await engine.import(_webConfig);
      return engine;
    }

    OpenLogStream window(
      String streamId, {
      String serverId = _web,
      bool follow = false,
    }) => OpenLogStream(
      streamId: streamId,
      spec: LogStreamSpec(
        serverId: serverId,
        source: const JournalLogSource(unit: 'nginx.service'),
        window: 50,
        follow: follow,
      ),
    );

    Matcher stream(String streamId, LogStreamStatus status) =>
        isA<LogStreamState>()
            .having((event) => event.streamId, 'streamId', streamId)
            .having((event) => event.status, 'status', status);

    /// Connects web and opens a window on it, which runs.
    Future<_Engine> runningWindow() async {
      final engine = await startEngine();
      engine.send(const Connect(_web));
      expect(await engine.next(), _connecting);
      expect(await engine.next(), _ready);
      engine.send(window('log-0'));
      expect(await engine.next(), stream('log-0', const LogStreamRunning()));
      return engine;
    }

    test('a window waits for its server\'s link, then reads over it', () async {
      final engine = await startEngine();
      engine.send(window('log-0'));
      expect(
        await engine.next(),
        stream('log-0', const LogStreamWaiting(LogStreamWaitReason.link)),
      );

      // The dial asks no host key, so the link is ready from connecting.
      engine.send(const Connect(_web));
      expect(await engine.next(), _connecting);
      expect(await engine.next(), _ready);
      expect(await engine.next(), stream('log-0', const LogStreamRunning()));
      expect(link.commands.single, contains('journalctl'));

      (await link.process(0))
        ..emitText('${jsonEncode({'__CURSOR': 'c1', 'MESSAGE': 'up'})}\n')
        ..end();
      final batch = await engine.next() as LogBatch;
      expect((batch.records.single as JournalRecord).message, 'up');
      expect(
        await engine.next(),
        stream('log-0', const LogStreamEnded(LogStreamEndReason.oldestReached)),
      );
    });

    test('a reused id and a server outside the fleet are rejected', () async {
      final engine = await startEngine();
      engine
        ..send(window('log-0'))
        ..send(window('log-0', follow: true))
        ..send(window('log-2', serverId: 'ssh-config:gone'));
      expect(await engine.next(), isA<LogStreamState>());
      expect(await engine.rejected(), 'OpenLogStream');
      expect(await engine.rejected(), 'OpenLogStream');
    });

    test('a follow (K26) reads its window, then each new entry, and '
        'Disconnect ends it as failed', () async {
      final engine = await startEngine();
      engine.send(const Connect(_web));
      expect(await engine.next(), _connecting);
      expect(await engine.next(), _ready);
      engine.send(window('log-0', follow: true));
      expect(await engine.next(), stream('log-0', const LogStreamRunning()));
      expect(
        link.commands.single,
        endsWith("'-u' 'nginx.service' '-n' '50' '-f'"),
      );

      final process = await link.process(0);
      for (final message in ['old', 'new']) {
        process.emitText(
          '${jsonEncode({'__CURSOR': 's=$message', 'MESSAGE': message})}\n',
        );
        final batch = await engine.next() as LogBatch;
        expect((batch.records.single as JournalRecord).message, message);
      }

      engine.send(const Disconnect(_web));
      expect(
        await engine.next(),
        stream('log-0', const LogStreamEnded(LogStreamEndReason.failed)),
      );
      await pumpEventQueue();
      expect(process.closeCalls, 1);
    });

    test('CloseStream ends a running window as closed', () async {
      final engine = await runningWindow();
      engine.send(const CloseStream('log-0'));
      expect(
        await engine.next(),
        stream('log-0', const LogStreamEnded(LogStreamEndReason.closed)),
      );
      final process = await link.process(0);
      await pumpEventQueue();
      expect(process.closeCalls, 1);
    });

    test('the background pauses a running window, and the foreground '
        'runs it again', () async {
      final engine = await runningWindow();
      engine.send(const SetAppActivity(AppActivity.background));
      expect(
        await engine.next(),
        stream('log-0', const LogStreamWaiting(LogStreamWaitReason.background)),
      );
      engine.send(const SetAppActivity(AppActivity.foreground));
      expect(await engine.next(), stream('log-0', const LogStreamRunning()));
      expect(link.commands, hasLength(2));
    });

    test('Disconnect ends a running window as failed before the link '
        'closes', () async {
      final engine = await runningWindow();
      engine.send(const Disconnect(_web));
      expect(
        await engine.next(),
        stream('log-0', const LogStreamEnded(LogStreamEndReason.failed)),
      );
      expect(
        await engine.next(),
        _state(const LinkClosed(LinkClosedReason.closedByOwner)),
      );
    });

    test('a server leaving the fleet ends its window as failed', () async {
      final engine = await runningWindow();
      engine.send(const ImportSshConfig(_otherConfig));
      expect(
        await engine.next(),
        stream('log-0', const LogStreamEnded(LogStreamEndReason.failed)),
      );
      expect(await engine.next(), isA<CatalogReplaced>());
      expect(await engine.next(), isA<SshConfigImported>());
    });
  });

  group('Docker queries (03 §5.9, §10.1)', () {
    DockerQuery query(String queryId, {String serverId = _web}) => DockerQuery(
      serverId: serverId,
      queryId: queryId,
      query: const DockerEngineQuery(),
    );

    Matcher failed(String queryId, DockerQueryFailure failure) =>
        isA<DockerResult>()
            .having((r) => r.queryId, 'queryId', queryId)
            .having(
              (r) => r.payload,
              'payload',
              isA<DockerQueryFailed>().having(
                (f) => f.failure,
                'failure',
                failure,
              ),
            );

    test('with links off, a query is rejected', () async {
      final engine = await startEngine(linksEnabled: false);
      await engine.import(_webConfig);
      engine.send(query('q-0'));
      expect(await engine.rejected(), 'DockerQuery');
    });

    test('a query waits for its server\'s link, then for its probe, and '
        'one outside the fleet is answered as such', () async {
      final link = ForwardingLink();
      final engine = await _Engine.start(
        support.path,
        linksEnabled: true,
        dial:
            ({
              required config,
              required credentials,
              required tofu,
              required onHostKey,
              onKeyboardInteractive,
              resolveJumpHost,
            }) async => link,
      );
      await engine.import(_webConfig);

      engine
        ..send(query('q-0'))
        ..send(query('q-1', serverId: 'ssh-config:gone'));
      expect(
        await engine.next(),
        failed('q-0', DockerQueryFailure.linkUnavailable),
      );
      expect(
        await engine.next(),
        isA<DockerEndpointState>()
            .having((s) => s.serverId, 'serverId', _web)
            .having((s) => s.phase, 'phase', DockerEndpointPhase.waiting)
            .having((s) => s.label, 'label', DockerRouteLabel.none),
      );
      expect(await engine.next(), failed('q-1', DockerQueryFailure.notInFleet));

      engine.send(const Connect(_web));
      expect(await engine.next(), _connecting);
      expect(await engine.next(), _ready);
      // Nothing samples, so no probe answers.
      engine.send(query('q-2'));
      expect(
        await engine.next(),
        failed('q-2', DockerQueryFailure.profileUnknown),
      );
      expect(link.opens, isEmpty);
    });
  });
}
