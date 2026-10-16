// The replay engine of the app's frame-timing test (spike S5 part 2, 03
// §11.4), driven through the production client as the app drives it: the
// fleet it serves, the samples it reads for the monitored streams and the
// subscriptions, its follows and windows, and a clean exit.
import 'dart:async';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/replay.dart';
import 'package:test/test.dart';

import '../../tool/src/engine_budget.dart' show findHostFixtures;

void main() {
  late List<HostFixture> fixtures;
  late List<String> journalRows;
  late IsolateEngineClient client;
  late List<EngineEvent> events;

  setUpAll(() {
    final root = findHostFixtures()!;
    fixtures = loadHostFixtures(root);
    journalRows = loadJournalRows(root);
  });

  Future<void> spawn({int hosts = 1, Set<SampleStream>? monitored}) async {
    final plan = ReplayPlan(
      fixtures: fixtures,
      journalRows: journalRows,
      hosts: hosts,
      monitored: monitored ?? const {},
    );
    client = await IsolateEngineClient.spawn(
      supportDirectory: Directory.systemTemp.path,
      entryPoint: replayEngine(plan),
    );
    events = [];
    client.events.listen(events.add);
    addTearDown(client.shutdown);
  }

  Future<void> until(bool Function() done, String what) async {
    final clock = Stopwatch()..start();
    while (!done()) {
      if (clock.elapsed > const Duration(seconds: 5)) fail('no $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Iterable<Sample> samples(String serverId) =>
      events.whereType<Sample>().where((s) => s.serverId == serverId);

  test('serves the fleet linked and probed, and samples each server\'s '
      'monitored streams', () async {
    await spawn(hosts: 2, monitored: const {SampleStream.core});
    // The second server's first read waits half the 2 s period.
    await until(
      () => samples('replay-1').isNotEmpty,
      'core sample of the second server',
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
          isA<HostProfileChanged>().having((e) => e.serverId, 'serverId', id),
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

  test('follows at the plan\'s rate until closed, and ends windows, files '
      'and unknown servers', () async {
    await spawn();
    LogStreamSpec spec({bool follow = true, LogSource? source, String? id}) =>
        LogStreamSpec(
          serverId: id ?? 'replay-0',
          source: source ?? const JournalLogSource(),
          window: 2,
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

    client.send(OpenLogStream(streamId: 'log-0', spec: spec()));
    await until(
      () => batches('log-0').fold(0, (n, b) => n + b.records.length) >= 200,
      'follow records',
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
          streamId: 'log-3',
          spec: spec(id: 'nowhere'),
        ),
      );
    await until(() => states('log-3').isNotEmpty, 'unknown server state');
    expect(batches('log-1').single.records, hasLength(2));
    expect(states('log-1'), [
      const LogStreamRunning(),
      const LogStreamEnded(LogStreamEndReason.oldestReached),
    ]);
    expect(states('log-2'), [const LogStreamEnded(LogStreamEndReason.missing)]);
    expect(states('log-3'), [const LogStreamEnded(LogStreamEndReason.invalid)]);
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
