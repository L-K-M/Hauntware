import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart'
    show engineMain;
import 'package:test/test.dart';

/// Why the fixture suites skip: run.sh exports the fixture's environment.
const fixtureSkipReason =
    'needs the sshd fixture: run klabautermann/test/integration/run.sh';

/// The fleet aliases of the client config each engine imports.
const directServer = 'ssh-config:direct';
const agentServer = 'ssh-config:agent';
const behindServer = 'ssh-config:behind';

/// The fleet server of the [i]th alias of the sampled host
/// ([FixtureEngine.startAliases]).
String aliasServer(int i) => 'ssh-config:alias-$i';

/// The Compose services of klabautermann/test/integration.
enum FixtureService {
  /// The sampled host, published on loopback and reached by the jump host
  /// under its service name.
  sshd,

  /// The ProxyJump host.
  jump,
}

/// What a host-key prompt's machine is: its host and port.
typedef Endpoint = ({String host, int port});

/// The sshd fixture run.sh started (03 §11.3, D53), from the variables it
/// exports.
final class Fixture {
  Fixture._(this._environment);

  final Map<String, String> _environment;

  /// The running fixture, or null when run.sh exported none of its
  /// variables. A run.sh that exports only some of them fails the suite
  /// instead: keyed on one, a renamed variable would skip every test and
  /// leave the integration job green.
  static Fixture? fromEnvironment([Map<String, String>? environment]) {
    environment ??= Platform.environment;
    if (!environment.keys.any((name) => name.startsWith(_prefix))) {
      return null;
    }
    return Fixture._(environment);
  }

  static const _prefix = 'KLABAUTERMANN_FIXTURE_';

  String _variable(String name) {
    final value = _environment['$_prefix$name'];
    if (value == null || value.isEmpty) {
      throw StateError('run.sh exported no $_prefix$name');
    }
    return value;
  }

  String get _composeFile => _variable('COMPOSE_FILE');
  String get _project => _variable('COMPOSE_PROJECT');
  String get _host => _variable('HOST');
  int get _port => int.parse(_variable('PORT'));
  int get _jumpPort => int.parse(_variable('JUMP_PORT'));
  String get _user => _variable('USER');

  /// run.sh's directory for this run, which it removes on every exit. A
  /// second signal ends the suites before their teardowns run, so files
  /// kept anywhere else would outlive a signalled run.
  String get _runtimeDirectory => _variable('RUNTIME');

  /// Where the engine dials the sampled host and the jump host, and where
  /// the jump host reaches the sampled host.
  Endpoint get direct => (host: _host, port: _port);
  Endpoint get jumpHost => (host: _host, port: _jumpPort);
  Endpoint get behind => (host: FixtureService.sshd.name, port: 22);

  /// The key file the `IdentityFile` hosts sign in with.
  String get identityFile => _variable('IDENTITY_FILE');

  /// The SHA256 fingerprints of the key file's key and of the key only the
  /// agent holds, as sshd logs an accepted key.
  String get identityFingerprint => _variable('IDENTITY_FINGERPRINT');
  String get agentFingerprint => _variable('AGENT_FINGERPRINT');

  /// Where run.sh collects evidence (`$KLABAUTERMANN_EVIDENCE_DIR`), or
  /// null.
  String? get _evidenceDirectory =>
      switch (_environment['KLABAUTERMANN_EVIDENCE_DIR']) {
        final path? when path.isNotEmpty => '$path/fixture',
        _ => null,
      };

  /// The client config the engine imports: [directServer] with the key
  /// file, [agentServer] with the agent, and [behindServer] through the
  /// jump host, which reaches the sampled host by its service name.
  String get _sshConfig =>
      '''
Host direct
  HostName $_host
  Port $_port
  User $_user
  IdentityFile $identityFile

Host agent
  HostName $_host
  Port $_port
  User $_user

Host behind
  HostName ${behind.host}
  Port ${behind.port}
  User $_user
  IdentityFile $identityFile
  ProxyJump hop

Host hop
  HostName $_host
  Port $_jumpPort
  User $_user
  IdentityFile $identityFile
''';

  /// [count] aliases of the sampled host, `alias-0` on, each with the key
  /// file: separate fleet servers, each dialing a link of its own to the
  /// one sshd, as 03 §11.4's ten hosts do in the soak.
  String _aliasSshConfig(int count) => [
    for (var i = 0; i < count; i++)
      '''
Host alias-$i
  HostName $_host
  Port $_port
  User $_user
  IdentityFile $identityFile
''',
  ].join('\n');

