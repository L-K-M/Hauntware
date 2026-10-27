// The engine's Docker reads on the Docker host's negative sshd variants
// (03 §5.2, §5.9, §11.3; M3 D22, exits E3 and E4): the real engine in its
// own isolate, links on, over an imported ssh_config naming one variant.
// Each variant that refuses streamlocal falls back to rank 2, the docker
// CLI relay, over which the lists, a log follow and list stats still
// work; `MaxSessions 2` puts the endpoint in low-session mode; and an
// account with no engine CLI and no relay lands on none with its reason.
// Every test checks the header label (E4) and writes what it saw to
// $KLABAUTERMANN_EVIDENCE_DIR/fixture/fallback/. run.sh starts and seeds
// the fixture; without it these skip.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// The image seed_docker.sh tags, which every container here runs.
const _image = 'klabautermann-fixture/busybox:1.37';

/// The engine's first candidate path (03 §5.4) on the Docker host.
const _socket = '/var/run/docker.sock';

/// dind's own socket, for the tests' side channel into the engine.
const _dindSocket = 'unix:///run/docker-fixture/docker.sock';

/// The account in the Docker host's `docker` group whose PATH has no
/// engine CLI (`sshd/nocli-shell.sh`), and no socat or `nc -U` either.
const _noCliUser = 'klab-nocli';

/// DKE-02's budget from a container's start to the list that shows it
/// [E], which the events stream meets on a relay as on streamlocal.
const _listChangeBudget = Duration(seconds: 2);

/// Covers the stack checks: a `test -f` exec, the compose CLI's
/// detection and `compose config --hash`, each up to 30 s [E].
const _verifyWait = Duration(seconds: 90);

/// Writes ten numbered lines a second.
const _tickerScript =
    r'n=0; while :; do echo "tick $n"; n=$((n + 1)); usleep 100000; done';

/// A Docker-host variant that refuses `direct-streamlocal` to the
/// socket, as docker_refusal_test.dart records, and the setting that
/// does.
typedef _RelayVariant = ({FixtureService service, String setting});

