// The engine's Docker reads end to end on the Docker fixture (03 §11.3;
// M3 D21, exit E2): the real engine in its own isolate, links on, over an
// imported ssh_config. Route and negotiation, event-driven lists, inspect
// masking, a log follow and the events stream across a reconnect, list
// stats, images, stacks and a stack file, and a user the socket refuses.
// The 1,000 lines/s follow is spike S1's measurement; its numbers go to
// $KLABAUTERMANN_EVIDENCE_DIR/fixture/docker-follow.json. run.sh starts
// and seeds the fixture (seed_docker.sh); without it these skip. The
// reconnect tests stop and restart the Docker host, so they run last, and
// each leaves it running.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show clientMaxTestedApiVersion, detectOwnership;
import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        HostKeyVerdict,
        InMemoryHostKeyStore,
        ServerConfig,
        SshCredentials,
        SshLink,
        TofuVerifier;
import 'package:test/test.dart';

import 'support/fixture.dart';

/// The image seed_docker.sh tags, which every container here runs.
const _image = 'klabautermann-fixture/busybox:1.37';

/// The engine's first candidate path (03 §5.4) on the Docker host.
const _socket = '/var/run/docker.sock';

/// dind's own socket, for the tests' side channel into the engine.
const _dindSocket = 'unix:///run/docker-fixture/docker.sock';

/// The seeded fake secrets (seed_docker.sh), which must never cross
/// unmasked.
const _password = 'fixture-password';
const _token = 'fixture-token';

/// The seeded stack's directory on the Docker host.
const _demoStack = '/home/klab/stacks/demo';

/// DKE-02's budget from a container's start to the list that shows it
/// [E].
const _listChangeBudget = Duration(seconds: 2);

/// Covers a redial after the Docker host returns, as in
/// engine_fixture_test.dart.
// A Docker host restart plus a redial has passed 90 s on a loaded CI
// runner (run 120054453500); the bound fails real deadlocks only.
const _redialWait = Duration(seconds: 180);

/// Covers stack verification: a `test -f` exec, the compose CLI's
/// detection and `compose config --hash`, each up to 30 s [E].
const _verifyWait = Duration(seconds: 90);

/// S1's follow: the rate the logger writes, the warm-up before the
/// measured window, and the window.
const _firehoseRate = 1000;
const _firehoseWarmUp = Duration(seconds: 3);
const _firehoseWindow = Duration(seconds: 20);

/// Writes [_firehoseRate] numbered lines a second, paced by
/// /proc/uptime's centiseconds so the rate holds however long a burst
/// takes; `read`, `echo` and `[` are shell builtins, so only the pause
/// forks.
const _firehoseScript =
    r'read up _ </proc/uptime; start=${up%.*}${up#*.}; n=0; '
    r'while :; do read up _ </proc/uptime; now=${up%.*}${up#*.}; '
    // Centiseconds since the start, times the lines due per centisecond.
    'due=\$(( (now - start) * ${_firehoseRate ~/ 100} )); '
    r'while [ $n -lt $due ]; do '
    r'echo "firehose $n ................................................"; '
    r'n=$((n + 1)); done; usleep 5000; done';