  /// Each endpoint a host-key prompt may name, with the fingerprints of the
  /// service that answers there.
  Future<Map<Endpoint, Set<String>>> hostKeys() async {
    final sshd = await _hostKeyFingerprints(FixtureService.sshd);
    return {
      direct: sshd,
      behind: sshd,
      jumpHost: await _hostKeyFingerprints(FixtureService.jump),
    };
  }

  Future<Set<String>> _hostKeyFingerprints(FixtureService service) async {
    final listing = await exec(service, [
      'sh',
      '-c',
      'for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "\$key"; done',
    ]);
    return {
      for (final line in const LineSplitter().convert(listing))
        if (line.split(' ') case [_, final fingerprint, ...]) fingerprint,
    };
  }

  /// Runs `docker compose` on the fixture's project and returns its
  /// stdout; a failure fails the test.
  Future<String> compose(List<String> arguments) async {
    final result = await Process.run('docker', [
      'compose',
      '--project-name',
      _project,
      '--file',
      _composeFile,
      ...arguments,
    ]);
    if (result.exitCode != 0) {
      fail(
        'docker compose ${arguments.join(' ')} exited ${result.exitCode}: '
        '${result.stderr}',
      );
    }
    return '${result.stdout}';
  }

  /// Runs [command] as root in [service]'s container, out of the engine's
  /// sight: the tests' side channel for signals and flags.
  Future<String> exec(FixtureService service, List<String> command) =>
      compose(['exec', '-T', service.name, ...command]);

  /// The lines [service] has logged so far.
  Future<List<String>> logs(FixtureService service) async =>
      const LineSplitter().convert(
        await compose(['logs', '--no-color', '--no-log-prefix', service.name]),
      );

  /// The PIDs of the engine's sampler shells on the sampled host, oldest
  /// first (`sshd/samplers.sh`).
  Future<List<int>> samplerPids() async => [
    for (final line in const LineSplitter().convert(
      await exec(FixtureService.sshd, ['fixture-samplers']),
    ))
      int.parse(line),
  ];
}

/// The real engine, spawned as the app spawns it but with links on, which
/// the app's composition root still leaves off ([EngineStart.linksEnabled]).
/// Each test starts its own, so host-key pins and links never carry over.
/// Stopping it disconnects every server first, so the fixture's sampler
/// shells end with their links.
final class FixtureEngine {
  FixtureEngine._(
    this._evidenceDirectory,
    this._client,
    this._events,
    this._support,
  );

  final String? _evidenceDirectory;
  final IsolateEngineClient _client;
  final StreamIterator<EngineEvent> _events;
  final Directory _support;
  final _clock = Stopwatch()..start();
  final _log = StringBuffer();
  final _connected = <String>{};

  /// The read a timed-out [until] left pending, which the next one takes
  /// over: a [StreamIterator] allows one at a time.
  Future<bool>? _pending;

  /// Every event read so far, in order.
  final seen = <EngineEvent>[];

  /// Starts an engine and imports [Fixture._sshConfig]. [name] titles the
  /// event log it leaves in the evidence directory.
  static Future<FixtureEngine> start(Fixture fixture, String name) => launch(
    name: name,
    runtimeDirectory: fixture._runtimeDirectory,
    sshConfig: fixture._sshConfig,
    hosts: 4,
    evidenceDirectory: fixture._evidenceDirectory,
  );

  /// Starts an engine through [entryPoint], which wraps the engine's own
  /// (`link_meter.dart`), and imports [count] aliases of the sampled host
  /// ([aliasServer]). [name] titles the event log it leaves in
  /// [evidenceDirectory].
  static Future<FixtureEngine> startAliases(
    Fixture fixture,
    String name, {
    required int count,
    required String evidenceDirectory,
    required void Function(EngineStart start) entryPoint,
  }) => launch(
    name: name,
    runtimeDirectory: fixture._runtimeDirectory,
    sshConfig: fixture._aliasSshConfig(count),
    hosts: count,
    evidenceDirectory: evidenceDirectory,
    entryPoint: entryPoint,
  );