const _relayVariants = <_RelayVariant>[
  (
    service: FixtureService.noStreamlocal,
    setting: 'AllowStreamLocalForwarding no',
  ),
  (service: FixtureService.disableForwarding, setting: 'DisableForwarding yes'),
  (service: FixtureService.noTcp, setting: 'AllowTcpForwarding no'),
  (service: FixtureService.permitOpen, setting: 'PermitOpen 127.0.0.1:1'),
  (service: FixtureService.restrict, setting: 'authorized_keys restrict'),
];

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the Docker fallback suite', () {}, skip: fixtureSkipReason);
    return;
  }

  var queries = 0;

  /// Starts an engine on [service] as [user], connects it with a
  /// sampling subscription, as a Docker view's server is, and waits for
  /// its capability probe, which the ladder reads.
  Future<(FixtureEngine, HostProfile)> start(
    String name,
    FixtureService service, {
    String? user,
  }) async {
    final (engine, hostKeys) = await FixtureEngine.startDockerVariant(
      fixture,
      name,
      service,
      user: user ?? fixture.user,
    );
    await engine.connect(variantServer, hostKeys);
    await engine.subscribe(variantServer, {SampleStream.core});
    final probed = await engine.until<HostProfileChanged>(
      (e) => e.serverId == variantServer && e.cachedAt == null,
    );
    return (engine, probed.profile);
  }

  /// Sends [spec] and returns its answer.
  Future<DockerPayload> query(
    FixtureEngine engine,
    DockerQuerySpec spec,
  ) async {
    final queryId = 'query-${queries++}';
    engine.send(
      DockerQuery(serverId: variantServer, queryId: queryId, query: spec),
    );
    final result = await engine.until<DockerResult>(
      (r) => r.serverId == variantServer && r.queryId == queryId,
    );
    return result.payload;
  }

  /// The endpoint states the engine reported so far.
  List<DockerEndpointState> endpointStates(FixtureEngine engine) => [
    for (final event in engine.seen)
      if (event is DockerEndpointState && event.serverId == variantServer)
        event,
  ];

  /// The [list] events read so far; a failed one fails the test.
  List<DockerListChanged> lists(FixtureEngine engine, DockerWatchList list) => [
    for (final event in engine.seen)
      if (event is DockerListChanged &&
          event.serverId == variantServer &&
          event.list == list)
        if (event.payload case DockerQueryFailed(:final failure, :final detail))
          fail('the ${list.name} list failed: ${failure.name} ($detail)')
        else
          event,
  ];

  /// Reads events until [done] holds over what the engine has seen.
  Future<void> waitFor(
    FixtureEngine engine,
    bool Function() done, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (done()) return;
    await engine.until<EngineEvent>((_) => done(), timeout);
  }

  /// Runs `docker` in dind as root, out of the engine's sight.
  Future<String> dind(List<String> arguments) => fixture.exec(
    FixtureService.dind,
    ['docker', '--host', _dindSocket, ...arguments],
  );

  /// Runs [script] in a new detached container [name], removed when the
  /// test ends, and returns its id.
  Future<String> runContainer(String name, String script) async {
    addTearDown(() => dind(['rm', '--force', name]));
    final id = await dind([
      'run',
      '--detach',
      '--name',
      name,
      _image,
      'sh',
      '-c',
      script,
    ]);
    return id.trim();
  }

  /// The tick numbers [streamId]'s batches carried so far, in order; an
  /// ended stream fails the test.
  List<int> ticks(FixtureEngine engine, String streamId) {
    final seqs = <int>[];
    for (final event in engine.seen) {
      if (event is LogStreamState && event.streamId == streamId) {
        if (event.status case LogStreamEnded(:final reason, :final detail)) {
          fail('the follow ended: ${reason.name} ($detail)');
        }
      }
      if (event is! LogBatch || event.streamId != streamId) continue;
      for (final record in event.records) {
        seqs.add(int.parse((record as ContainerRecord).text.split(' ')[1]));
      }
    }
    return seqs;
  }

  /// Opens a follow of [container]'s log with [window] earlier lines.
  String follow(FixtureEngine engine, String container, {int window = 0}) {
    final streamId = 'follow-$container';
    engine.send(
      OpenLogStream(
        streamId: streamId,
        spec: LogStreamSpec(
          serverId: variantServer,
          source: ContainerLogSource(container),
          window: window,
          follow: true,
        ),
      ),
    );
    return streamId;
  }

  /// Records [details] about [service] for the evidence as [name], the
  /// service's by default, and prints them so the job log carries them
  /// too.
  Future<void> record(
    FixtureService service,
    Map<String, Object?> details, {
    String? name,
  }) async {
    final evidence = const JsonEncoder.withIndent('  ')
        .convert({'service': service.composeName, ...details});
    print(evidence);
    await fixture.writeEvidence(
      'fallback/${name ?? service.composeName}.json',
      '$evidence\n',
    );
  }

  for (final variant in _relayVariants) {
    final service = variant.service;
    test('${variant.setting} (${service.composeName}): rank 2, the docker '
        'CLI relay, carries the lists, a log follow and stats', () async {
      final (engine, profile) = await start(
        'fallback ${service.composeName}',
        service,
      );
      expect(profile.toolPresent('docker'), isTrue);
      final ticker = 'klab-fallback-${service.composeName}';
      final tickerId = await runContainer(ticker, _tickerScript);

      final clock = Stopwatch()..start();
      final listed = await query(engine, const DockerContainersQuery());
      final resolvedMs = clock.elapsedMilliseconds;
      expect(
        (listed as DockerContainersPayload).containers.map((c) => c.name),
        containsAll([ticker, 'demo-web-1', 'coolify-app']),
      );

      final states = endpointStates(engine);
      expect(
        states.map((s) => s.phase),
        isNot(contains(DockerEndpointPhase.failed)),
      );
      final ready = states.last;
      expect(ready.phase, DockerEndpointPhase.ready);
      expect(ready.route?.rank, DockerRank.cliRelay);
      expect(ready.route?.rank.number, 2);
      // E4: 03 §5.9's "via docker CLI relay (limited streams)", which
      // the app words (D12).
      expect(ready.label, DockerRouteLabel.cliRelay);
      expect(ready.route?.socketPath, _socket);
      expect(ready.route?.runtime, EngineRuntime.docker);
      expect(ready.route?.mode, EngineMode.rootful);
      expect(ready.route?.rootEquivalence, DockerRootEquivalence.rootfulSocket);
      expect(ready.negotiatedApi, isNotNull);
      expect(ready.lowSession, isFalse);

      // The events stream and the follow take the relay's two follower
      // slots (M9); the stats go one at a time over the pooled
      // connection.
      clock.reset();
      engine.send(
        DockerWatch(
          serverId: variantServer,
          watchId: 'watch',
          lists: const {DockerWatchList.containers, DockerWatchList.stats},
          statsFor: {tickerId},
        ),
      );
      final streamId = follow(engine, ticker, window: 5);
      await waitFor(
        engine,
        () =>
            lists(engine, DockerWatchList.containers).isNotEmpty &&
            lists(engine, DockerWatchList.stats).length >= 2 &&
            ticks(engine, streamId).length >= 20,
      );
      final watchedMs = clock.elapsedMilliseconds;

      final firstList = lists(engine, DockerWatchList.containers).first;
      expect(firstList.fullRelist, isTrue);
      final received = ticks(engine, streamId);
      expect(received, [
        for (var i = 0; i < received.length; i++) received.first + i,
      ], reason: 'no tick lost or repeated');
      final rounds = [
        for (final event in lists(engine, DockerWatchList.stats))
          (event.payload as DockerStatsPayload).stats.single,
      ];
      expect(rounds.map((s) => s.containerId), everyElement(tickerId));
      expect(rounds.map((s) => s.memoryUsed), everyElement(isPositive));
      // A one-shot read's precpu_stats is zero (03 §5.6), so the CPU %
      // comes from the second round.
      expect(rounds.first.cpuPercent, isNull);
      expect(rounds[1].cpuPercent, isPositive);

      // A container started behind the engine's back reaches the list
      // through the events stream, not a full re-list.
      final added = 'klab-fallback-added-${service.composeName}';
      clock.reset();
      await runContainer(added, 'sleep 600');
      final ranMs = clock.elapsedMilliseconds;
      clock.reset();
      final mark = engine.seen.length;
      await waitFor(
        engine,
        () => lists(
          engine,
          DockerWatchList.containers,
        ).skip(1).any((e) => _names(e).contains(added)),
        timeout: _listChangeBudget,
      );
      final listedMs = clock.elapsedMilliseconds;
      expect(
        engine.seen
            .skip(mark)
            .whereType<DockerListChanged>()
            .where((e) => e.list == DockerWatchList.containers)
            .map((e) => e.fullRelist),
        everyElement(isFalse),
      );
      engine.send(CloseStream(streamId));

      expect(
        endpointStates(engine).last.route?.rank,
        DockerRank.cliRelay,
        reason: 'the relay held throughout',
      );
      await record(service, {
        'setting': variant.setting,
        'phase': ready.phase.name,
        'rank': ready.route?.rank.number,
        'label': ready.label.name,
        'negotiatedApi': '${ready.negotiatedApi}',
        'lowSession': ready.lowSession,
        'resolveAndListMs': resolvedMs,
        'watchFollowStatsMs': watchedMs,
        'ticksReceived': received.length,
        'statsRounds': rounds.length,
        'dockerRunMs': ranMs,
        'listedAfterRunMs': listedMs,
      });
    });
  }

  test('MaxSessions 2 (neg-maxsessions2): rank 1 stays, the learned limit '
      'is low-session mode, and the samplers leave no session for the stack '
      'checks or a host follow', () async {
    const service = FixtureService.maxSessions2;
    final logged = (await fixture.logs(service)).length;
    final (engine, _) = await start('fallback maxsessions2', service);
    await query(engine, const DockerEngineQuery());
    final ready = endpointStates(engine).last;
    expect(ready.phase, DockerEndpointPhase.ready);
    expect(ready.route?.rank, DockerRank.streamlocal);
    expect(ready.label, DockerRouteLabel.socketForward);
    // The two samplers fit. The footprint check each connect runs
    // (SAF-14) needs a third session, which sshd may refuse: then the
    // link has learned its limit already. Otherwise the stack checks run
    // commands: the third session, which sshd refuses, so the link
    // learns its limit.
    final learnedAtConnect = ready.lowSession;
    final clock = Stopwatch()..start();
    engine.send(
      const DockerWatch(
        serverId: variantServer,
        watchId: 'watch',
        lists: {DockerWatchList.containers, DockerWatchList.stacks},
      ),
    );
    final low = learnedAtConnect
        ? ready
        : await engine.until<DockerEndpointState>(
            (e) => e.serverId == variantServer && e.lowSession,
          );
    final learnedMs = clock.elapsedMilliseconds;
    expect(low.phase, DockerEndpointPhase.ready);
    expect(low.route?.rank, DockerRank.streamlocal);
    expect(low.label, DockerRouteLabel.socketForward);
    expect(engine.seen.whereType<LinkState>().last.status, isA<LinkDegraded>());

    // A check that taught the limit runs again at it, where it queues
    // for a session (docker_router.dart). The two samplers hold both for
    // as long as the host is sampled, so no check gets one before the
    // link's open timeout: recorded behaviour, not a wish. That stack
    // reads "check failed" instead of verified. A check that starts at
    // an already learned limit waits for a channel instead (M4 plan M6).
    final settled = anyOf(
      isA<StackUnverified>().having(
        (v) => v.reason,
        'reason',
        StackUnverifiedReason.checkFailed,
      ),
      isA<StackVerifying>().having(
        (v) => v.waiting,
        'waiting',
        StackWait.channel,
      ),
    );
    clock.reset();
    await waitFor(engine, () {
      final stacks = lists(engine, DockerWatchList.stacks);
      if (stacks.isEmpty) return false;
      final verdicts = (stacks.last.payload as DockerStacksPayload).verdicts;
      return verdicts.isNotEmpty &&
          verdicts.values.every((v) => settled.matches(v, {}));
    }, timeout: _verifyWait);
    final checkedMs = clock.elapsedMilliseconds;
    final verdicts =
        (lists(engine, DockerWatchList.stacks).last.payload
                as DockerStacksPayload)
            .verdicts;
    expect(verdicts.keys, containsAll(['demo', 'gone']));
    expect(verdicts.values, everyElement(settled));
    if (!learnedAtConnect) {
      expect(verdicts.values, everyElement(isA<StackUnverified>()));
    }
    expect(
      (await fixture.logs(service)).skip(logged),
      contains('no more sessions'),
      reason: 'sshd refused the third session',
    );

    // Streamlocal costs no session, so the events stream stays and a
    // container follow runs; a host follow gets no channel below a
    // learned limit of 4 (03 §5.2).
    final added = 'klab-fallback-added-${service.composeName}';
    final mark = engine.seen.length;
    clock.reset();
    await runContainer(added, 'sleep 600');
    await waitFor(
      engine,
      () => lists(
        engine,
        DockerWatchList.containers,
      ).skip(1).any((e) => _names(e).contains(added)),
      timeout: _listChangeBudget,
    );
    final listedMs = clock.elapsedMilliseconds;
    expect(
      engine.seen
          .skip(mark)
          .whereType<DockerListChanged>()
          .where((e) => e.list == DockerWatchList.containers)
          .map((e) => e.fullRelist),
      everyElement(isFalse),
    );

    final ticker = 'klab-fallback-${service.composeName}';
    await runContainer(ticker, _tickerScript);
    final container = follow(engine, ticker);
    engine.send(
      OpenLogStream(
        streamId: 'host-follow',
        spec: LogStreamSpec(
          serverId: variantServer,
          source: const FileLogSource('/etc/hostname'),
          window: 0,
          follow: true,
        ),
      ),
    );
    await waitFor(engine, () => ticks(engine, container).length >= 10);
    final hostStatuses = [
      for (final event in engine.seen)
        if (event is LogStreamState && event.streamId == 'host-follow')
          event.status,
    ];
    expect(hostStatuses, [const LogStreamWaiting(LogStreamWaitReason.channel)]);
    engine
      ..send(CloseStream(container))
      ..send(const CloseStream('host-follow'));
    expect(endpointStates(engine).last.lowSession, isTrue);

    await record(service, {
      'setting': 'MaxSessions 2',
      'rank': low.route?.rank.number,
      'label': low.label.name,
      'lowSession': low.lowSession,
      'learnedAfterStacksWatchMs': learnedMs,
      'stackVerdicts': {
        for (final MapEntry(:key, :value) in verdicts.entries)
          key: value is StackUnverified
              ? value.reason.name
              : '${value.runtimeType}',
      },
      'stacksCheckedMs': checkedMs,
      'listedAfterRunMs': listedMs,
      'hostFollow': [
        for (final status in hostStatuses)
          if (status case LogStreamWaiting(:final reason))
            'waiting ${reason.name}'
          else
            '${status.runtimeType}',
      ],
      'containerFollowTicks': ticks(engine, container).length,
    });
  });

  test('an account with no engine CLI, socat or nc -U '
      '(neg-nostreamlocal) lands on none: no relay', () async {
    const service = FixtureService.noStreamlocal;
    final (engine, profile) = await start(
      'fallback nocli',
      service,
      user: _noCliUser,
    );
    expect(profile.toolPresent('docker'), isFalse);
    expect(profile.toolPresent('podman'), isFalse);
    expect(profile.toolPresent('socat'), isFalse);

    final payload = await query(engine, const DockerEngineQuery());
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
          e.serverId == variantServer &&
          e.phase != DockerEndpointPhase.resolving,
    );
    expect(failed.phase, DockerEndpointPhase.failed);
    expect(failed.failure, DockerEndpointFailure.noRoute);
    // BusyBox's nc has no -U, so the ladder offers no `nc -U` relay that
    // would fail at its first request (docker_ladder.dart).
    expect(failed.noRouteReason, DockerNoRouteReason.noRelay);
    // E4: no route, Docker panels hidden with the reason.
    expect(failed.label, DockerRouteLabel.none);
    expect(failed.route, isNull);
    expect(endpointStates(engine).map((s) => s.phase), [
      DockerEndpointPhase.resolving,
      DockerEndpointPhase.failed,
    ], reason: 'one resolution, no relay tried and dropped');

    await record(service, {
      'user': _noCliUser,
      'phase': failed.phase.name,
      'failure': failed.failure?.name,
      'noRouteReason': failed.noRouteReason?.name,
      'label': failed.label.name,
    }, name: '${service.composeName}-$_noCliUser');
  });
}

/// The container names [event]'s list holds.
Set<String?> _names(DockerListChanged event) => {
  for (final c in (event.payload as DockerContainersPayload).containers) c.name,
};
