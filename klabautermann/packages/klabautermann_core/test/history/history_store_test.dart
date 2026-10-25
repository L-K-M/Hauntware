// HIS-01's on-device history (03 §7.20): readings rolled into 1-minute
// and 10-minute buckets with min, max, mean and count, the gaps the
// engine saw, rings that survive a restart, and purges with the fleet.
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/capabilities/capability_cache.dart'
    show CachePurge;
import 'package:klabautermann_core/src/history/history_store.dart';
import 'package:test/test.dart';

const _web = '6f1c2b8e-5d0a-4e7f-9b3c-1a2d3e4f5a6b';
const _db = '0b9a8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d';

final _t0 = DateTime.utc(2026, 10, 25, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

OverviewResult _cpu(double busy) =>
    OverviewResult(cpu: CpuPercentages(const [], busy));

FsResult _disk(int used, int inodes) => FsResult(
  FsSnapshot([
    FsMount(
      device: '/dev/sda1',
      type: 'ext4',
      mountPoint: '/',
      capacityPercent: used,
      inodeUsePercent: inodes,
    ),
  ]),
);

void main() {
  group('rollups', () {
    late HistoryStore history;

    setUp(() => history = HistoryStore.inMemory());

    test(
      'readings roll into 1-minute buckets, the filling one included',
      () async {
        history
          ..observe(_web, _cpu(10), _at(0))
          ..observe(_web, _cpu(30), _at(30))
          ..observe(_web, _cpu(50), _at(65));

        final range = await history.read(
          _web,
          HistoryTier.minute,
          now: _at(70),
        );
        expect([for (final b in range.buckets) b.start], [_at(0), _at(60)]);
        final first = range.buckets.first.values[AlertMetric.cpuBusy]!;
        expect(
          (first.min, first.max, first.mean, first.count),
          (10, 30, 20, 2),
        );
        expect(range.buckets.first.provenance, HistoryProvenance.liveSampler);
        expect(range.buckets.last.values[AlertMetric.cpuBusy]!.count, 1);
        // A metric no reading carried is absent, never zero.
        expect(
          range.buckets.first.values,
          isNot(contains(AlertMetric.diskUsed)),
        );
      },
    );

    test('written minutes fold into the 10-minute bucket as a session '
        'rollup', () async {
      for (var minute = 0; minute < 11; minute++) {
        history.observe(_web, _cpu(minute * 10.0), _at(minute * 60));
      }

      final range = await history.read(
        _web,
        HistoryTier.tenMinutes,
        now: _at(11 * 60),
      );
      final ten = range.buckets.first;
      expect(ten.start, _t0);
      expect(ten.provenance, HistoryProvenance.sessionRollup);
      final cpu = ten.values[AlertMetric.cpuBusy]!;
      expect((cpu.min, cpu.max, cpu.count), (0, 90, 10));
      expect(cpu.mean, closeTo(45, 1e-4));
      // The eleventh minute is still filling and has opened nothing yet.
      expect(range.buckets, hasLength(1));
    });

    test('servers keep their own buckets, and a reading from before the '
        'held minute is dropped', () async {
      history
        ..observe(_web, _cpu(10), _at(60))
        ..observe(_db, _cpu(90), _at(60))
        ..observe(_web, _cpu(99), _at(0));

      final web = await history.read(_web, HistoryTier.minute, now: _at(90));
      expect(web.buckets.single.values[AlertMetric.cpuBusy]!.max, 10);
      final db = await history.read(_db, HistoryTier.minute, now: _at(90));
      expect(db.buckets.single.values[AlertMetric.cpuBusy]!.max, 90);
    });

    test('a bucket older than the tier\'s span is left out', () async {
      history
        ..observe(_web, _cpu(10), _at(0))
        ..observe(_web, _cpu(20), _at(60));
      await history.flush();

      final range = await history.read(
        _web,
        HistoryTier.minute,
        now: _at(
          0,
        ).add(HistoryTier.minute.span).add(const Duration(seconds: 30)),
      );
      expect([for (final b in range.buckets) b.start], [_at(60)]);
    });

    test('gaps are recorded and read back in order', () async {
      history
        ..gap(_web, _at(120), _at(300), GapCause.disconnected)
        ..gap(_web, _at(0), _at(60), GapCause.background);

      final range = await history.read(_web, HistoryTier.minute, now: _at(400));
      expect(
        [for (final g in range.gaps) (g.from, g.until, g.cause)],
        [
          (_at(0), _at(60), GapCause.background),
          (_at(120), _at(300), GapCause.disconnected),
        ],
      );
    });
  });

  group('files', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('klab-history-');
    });

    tearDown(() => support.delete(recursive: true));

    Future<HistoryStore> open(Set<String> fleet) => HistoryStore.open(
      support,
      access: SupportDirectoryAccess.exclusive,
      fleet: fleet,
      purge: CachePurge.removedServers,
    );

    test('rings keep their buckets and gaps across a restart, in files of '
        'a fixed size', () async {
      final first = await open({_web});
      first
        ..observe(_web, _cpu(10), _at(0))
        ..observe(_web, _disk(81, 7), _at(5))
        ..observe(_web, _cpu(20), _at(60))
        ..gap(_web, _at(70), _at(90), GapCause.readingLost);
      await first.flush();

      final ring = File(
        '${support.path}/history/$_web/${HistoryTier.minute.name}.ring',
      );
      final size = await ring.length();

      final reopened = await open({_web});
      final range = await reopened.read(
        _web,
        HistoryTier.minute,
        now: _at(120),
      );
      expect([for (final b in range.buckets) b.start], [_at(0), _at(60)]);
      expect(range.buckets.first.values[AlertMetric.cpuBusy]!.mean, 10);
      // Every metric has its place in a slot, the last one included.
      expect(range.buckets.first.values[AlertMetric.diskUsed]!.max, 81);
      expect(range.buckets.first.values[AlertMetric.diskInodes]!.max, 7);
      expect(range.gaps.single.cause, GapCause.readingLost);

      reopened.observe(_web, _cpu(30), _at(120));
      await reopened.flush();
      expect(await ring.length(), size);
    });

    test('a server leaving the fleet loses its rings, at once or at the '
        'next open', () async {
      final store = await open({_web, _db});
      store
        ..observe(_web, _cpu(10), _at(0))
        ..observe(_db, _cpu(10), _at(0));
      await store.flush();
      final webDir = Directory('${support.path}/history/$_web');
      final dbDir = Directory('${support.path}/history/$_db');
      expect(await webDir.exists(), isTrue);

      await store.forget({_web});
      expect(await webDir.exists(), isFalse);

      await open({});
      expect(await dbDir.exists(), isFalse);
    });

    test('without exclusive access nothing touches disk', () async {
      final store = await HistoryStore.open(
        support,
        access: SupportDirectoryAccess.unguarded,
        fleet: {_web},
        purge: CachePurge.removedServers,
      );
      store
        ..observe(_web, _cpu(10), _at(0))
        ..observe(_web, _cpu(20), _at(60));
      await store.flush();

      expect(await Directory('${support.path}/history').exists(), isFalse);
      final range = await store.read(_web, HistoryTier.minute, now: _at(90));
      expect(range.buckets, hasLength(2));
    });
  });
}