  /// Starts an engine that keeps its files under [runtimeDirectory] and
  /// imports [sshConfig], which names [hosts] hosts, for a host other than
  /// the Compose fixture, such as the runner VM (`runner_vm.dart`). [name]
  /// titles the event log it leaves in [evidenceDirectory], if any.
  /// [entryPoint] replaces the engine's.
  static Future<FixtureEngine> launch({
    required String name,
    required String runtimeDirectory,
    required String sshConfig,
    required int hosts,
    String? evidenceDirectory,
    void Function(EngineStart start) entryPoint = engineMain,
  }) async {
    final support = await Directory(runtimeDirectory).createTemp('engine-');
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      linksEnabled: true,
      entryPoint: entryPoint,
    );
    final engine = FixtureEngine._(
      evidenceDirectory,
      client,
      StreamIterator(client.events),
      support,
    );
    addTearDown(() => engine._stop(name));

    await engine.until<CatalogReplaced>();
    engine.send(ImportSshConfig(sshConfig));
    await engine.until<SshConfigImported>(
      (event) => event.importedCount == hosts && event.skippedCount == 0,
    );
    return engine;
  }

  /// The support directory, where the engine keeps its files.
  String get supportDirectory => _support.path;

  void send(EngineRequest request) {
    note('> ${request.runtimeType}');
    _client.send(request);
  }

  /// Reads events until one of type [T] that [test] accepts; fails after
  /// [timeout] without one. A host-key prompt fails the test: only
  /// [connect] expects them.
  Future<T> until<T extends EngineEvent>([
    bool Function(T event)? test,
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    final deadline = _clock.elapsed + timeout;
    while (true) {
      final left = deadline - _clock.elapsed;
      final arrived = await (_pending ??= _events.moveNext()).timeout(
        left.isNegative ? Duration.zero : left,
        onTimeout: () => fail('no $T within $timeout'),
      );
      _pending = null;
      expect(arrived, isTrue, reason: 'the engine stopped');
      final event = _events.current;
      seen.add(event);
      note('< ${_describe(event)}');
      if (event is T && (test?.call(event) ?? true)) return event;
      if (event is Prompt && T != Prompt) {
        fail('unexpected prompt: ${_describe(event)}');
      }
    }
  }

  /// Reads events for [duration], handing each to [onEvent], without
  /// keeping them in [seen] or the event log: a soak's samples would grow
  /// both. Other events than samples are logged. A prompt fails the test,
  /// as in [until].
  Future<void> pump(
    Duration duration,
    void Function(EngineEvent event) onEvent,
  ) async {
    final deadline = _clock.elapsed + duration;
    while (true) {
      final left = deadline - _clock.elapsed;
      if (left <= Duration.zero) return;

      // A read the deadline cuts short stays pending for the next caller,
      // as in [until]; the timeout's timer goes when the read completes.
      final pending = _pending ??= _events.moveNext();
      final arrived = await pending
          .then<bool?>((arrived) => arrived)
          .timeout(left, onTimeout: () => null);
      if (arrived == null) return;

      _pending = null;
      expect(arrived, isTrue, reason: 'the engine stopped');
      final event = _events.current;
      if (event is! Sample) note('< ${_describe(event)}');
      if (event is Prompt) fail('unexpected prompt: ${_describe(event)}');
      onEvent(event);
    }
  }

  /// Connects [serverId] interactively, trusting each host key the fixture
  /// really has at the prompting endpoint, and returns the endpoints that
  /// prompted, in order.
  Future<List<Endpoint>> connect(
    String serverId,
    Map<Endpoint, Set<String>> hostKeys,
  ) async {
    final prompted = <Endpoint>[];
    send(Connect(serverId));
    _connected.add(serverId);
    while (true) {
      final event = await until<EngineEvent>(
        (event) =>
            event is Prompt ||
            (event is LinkState && event.serverId == serverId),
      );
      switch (event) {
        case Prompt(
          :final promptId,
          :final host,
          :final port,
          request: HostKeyPromptRequest(:final fingerprintSha256),
        ):
          final endpoint = (host: host, port: port);
          expect(hostKeys[endpoint], contains(fingerprintSha256));
          prompted.add(endpoint);
          send(AnswerPrompt(promptId, const PromptTrustAnswer(true)));
        case LinkState(status: LinkReady()):
          return prompted;
        case LinkState(status: LinkClosed() || LinkBlocked()):
          fail('connect failed: ${_describe(event)}');
        default:
          break;
      }
    }
  }

  /// Subscribes [serverId]'s [streams] and waits until it samples.
  Future<void> subscribe(String serverId, Set<SampleStream> streams) async {
    send(
      Subscribe(
        serverId: serverId,
        subscriptionId: 'fixture',
        streams: streams,
      ),
    );
    await until<SamplingState>(
      (event) =>
          event.serverId == serverId && event.phase == SamplingPhase.sampling,
    );
  }

  /// The first sample of [serverId]'s [stream] read so far, or else the
  /// next one.
  Future<Sample> firstSample(String serverId, SampleStream stream) async {
    for (final event in seen) {
      if (event is Sample &&
          event.serverId == serverId &&
          event.stream == stream) {
        return event;
      }
    }
    return sample(serverId, stream);
  }

  /// The next sample of [serverId]'s [stream] that [test] accepts.
  Future<Sample> sample(
    String serverId,
    SampleStream stream, {
    bool Function(Sample sample)? test,
    Duration timeout = const Duration(seconds: 30),
  }) => until<Sample>(
    (event) =>
        event.serverId == serverId &&
        event.stream == stream &&
        (test?.call(event) ?? true),
    timeout,
  );

  /// The link statuses [serverId] reported from [from] on in [seen].
  List<LinkStatus> statusesSince(String serverId, int from) => [
    for (final event in seen.skip(from))
      if (event is LinkState && event.serverId == serverId) event.status,
  ];

  Future<void> _stop(String name) async {
    try {
      for (final serverId in _connected) {
        send(Disconnect(serverId));
        await until<LinkState>(
          (event) =>
              event.serverId == serverId &&
              event.status == const LinkClosed(LinkClosedReason.closedByOwner),
          const Duration(seconds: 10),
        );
      }
    } on Object catch (error) {
      // A test that failed mid-connect may leave nothing to close, or a
      // prompt open; its own failure is the one to report.
      note('! stop: $error');
    } finally {
      // The iterator goes first: it pauses the client's broadcast stream
      // while no read is pending, and a paused listener would hold up the
      // stream's close in shutdown.
      await _events.cancel();
      await _client.shutdown();
      await _support.delete(recursive: true);
      if (_evidenceDirectory case final directory?) {
        final file = File('$directory/${name.replaceAll(' ', '-')}.events');
        await file.create(recursive: true);
        await file.writeAsString('$_log');
      }
    }
  }

  /// Logs [line] for the evidence file and a failed test's output, such
  /// as what a test does to the fixture behind the engine's back.
  void note(String line) {
    final stamped =
        '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(3).padLeft(8)} '
        '$line';
    _log.writeln(stamped);
    printOnFailure(stamped);
  }
}

