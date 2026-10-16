// The replay engine of the app's frame-timing test (spike S5 part 2, 03
// §11.4), driven through the production client as the app drives it: the
// fleet it serves, the samples it reads for the monitored streams and the
// subscriptions, its follows and windows, and a clean exit.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/replay.dart';
import 'package:klabautermann_core/src/links/channel_quota.dart'
    show ChannelShare;
import 'package:klabautermann_core/src/logs/log_stream_router.dart'
    show kLogStreamsPerServerMax;
import 'package:klabautermann_core/src/replay/fixture_replay.dart'
    show nextGridRead;
import 'package:test/test.dart';

import '../../tool/src/engine_budget.dart' show findHostFixtures;

void main() {
  late List<HostFixture> fixtures;
  late List<String> journalRows;
  late ReplayPlan plan;
  late IsolateEngineClient client;
  late List<EngineEvent> events;

  setUpAll(() {
    final root = findHostFixtures()!;
    fixtures = loadHostFixtures(root);
    journalRows = loadJournalRows(root);
  });

  Future<void> spawn({
    int hosts = 1,
    Set<SampleStream>? monitored,
    int logLinesPerSecond = 1000,
    void Function(EngineStart start) Function(ReplayPlan plan) engine =
        replayEngine,
  }) async {
    plan = ReplayPlan(
      fixtures: fixtures,
      journalRows: journalRows,
      hosts: hosts,
      monitored: monitored ?? const {},
      logLinesPerSecond: logLinesPerSecond,
    );
    client = await IsolateEngineClient.spawn(
      supportDirectory: Directory.systemTemp.path,
      entryPoint: engine(plan),
    );
    events = [];
    client.events.listen(events.add);
    addTearDown(client.shutdown);
  }

  Future<void> until(
    bool Function() done,
    String what, {
    Duration within = const Duration(seconds: 5),
  }) async {
    final clock = Stopwatch()..start();
    while (!done()) {
      if (clock.elapsed > within) fail('no $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Iterable<Sample> samples(String serverId) =>
      events.whereType<Sample>().where((s) => s.serverId == serverId);

  LogStreamSpec spec({
    bool follow = true,
    LogSource? source,
    String? id,
    int window = 2,
  }) => LogStreamSpec(
    serverId: id ?? 'replay-0',
    source: source ?? const JournalLogSource(),
    window: window,
    follow: follow,
  );
  List<LogStreamStatus> states(String streamId) => [
    for (final e in events.whereType<LogStreamState>())
      if (e.streamId == streamId) e.status,
  ];
  List<LogBatch> batches(String streamId) => events
      .whereType<LogBatch>()
      .where((b) => b.streamId == streamId)
      .toList();
  List<String> rejections() => [
    for (final e in events.whereType<RequestRejected>()) e.reason,
  ];

  test('serves the fleet linked and probed, and samples each server\'s '
      'monitored streams', () async {
    await spawn(hosts: 2, monitored: const {SampleStream.core});
    await until(
      () => samples('replay-1').isNotEmpty,
      'core sample of the second server',
    );
    // The second server's first read waits half the 2 s period, by the
    // engine's clock; the bound leaves room for a slow first step.
    expect(
      samples('replay-1').first.at.difference(samples('replay-0').first.at),
      greaterThanOrEqualTo(const Duration(milliseconds: 500)),
    );

    final fleet = events.whereType<CatalogReplaced>().single.entries;
    expect([for (final e in fleet) e.serverId], ['replay-0', 'replay-1']);
    expect(fleet[1].label, '${fixtures[1].platform}-1');
    for (final id in ['replay-0', 'replay-1']) {
      expect(
        events,
        containsAll([
          isA<LinkState>()
              .having((e) => e.serverId, 'serverId', id)
              .having((e) => e.status, 'status', const LinkReady()),
          isA<Reachability>().having((e) => e.serverId, 'serverId', id),
          isA<HostProfileChanged>()
              .having((e) => e.serverId, 'serverId', id)
              .having((e) => e.cachedAt, 'cachedAt', isNull),
          isA<SamplingState>()
              .having((e) => e.serverId, 'serverId', id)
              .having((e) => e.phase, 'phase', SamplingPhase.sampling),
        ]),
      );
      final first = samples(id).first;
      expect(first.stream, SampleStream.core);
      expect(first.result, isA<CoreResult>());
    }
  });

  test('reads what a view subscribes at once, identity once, until it '
      'unsubscribes', () async {
    await spawn();
    client.send(
      const Subscribe(
        serverId: 'replay-0',
        subscriptionId: 'overview-0',
        streams: {
          SampleStream.core,
          SampleStream.fs,
          SampleStream.identity,
          SampleStream.failedUnits,
        },
      ),
    );
    await until(() => samples('replay-0').length >= 4, 'subscribed samples');
    expect(
      {for (final s in samples('replay-0')) s.stream: s.result.runtimeType},
      {
        SampleStream.core: CoreResult,
        SampleStream.fs: FsResult,
        SampleStream.identity: IdentityResult,
        SampleStream.failedUnits: FailedUnitsResult,
      },
    );

    // Another subscription reads its new stream, not identity again.
    client.send(
      const Subscribe(
        serverId: 'replay-0',
        subscriptionId: 'system-1',
        streams: {SampleStream.identity, SampleStream.procs},
      ),
    );
    await until(
      () => samples('replay-0').any((s) => s.stream == SampleStream.procs),
      'procs sample',
    );
    expect(
      samples('replay-0').where((s) => s.stream == SampleStream.identity),
      hasLength(1),
    );

    client
      ..send(
        const Unsubscribe(serverId: 'replay-0', subscriptionId: 'system-1'),
      )
      ..send(
        const Unsubscribe(serverId: 'replay-0', subscriptionId: 'overview-0'),
      );
    await until(
      () => events.whereType<SamplingState>().any(
        (s) => s.phase == SamplingPhase.unsubscribed,
      ),
      'unsubscribed state',
    );
  });

  test('follows at the plan\'s rate until closed, and ends windows and '
      'files', () async {
    await spawn();
    int records(String streamId) =>
        batches(streamId).fold(0, (n, b) => n + b.records.length);

    client.send(OpenLogStream(streamId: 'log-0', spec: spec()));
    await until(() => records('log-0') > 0, 'follow records');
    // The plan's rate over a measured second, loosely, for a loaded
    // machine's late batches.
    final clock = Stopwatch()..start();
    final from = records('log-0');
    await Future<void>.delayed(const Duration(seconds: 1));
    final perSecond =
        (records('log-0') - from) / (clock.elapsedMicroseconds / 1e6);
    expect(
      perSecond,
      inInclusiveRange(
        plan.logLinesPerSecond * 0.5,
        plan.logLinesPerSecond * 1.5,
      ),
    );
    expect(states('log-0'), [const LogStreamRunning()]);
    expect(batches('log-0').first.records.first, isA<JournalRecord>());

    client.send(const CloseStream('log-0'));
    await until(() => states('log-0').length == 2, 'closed state');
    expect(
      states('log-0').last,
      const LogStreamEnded(LogStreamEndReason.closed),
    );
    final sent = batches('log-0').length;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(batches('log-0'), hasLength(sent));

    client
      ..send(OpenLogStream(streamId: 'log-1', spec: spec(follow: false)))
      ..send(
        OpenLogStream(
          streamId: 'log-2',
          spec: spec(source: const FileLogSource('/var/log/syslog')),
        ),
      )
      ..send(
        OpenLogStream(
          streamId: 'log-4',
          spec: spec(follow: false, window: journalRows.length + 1),
        ),
      );
    await until(() => states('log-4').length == 2, 'whole-journal window');
    // A window of 2 leaves older rows; one larger than the journal reads
    // them all (protocol.dart's LogStreamEndReason).
    String? cursor(String row) =>
        (jsonDecode(row) as Map<String, Object?>)['__CURSOR'] as String?;
    expect(
      [
        for (final record in batches('log-1').single.records)
          (record as JournalRecord).cursor,
      ],
      [for (final row in journalRows.reversed.take(2)) cursor(row)],
    );
    expect(states('log-1'), [
      const LogStreamRunning(),
      const LogStreamEnded(LogStreamEndReason.windowFilled),
    ]);
    expect(batches('log-4').single.records, hasLength(journalRows.length));
    expect(states('log-4'), [
      const LogStreamRunning(),
      const LogStreamEnded(LogStreamEndReason.oldestReached),
    ]);
    expect(states('log-2'), [const LogStreamEnded(LogStreamEndReason.missing)]);
  });

  test('rejects an open as the engine\'s router does, and ends a window '
      '03 §8.8 refuses at once', () async {
    await spawn(logLinesPerSecond: 1);
    client
      ..send(OpenLogStream(streamId: 'log-0', spec: spec(follow: false)))
      ..send(OpenLogStream(streamId: 'log-0', spec: spec()))
      ..send(
        OpenLogStream(
          streamId: 'log-1',
          spec: spec(id: 'nowhere'),
        ),
      )
      ..send(
        OpenLogStream(streamId: 'log-2', spec: spec(follow: false, window: 0)),
      );
    for (var i = 0; i < kLogStreamsPerServerMax; i++) {
      client.send(OpenLogStream(streamId: 'follow-$i', spec: spec()));
    }
    client.send(OpenLogStream(streamId: 'follow-last', spec: spec()));
    await until(() => rejections().length == 3, 'rejections');

    expect(rejections(), [
      'stream id log-0 was used before',
      'no fleet server nowhere',
      'replay-0 holds $kLogStreamsPerServerMax log streams',
    ]);
    expect(states('log-0'), hasLength(2));
    expect(states('log-1'), isEmpty);
    expect(states('log-2'), [const LogStreamEnded(LogStreamEndReason.invalid)]);
    expect(states('follow-last'), isEmpty);

    // A closed stream leaves room for another, waiting ones counted, but
    // its id stays used.
    client
      ..send(const CloseStream('follow-0'))
      ..send(OpenLogStream(streamId: 'follow-0', spec: spec()))
      ..send(OpenLogStream(streamId: 'follow-again', spec: spec()));
    await until(() => states('follow-again').isNotEmpty, 'the room left');
    expect(rejections().last, 'stream id follow-0 was used before');
    expect(states('follow-again'), [
      const LogStreamWaiting(LogStreamWaitReason.channel),
    ]);
  });

  test('Disconnect ends its server\'s streams as failed, and Shutdown '
      'every stream before the engine exits', () async {
    await spawn(hosts: 2, logLinesPerSecond: 1);
    client
      ..send(OpenLogStream(streamId: 'log-0', spec: spec()))
      ..send(
        OpenLogStream(
          streamId: 'log-1',
          spec: spec(id: 'replay-1'),
        ),
      )
      ..send(const Disconnect('nowhere'))
      ..send(const Disconnect('replay-0'));
    await until(() => states('log-0').length == 2, 'the disconnected end');
    expect(states('log-0'), [
      const LogStreamRunning(),
      const LogStreamEnded(LogStreamEndReason.failed),
    ]);
    expect(states('log-1'), [const LogStreamRunning()]);
    // The engine ignores a Disconnect of a server outside the fleet.
    expect(rejections(), isEmpty);

    // Shutdown completes once its events stream closed.
    await client.shutdown();
    expect(states('log-1'), [
      const LogStreamRunning(),
      const LogStreamEnded(LogStreamEndReason.failed),
    ]);
  });

  test('the background pauses follows and holds new streams; the '
      'foreground runs them from their start, paused ones first', () async {
    await spawn();
    client.send(OpenLogStream(streamId: 'log-0', spec: spec()));
    await until(() => batches('log-0').isNotEmpty, 'follow batches');

    client
      ..send(const SetAppActivity(AppActivity.background))
      ..send(OpenLogStream(streamId: 'log-1', spec: spec()))
      ..send(OpenLogStream(streamId: 'log-2', spec: spec(follow: false)));
    await until(() => states('log-2').isNotEmpty, 'the waiting window');
    const background = LogStreamWaiting(LogStreamWaitReason.background);
    expect(states('log-0'), [const LogStreamRunning(), background]);
    expect(states('log-1'), [background]);
    expect(states('log-2'), [background]);
    final paused = batches('log-0').length;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(batches('log-0'), hasLength(paused));

    client.send(const SetAppActivity(AppActivity.foreground));
    await until(
      () => batches('log-0').length > paused && batches('log-1').isNotEmpty,
      'follow batches after the return',
    );
    expect(
      [
        for (final e in events.whereType<LogStreamState>())
          if (e.status == const LogStreamRunning()) e.streamId,
      ],
      ['log-0', 'log-0', 'log-1', 'log-2'],
    );
    expect(states('log-2').last, isA<LogStreamEnded>());
  });

  test('a server runs as many follows as its share allows; the next waits '
      'for a channel until one ends', () async {
    await spawn(hosts: 2, logLinesPerSecond: 1);
    final share = ChannelShare.follower.limit;
    for (var i = 0; i <= share; i++) {
      client.send(OpenLogStream(streamId: 'follow-$i', spec: spec()));
    }
    client
      ..send(
        OpenLogStream(
          streamId: 'other',
          spec: spec(id: 'replay-1'),
        ),
      )
      ..send(OpenLogStream(streamId: 'window', spec: spec(follow: false)));
    // The window's end is a message of its own after its start, so wait
    // for both; the earlier opens' states arrived before either.
    await until(() => states('window').length == 2, 'the window');
    for (var i = 0; i < share; i++) {
      expect(states('follow-$i'), [const LogStreamRunning()]);
    }
    const channel = LogStreamWaiting(LogStreamWaitReason.channel);
    expect(states('follow-$share'), [channel]);
    expect(states('other'), [const LogStreamRunning()]);
    expect(states('window'), [
      const LogStreamRunning(),
      const LogStreamEnded(LogStreamEndReason.windowFilled),
    ]);

    client.send(const CloseStream('follow-0'));
    await until(() => states('follow-$share').length == 2, 'the freed slot');
    expect(states('follow-$share'), [channel, const LogStreamRunning()]);
  });

  test('a late read keeps its period\'s grid, skipping the slots it '
      'passed (03 §6.2)', () {
    const period = Duration(seconds: 2);
    Duration next(int ms) => nextGridRead(
      const Duration(seconds: 1),
      period,
      Duration(milliseconds: ms),
    );

    expect(next(1000), const Duration(seconds: 3));
    expect(next(2990), const Duration(seconds: 3));
    expect(next(3000), const Duration(seconds: 5));
    expect(next(7500), const Duration(seconds: 9));
  });

  test('a read a period late resumes on its grid', () async {
    await spawn(monitored: const {SampleStream.core}, engine: _stalled);
    await until(
      () => samples('replay-0').length >= 3,
      'core samples around the stall',
      within: const Duration(seconds: 10),
    );
    final [first, late, next, ...] = [
      for (final sample in samples('replay-0')) sample.at,
    ];
    // Due at 2 s, the read ran past 4 s: the next is the 6 s slot, not
    // a period after the late read (about 6.9 s). The bounds leave room
    // for a slow first step.
    expect(
      late.difference(first),
      greaterThan(_stall - const Duration(milliseconds: 100)),
    );
    expect(next.difference(first).inMilliseconds, inInclusiveRange(5500, 6500));
  });

  test('rejects what it does not serve and exits on shutdown', () async {
    await spawn();
    client
      ..send(const Connect('replay-0'))
      ..send(const Connect('nowhere'))
      ..send(const ImportSshConfig('Host a'));
    await until(
      () => events.whereType<RequestRejected>().length == 2,
      'rejections',
    );
    expect(
      [for (final e in events.whereType<RequestRejected>()) e.requestName],
      ['Connect', 'ImportSshConfig'],
    );

    // IsolateEngineClient kills an engine that has not exited within 2 s.
    await client.shutdown().timeout(const Duration(seconds: 1));
  });
}

/// How long [_stalled] blocks its engine: from the first `core` read to
/// half way between the 4 s and 6 s slots, so the read due at 2 s runs
/// over a period late.
const _stall = Duration(milliseconds: 4900);

/// A replay engine over [plan] whose isolate blocks for [_stall] once its
/// first sample is out, as an engine busy elsewhere would. Its events
/// reach the client through a port of its own, which watches for that
/// sample.
void Function(EngineStart start) _stalled(ReplayPlan plan) => (start) {
  final relay = RawReceivePort();
  var stalled = false;
  relay.handler = (Object? message) {
    start.uiPort.send(message);
    if (stalled || message is! Sample) return;

    stalled = true;
    sleep(_stall);
  };
  replayEngine(plan)(
    EngineStart(
      uiPort: relay.sendPort,
      supportDirectory: start.supportDirectory,
    ),
  );
};