/// Writes ten numbered lines a second.
const _tickerScript =
    r'n=0; while :; do echo "tick $n"; n=$((n + 1)); usleep 100000; done';

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the Docker engine suite', () {}, skip: fixtureSkipReason);
    return;
  }

  late Map<Endpoint, Set<String>> hostKeys;
  setUpAll(() async => hostKeys = await fixture.dockerHostKeys());

  var queries = 0;
  var streams = 0;

  /// [serverId]'s probe answer on its link, read so far or next.
  Future<HostProfileChanged> probed(
    FixtureEngine engine, [
    String serverId = dockerServer,
  ]) async {
    bool fresh(HostProfileChanged e) =>
        e.serverId == serverId && e.cachedAt == null;
    for (final event in engine.seen) {
      if (event is HostProfileChanged && fresh(event)) return event;
    }
    return engine.until<HostProfileChanged>(fresh);
  }

  /// Starts an engine and connects [serverId] with a sampling
  /// subscription, and waits for its capability probe: until it answers,
  /// the endpoint has no sockets to try and a query is answered with
  /// [DockerQueryFailure.profileUnknown] (03 §5.4).
  Future<FixtureEngine> start(
    String name, {
    String serverId = dockerServer,
  }) async {
    final engine = await FixtureEngine.startDocker(fixture, name);
    await engine.connect(serverId, hostKeys);
    await engine.subscribe(serverId, {SampleStream.core});
    await probed(engine, serverId);
    return engine;
  }

  /// Sends [spec] for [serverId] and returns its answer.
  Future<DockerPayload> query(
    FixtureEngine engine,
    DockerQuerySpec spec, {
    String serverId = dockerServer,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final queryId = 'query-${queries++}';
    engine.send(DockerQuery(serverId: serverId, queryId: queryId, query: spec));
    final result = await engine.until<DockerResult>(
      (r) => r.serverId == serverId && r.queryId == queryId,
      timeout,
    );
    return result.payload;
  }

  /// The endpoint states [serverId] reported so far.
  List<DockerEndpointState> endpointStates(
    FixtureEngine engine, [
    String serverId = dockerServer,
  ]) => [
    for (final event in engine.seen)
      if (event is DockerEndpointState && event.serverId == serverId) event,
  ];

  /// The next [list] of the fixture user's server whose payload [test]
  /// accepts; a failed list fails the test.
  Future<DockerListChanged> listChanged(
    FixtureEngine engine,
    DockerWatchList list, {
    bool Function(DockerListChanged event)? test,
    Duration timeout = const Duration(seconds: 30),
  }) => engine.until<DockerListChanged>((event) {
    if (event.serverId != dockerServer || event.list != list) return false;
    if (event.payload case DockerQueryFailed(:final failure, :final detail)) {
      fail('the ${list.name} list failed: ${failure.name} ($detail)');
    }
    return test?.call(event) ?? true;
  }, timeout);

  /// Runs `docker` in dind as root, out of the engine's sight.
  Future<String> dind(List<String> arguments) => fixture.exec(
    FixtureService.dind,
    ['docker', '--host', _dindSocket, ...arguments],
  );

  /// Runs [script] in a new detached container [name], removed when the
  /// test ends.
  Future<void> runContainer(String name, String script) async {
    await dind(['run', '--detach', '--name', name, _image, 'sh', '-c', script]);
    addTearDown(() => dind(['rm', '--force', name]));
  }

  /// Opens a follow of [containerId]'s log with [window] earlier lines.
  String follow(FixtureEngine engine, String containerId, {int window = 0}) {
    final streamId = 'follow-${streams++}';
    engine.send(
      OpenLogStream(
        streamId: streamId,
        spec: LogStreamSpec(
          serverId: dockerServer,
          source: ContainerLogSource(containerId),
          window: window,
          follow: true,
        ),
      ),
    );
    return streamId;
  }

  /// The number a seeded logger put after [prefix] on [record].
  int sequence(LogRecord record, String prefix) {
    final text = (record as ContainerRecord).text;
    expect(text, startsWith('$prefix '));
    return int.parse(text.split(' ')[1]);
  }

  test('the endpoint is rank 1 streamlocal to the rootful socket, and the '
      'API is negotiated against dind', () async {
    final engine = await start('docker route');

    final payload = await query(engine, const DockerEngineQuery());

    final states = endpointStates(engine);
    expect(
      states.map((s) => s.phase),
      isNot(contains(DockerEndpointPhase.failed)),
    );
    final ready = states.last;
    expect(ready.phase, DockerEndpointPhase.ready);
    expect(ready.route?.rank, DockerRank.streamlocal);
    expect(ready.route?.rank.number, 1);
    expect(ready.label, DockerRouteLabel.socketForward);
    expect(ready.route?.socketPath, _socket);
    expect(ready.route?.runtime, EngineRuntime.docker);
    expect(ready.route?.mode, EngineMode.rootful);
    expect(ready.route?.rootEquivalence, DockerRootEquivalence.rootfulSocket);
    expect(ready.lowSession, isFalse);

    final DockerEnginePayload(:info, :version) = payload as DockerEnginePayload;
    expect(
      version.version,
      '29.9.1',
      reason:
          'the dind image pin in test/integration/docker-compose.yml; '
          'bump both together',
    );
    expect(info.serverVersion, version.version);
    final serverMax = version.apiVersion!;
    expect(
      ready.negotiatedApi,
      serverMax < clientMaxTestedApiVersion
          ? serverMax
          : clientMaxTestedApiVersion,
    );
    engine.note('! negotiated ${ready.negotiatedApi} with $serverMax');
  });

  test('the container list follows a docker run over SSH within 2 s', () async {
    final engine = await start('docker list events');
    engine.send(
      const DockerWatch(
        serverId: dockerServer,
        watchId: 'containers',
        lists: {DockerWatchList.containers},
      ),
    );

    final first = await listChanged(engine, DockerWatchList.containers);
    expect(first.fullRelist, isTrue);
    final seeded = {
      for (final c in (first.payload as DockerContainersPayload).containers)
        c.name: c,
    };
    expect(
      seeded.keys,
      containsAll([
        'demo-web-1',
        'demo-broken-1',
        'demo-console-1',
        'demo-vault-1',
        'gone-idle-1',
        'coolify-app',
      ]),
    );
    expect(seeded['demo-web-1']!.health, HealthStatus.healthy);
    expect(seeded['demo-broken-1']!.health, HealthStatus.unhealthy);
    // The list's command line can hold a secret; inspect masks it.
    expect(seeded.values.map((c) => c.command), everyElement(isNull));

    final shell = await _DockerHostShell.connect(fixture, hostKeys);
    const name = 'klab-e2e-run';
    addTearDown(() => dind(['rm', '--force', name]));
    await shell.run(
      'docker run --detach --name $name $_image sh -c "sleep 600"',
    );
    final ran = Stopwatch()..start();
    engine.note('! docker run $name returned');
    final added = await listChanged(
      engine,
      DockerWatchList.containers,
      test: (event) => _names(event).contains(name),
      timeout: _listChangeBudget,
    );
    engine.note('! $name listed after ${ran.elapsedMilliseconds} ms');
    expect(added.fullRelist, isFalse);
    expect(_names(added), containsAll(seeded.keys));

    await shell.run('docker rm --force $name');
    ran.reset();
    await listChanged(
      engine,
      DockerWatchList.containers,
      test: (event) => !_names(event).contains(name),
      timeout: _listChangeBudget,
    );
    engine.note('! $name gone after ${ran.elapsedMilliseconds} ms');
  });

  test('an inspected container crosses with its seeded secrets '
      'masked', () async {
    final engine = await start('docker inspect');

    final payload = await query(
      engine,
      const DockerContainerQuery('demo-vault-1'),
    );

    final details = (payload as DockerContainerPayload).container;
    final config = details.config!;
    final env = {for (final e in config.env) e.name: e.value};
    _expectSecret(env['DB_PASSWORD'], _password);
    _expectSecret(env['API_TOKEN'], _token);
    expect(env['FIXTURE_MODE'], MaskedValue.plain('plain'));
    _expectSecret(config.labels['fixture.api-token'], _token);

    // `--password ${FIXTURE_PASSWORD}`, interpolated from the stack's
    // .env, and a URL credential in `--dsn=`, in Args and again in Cmd.
    expect(details.path, 'sh');
    for (final words in [details.args, config.cmd]) {
      final shown = words.map((w) => w.display).toList();
      final option = shown.indexOf('--password');
      expect(option, isNonNegative, reason: '$shown');
      _expectSecret(words[option + 1], _password);
      final dsn = words.singleWhere((w) => w.display.startsWith('--dsn='));
      expect(dsn.isMasked, isTrue);
      expect(dsn.reveal(), contains(_password));
    }

    // The health check prints DB_PASSWORD=<value>.
    final checks = details.state!.health!.log;
    expect(checks, isNotEmpty);
    for (final check in checks) {
      expect(check.output?.isMasked, isTrue);
      expect(check.output?.reveal(), contains(_password));
    }

    final shown = [
      ?details.name,
      ?details.path,
      for (final e in config.env) ...[e.name, e.value.display],
      for (final MapEntry(:key, :value) in config.labels.entries) ...[
        key,
        value.display,
      ],
      for (final w in [...details.args, ...config.entrypoint, ...config.cmd])
        w.display,
      for (final check in checks) ?check.output?.display,
    ];
    for (final secret in [_password, _token]) {
      expect(shown, everyElement(isNot(contains(secret))));
    }
  });

  test('images list with the seeded dangling image flagged', () async {
    final engine = await start('docker images');

    final payload = await query(engine, const DockerImagesQuery());

    final images = (payload as DockerImagesPayload).images;
    final seeded = images.singleWhere((i) => i.repoTags.contains(_image));
    expect(seeded.isDangling, isFalse);
    // The in-use count arrives with API 1.51, below the dind engine's.
    expect(seeded.inUse, isTrue);
    final dangling = images.singleWhere(
      (i) => i.labels['klabautermann.fixture']?.display == 'dangling',
    );
    expect(dangling.isDangling, isTrue);
    expect(dangling.inUse, isFalse);
  });

  test('list stats arrive in rounds, with CPU % from the second '
      'on', () async {
    final engine = await start('docker stats');
    // The ticker forks ten times a second, so each round sees it use
    // CPU; coolify-app sleeps for a minute at a time, and a round in
    // which it used none has no CPU % (cpuPercentDelta).
    const busy = 'klab-e2e-stats';
    await runContainer(busy, _tickerScript);
    final listed = await query(engine, const DockerContainersQuery());
    final byName = {
      for (final c in (listed as DockerContainersPayload).containers)
        c.name: c.id,
    };
    final busyId = byName[busy]!;
    final ids = {busyId, byName['coolify-app']!};

    engine.send(
      DockerWatch(
        serverId: dockerServer,
        watchId: 'stats',
        lists: const {DockerWatchList.stats},
        statsFor: ids,
      ),
    );

    Map<String, ContainerListStats> rows(DockerListChanged event) => {
      for (final row in (event.payload as DockerStatsPayload).stats)
        row.containerId: row,
    };
    final first = await listChanged(engine, DockerWatchList.stats);
    final second = await listChanged(engine, DockerWatchList.stats);
    for (final round in [first, second]) {
      expect(rows(round).keys, unorderedEquals(ids));
      for (final row in rows(round).values) {
        expect(row.memoryUsed, isPositive);
        expect(row.memoryLimit, greaterThanOrEqualTo(row.memoryUsed!));
      }
    }
    // A one-shot read's precpu_stats is zero (03 §5.6), so a container's
    // first read has no CPU % and the next one takes the delta.
    expect(rows(first).values.map((s) => s.cpuPercent), everyElement(isNull));
    expect(rows(second)[busyId]!.cpuPercent, isPositive);
    expect(
      second.at.difference(first.at),
      greaterThanOrEqualTo(const Duration(seconds: 4)),
    );
  });

  test('stacks are verified, missing their source, or managed', () async {
    final engine = await start('docker stacks');
    engine.send(
      const DockerWatch(
        serverId: dockerServer,
        watchId: 'stacks',
        lists: {DockerWatchList.stacks},
      ),
    );

    final checked = await listChanged(
      engine,
      DockerWatchList.stacks,
      test: (event) {
        final verdicts = (event.payload as DockerStacksPayload).verdicts;
        return verdicts.isNotEmpty &&
            verdicts.values.every((v) => v is! StackVerifying);
      },
      timeout: _verifyWait,
    );

    final stacks = checked.payload as DockerStacksPayload;
    // Compose v5's `config --hash '*'` prints a hash per service, which
    // the labels match.
    expect(stacks.verdicts['demo'], isA<StackVerified>());
    expect(
      stacks.verdicts['gone'],
      isA<StackSourceNotOnHost>().having(
        (v) => v.deployedBy,
        'deployedBy',
        isNull,
      ),
    );
    final cli = stacks.composeCli!;
    expect(cli.pluginVersion, isNotNull);
    expect(cli.standaloneVersion, isNull);
    engine.note('! compose plugin ${cli.pluginVersion}');

    final demo = stacks.grouping.project('demo')!;
    expect(
      demo.services.map((s) => s.name),
      unorderedEquals(['web', 'broken', 'console', 'vault']),
    );
    expect(demo.ownership.isOwned, isFalse);
    expect(demo.workingDir, _demoStack);
    final coolify = stacks.grouping.unmanaged.singleWhere(
      (c) => c.name == 'coolify-app',
    );
    expect(
      detectOwnership(coolify.labels).primary?.manager,
      ExternalManager.coolify,
    );
  });

  test('a stack file and its .env read with their secrets masked', () async {
    final engine = await start('docker stack file');

    final compose = await query(
      engine,
      const DockerStackFileQuery(
        project: 'demo',
        path: '$_demoStack/compose.yaml',
      ),
      timeout: _verifyWait,
    );
    final environment = await query(
      engine,
      const DockerStackFileQuery(project: 'demo', path: '$_demoStack/.env'),
    );

    for (final (payload, secrets) in [
      (compose, {_password, _token}),
      (environment, {_password}),
    ]) {
      if (payload is DockerStackFileFailed) {
        fail('the stack file read failed: ${payload.failure.name}');
      }
      final file = payload as DockerStackFilePayload;
      expect(file.truncated, isFalse);
      final shown = file.text.map((span) => span.display).join();
      final real = file.text.map((span) => span.reveal() ?? span.display);
      expect(utf8.encode(real.join()), hasLength(file.size));
      for (final secret in secrets) {
        expect(shown, isNot(contains(secret)), reason: file.path);
        expect(
          file.text.where((span) => span.isMasked).map((s) => s.reveal()),
          contains(contains(secret)),
          reason: file.path,
        );
      }
    }
    final shown = (compose as DockerStackFilePayload).text
        .map((span) => span.display)
        .join();
    expect(shown, contains('- DB_PASSWORD=${MaskedValue.maskToken}'));
    expect(shown, contains('fixture.api-token: ${MaskedValue.maskToken}'));
  });

  test('a user outside the docker group is denied, which the access '
      'check explains', () async {
    final engine = await start('docker denied', serverId: noSocketServer);
    final profile = await probed(engine, noSocketServer);

    final payload = await query(
      engine,
      const DockerEngineQuery(),
      serverId: noSocketServer,
    );

    expect(
      payload,
      isA<DockerQueryFailed>().having(
        (f) => f.failure,
        'failure',
        DockerQueryFailure.endpointUnavailable,
      ),
    );
    // The state that says why goes out before the waiting query's
    // answer, so the query has already read it.
    final failed = engine.seen.whereType<DockerEndpointState>().lastWhere(
      (e) =>
          e.serverId == noSocketServer &&
          e.phase != DockerEndpointPhase.resolving,
    );
    expect(failed.phase, DockerEndpointPhase.failed);
    expect(failed.failure, DockerEndpointFailure.noRoute);
    // The host has no sudo, so admin mode would not help either.
    expect(failed.noRouteReason, DockerNoRouteReason.socketDenied);
    expect(failed.label, DockerRouteLabel.none);

    final socket = evaluateAccess(profile.profile).row(AccessItem.dockerSocket);
    expect(socket.status, AccessStatus.missing);
    expect(socket.reason, AccessReason.socketNotWritable);
    expect(socket.rootEquivalent, isTrue);
    expect(socket.fix?.argv, contains('docker'));
  });

  test('a 1,000 lines/s container follow keeps up without losing a '
      'line', () async {
    final engine = await start('docker follow rate');
    const name = 'klab-firehose';
    await runContainer(name, _firehoseScript);
    final streamId = follow(engine, name);
    await engine.until<LogStreamState>(
      (e) => e.streamId == streamId && e.status is LogStreamRunning,
    );

    final clock = Stopwatch()..start();
    final measured = <(int, DateTime, DateTime)>[];
    var dropped = 0;
    var batches = 0;
    int? previous;
    var missing = 0;
    var duplicates = 0;
    void onEvent(EngineEvent event) {
      if (event is LogStreamState && event.streamId == streamId) {
        if (event.status case LogStreamEnded(:final reason, :final detail)) {
          fail('the follow ended: ${reason.name} ($detail)');
        }
      }
      if (event is! LogBatch || event.streamId != streamId) return;
      final received = DateTime.now();
      final counted = clock.elapsed >= _firehoseWarmUp;
      if (counted) {
        dropped += event.dropped;
        batches++;
      }
      for (final record in event.records) {
        final seq = sequence(record, 'firehose');
        if (previous case final p? when counted) {
          if (seq <= p) duplicates++;
          if (seq > p + 1) missing += seq - p - 1;
        }
        previous = seq;
        if (counted) {
          measured.add((seq, (record as ContainerRecord).at!, received));
        }
      }
    }

    await engine.pump(_firehoseWarmUp + _firehoseWindow, onEvent);
    engine.send(CloseStream(streamId));

    expect(measured, isNotEmpty);
    final window =
        measured.last.$3.difference(measured.first.$3).inMicroseconds / 1e6;
    final written =
        measured.last.$2.difference(measured.first.$2).inMicroseconds / 1e6;
    final latencies = [
      for (final (_, at, received) in measured)
        received.difference(at).inMicroseconds / 1000,
    ]..sort();
    double percentile(double p) =>
        latencies[math.min(latencies.length - 1, (latencies.length * p) ~/ 1)];
    final numbers = {
      'targetLinesPerSecond': _firehoseRate,
      'windowSeconds': window,
      'linesDelivered': measured.length,
      'deliveredLinesPerSecond': (measured.length - 1) / window,
      'writtenLinesPerSecond': (measured.last.$1 - measured.first.$1) / written,
      'batches': batches,
      'dropped': dropped,
      'missing': missing,
      'duplicates': duplicates,
      'latencyMs': {
        'p50': percentile(0.5),
        'p95': percentile(0.95),
        'p99': percentile(0.99),
        'max': latencies.last,
      },
      'route': '${endpointStates(engine).last.route?.rank.name}',
      'api': '${endpointStates(engine).last.negotiatedApi}',
    };
    final report = const JsonEncoder.withIndent('  ').convert(numbers);
    engine.note('! follow rate $report');
    if (!await fixture.writeEvidence('docker-follow.json', report)) {
      // Without an evidence directory the numbers still show locally.
      print(report);
    }

    expect(numbers['writtenLinesPerSecond'] as double, greaterThan(900));
    expect(dropped, 0);
    expect(missing, 0);
    expect(duplicates, 0);
    // Every line delivered: the follow keeps pace with the writer.
    expect(
      numbers['deliveredLinesPerSecond'] as double,
      closeTo(numbers['writtenLinesPerSecond'] as double, 50),
    );
    // Batches go out every 50 ms at most; a second at p95 means a lag.
    expect(percentile(0.95), lessThan(1000));
  });

  test('a restarted Docker host reconnects, and the events stream resumes '
      'with since', () async {
    final engine = await start('docker events resume');
    engine.send(
      const DockerWatch(
        serverId: dockerServer,
        watchId: 'containers',
        lists: {DockerWatchList.containers},
      ),
    );
    await listChanged(engine, DockerWatchList.containers);

    // An event the stream has seen gives the resume a point to start
    // from.
    await runContainer('klab-e2e-before', 'sleep 600');
    await listChanged(
      engine,
      DockerWatchList.containers,
      test: (event) => _names(event).contains('klab-e2e-before'),
    );

    // compose restart in two steps, so a container starts while the host
    // is down and only a resumed stream can report it.
    engine.note('! compose stop docker-sshd');
    await fixture.compose(['stop', FixtureService.dockerHost.composeName]);
    var stopped = true;
    addTearDown(() async {
      if (stopped) {
        await fixture.compose(['start', FixtureService.dockerHost.composeName]);
      }
    });
    await engine.until<LinkState>(
      (e) => e.serverId == dockerServer && e.status is LinkClosed,
    );
    final mark = engine.seen.length;
    await runContainer('klab-e2e-during', 'sleep 600');
    engine.note('! compose start docker-sshd');
    await fixture.compose(['start', FixtureService.dockerHost.composeName]);
    stopped = false;

    await engine.until<LinkState>(
      (e) => e.serverId == dockerServer && e.status == const LinkReady(),
      _redialWait,
    );
    final resumed = await listChanged(
      engine,
      DockerWatchList.containers,
      test: (event) => _names(event).contains('klab-e2e-during'),
    );
    expect(resumed.fullRelist, isFalse);
    expect(
      engine.seen
          .skip(mark)
          .whereType<DockerListChanged>()
          .map((e) => e.fullRelist),
      everyElement(isFalse),
      reason: 'a stream that resumes with since lists nothing in full',
    );
    expect(endpointStates(engine).last.route?.rank, DockerRank.streamlocal);
  });

  test('a log follow resumes across a Docker host restart with no line '
      'lost or repeated', () async {
    final engine = await start('docker follow resume');
    const name = 'klab-ticker';
    await runContainer(name, _tickerScript);
    final streamId = follow(engine, name, window: 500);

    // From every batch read, those the waits for other events read too.
    Iterable<LogBatch> batches() =>
        engine.seen.whereType<LogBatch>().where((b) => b.streamId == streamId);
    List<int> seqs() => [
      for (final batch in batches())
        for (final record in batch.records) sequence(record, 'tick'),
    ];
    Future<void> collectUntil(
      bool Function(List<int> seqs) done, [
      Duration timeout = const Duration(seconds: 30),
    ]) async {
      while (!done(seqs())) {
        await engine.until<LogBatch>((e) => e.streamId == streamId, timeout);
      }
    }

    await collectUntil((seqs) => seqs.length >= 20);
    final mark = engine.seen.length;
    engine.note('! compose restart docker-sshd');
    await fixture.compose(['restart', FixtureService.dockerHost.composeName]);
    await engine.until<LinkState>(
      (e) => e.serverId == dockerServer && e.status == const LinkReady(),
      _redialWait,
    );
    final last = seqs().last;
    // The ticker wrote on while the host was down: lines past the restart
    // and past the redial show the follow read them all.
    await collectUntil((seqs) => seqs.last >= last + 50, _redialWait);
    engine.send(CloseStream(streamId));

    final statuses = [
      for (final event in engine.seen.skip(mark))
        if (event is LogStreamState && event.streamId == streamId) event.status,
    ];
    expect(
      statuses,
      containsAllInOrder([
        const LogStreamWaiting(LogStreamWaitReason.link),
        const LogStreamRunning(),
      ]),
    );
    expect(statuses, isNot(contains(isA<LogStreamEnded>())));
    expect(batches().map((b) => b.dropped), everyElement(0));
    final received = seqs();
    expect(received, [
      for (var i = 0; i < received.length; i++) received.first + i,
    ]);
  });
}