/// One line about [event] for the evidence log and failure messages.
String _describe(EngineEvent event) => switch (event) {
  LinkState(:final serverId, :final status) =>
    'LinkState $serverId ${_status(status)}',
  Sample(:final serverId, :final stream, :final seq, :final result) =>
    'Sample $serverId ${stream.name} seq=$seq ${_result(result)}',
  Gap(:final serverId, :final streams, :final cause) =>
    'Gap $serverId ${cause.name} ${[for (final s in streams) s.name]}',
  SamplingState(:final serverId, :final phase) =>
    'SamplingState $serverId ${phase.name}',
  Prompt(:final serverId, :final host, :final port, :final request) =>
    'Prompt $serverId $host:$port ${request.kind.name}',
  RequestRejected(:final requestName, :final reason) =>
    'RequestRejected $requestName: $reason',
  LogStreamState(:final streamId, :final status) =>
    'LogStreamState $streamId ${_logStatus(status)}',
  LogBatch(:final streamId, :final records, :final dropped) =>
    'LogBatch $streamId ${records.length} records, $dropped dropped',
  _ => '${event.runtimeType}',
};

String _logStatus(LogStreamStatus status) => switch (status) {
  LogStreamWaiting(:final reason) => 'waiting ${reason.name}',
  LogStreamRunning(:final reader, :final continuity) =>
    'running ${reader.name} ${continuity.name}',
  LogStreamEnded(:final reason, :final detail) =>
    'ended ${reason.name}${detail == null ? '' : ' ($detail)'}',
};

String _status(LinkStatus status) => switch (status) {
  LinkClosed(:final reason, :final failure) =>
    'closed ${reason.name}${failure == null ? '' : ' ${failure.name}'}',
  LinkBlocked(:final reason) => 'blocked ${reason.name}',
  LinkNeedsUser(:final kind) => 'needsUser ${kind.name}',
  _ => '${status.runtimeType}',
};

String _result(SampleResult result) => switch (result) {
  CollectorUnavailable(:final reason, :final detail) =>
    'unavailable ${reason.name}${detail == null ? '' : ' ($detail)'}',
  _ => '${result.runtimeType}',
};