/// The container names [event]'s list holds.
Set<String?> _names(DockerListChanged event) => {
  for (final c in (event.payload as DockerContainersPayload).containers) c.name,
};

/// [value] masks [secret] behind the mask token.
void _expectSecret(MaskedValue? value, String secret) {
  expect(value, isNotNull);
  expect(value!.isMasked, isTrue, reason: 'shown as ${value.display}');
  expect(value.display, isNot(contains(secret)));
  expect(value.reveal(), contains(secret));
}

/// A shell on the Docker host as the fixture user, beside the engine: the
/// way a person changes the engine while the app watches.
final class _DockerHostShell {
  _DockerHostShell._(this._link);

  final SshLink _link;

  static Future<_DockerHostShell> connect(
    Fixture fixture,
    Map<Endpoint, Set<String>> hostKeys,
  ) async {
    final link = await SshLink.connect(
      config: ServerConfig(
        id: 'docker-host-shell',
        label: 'docker host',
        host: fixture.dockerHost.host,
        port: fixture.dockerHost.port,
        username: fixture.user,
        authMethod: AuthMethod.privateKey,
        identityFilePath: fixture.identityFile,
        createdAt: 0,
        updatedAt: 0,
      ),
      credentials: SshCredentials.privateKey(
        await File(fixture.identityFile).readAsString(),
      ),
      tofu: TofuVerifier(InMemoryHostKeyStore()),
      onHostKey: (decision) async =>
          decision.verdict == HostKeyVerdict.firstUse &&
          (hostKeys[fixture.dockerHost] ?? const {}).contains(
            decision.presented.fingerprintSha256,
          ),
    );
    addTearDown(link.close);
    return _DockerHostShell._(link);
  }

  /// Runs [command]; a failure fails the test.
  Future<String> run(String command) async {
    final result = await _link.run(command);
    if (result.exitCode != 0) {
      fail('`$command` exited ${result.exitCode}: ${result.stderr}');
    }
    return result.stdout;
  }
}
