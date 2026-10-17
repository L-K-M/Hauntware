// The engine budget harness's replay rules (spike S5 part 1, 03 §11.4):
// fixture counters advancing with time, HWS/1 framing, the staggered
// schedule and the follow's batches.
import 'dart:convert';
import 'dart:math' as math;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/replay/fixture_replay.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _core = '''
== stat ==
cpu  4705 356 1831 74933 1020 0 45 0 0 0
cpu0 1733 18988
btime 1700000000
== meminfo ==
MemTotal: 16384000
== netdev ==
eth0 987654321 123456789
== diskstats ==
sda 1234567 98765432 2345678 123456780
== pressure_io ==
some avg10=0.05 avg60=0.02 avg300=0.01
== uptime ==
458100.73 1832400.50''';

void main() {
  group('advanceCounters', () {
    test('advances each counter by its rate times the seconds', () {
      expect(advanceCounters(_core, 3), '''
== stat ==
cpu  4795 356 1861 75083 1050 0 45 0 0 0
cpu0 1808 19213
btime 1700000000
== meminfo ==
MemTotal: 16384000
== netdev ==
eth0 987660321 123459789
== diskstats ==
sda 1234570 98765456 2345681 123456828
== pressure_io ==
some avg10=0.05 avg60=0.02 avg300=0.01
== uptime ==
458103.73 1832403.50''');
    });

    test('advances the eight raw counters of a 32-bit shell', () {
      expect(
        advanceCounters('== stat ==\ncpu1 1 2 3 4 5 6 7 8', 2),
        '== stat ==\ncpu1 21 2 13 124 35 16 13 12',
      );
    });

    test('leaves the payload as it is at zero seconds', () {
      expect(advanceCounters(_core, 0), _core);
    });

    test('reads the uptime block, or none', () {
      expect(fixtureUptime(_core), 458100.73);
      expect(fixtureUptime('== stat ==\ncpu  1 2 3 4'), isNull);
    });
  });

  test('a framed reply assembles into the tick it describes', () {
    final assembler = HwsTickAssembler(nonce: replayNonce);
    expect(assembler.push(readyFrame()).single, isA<HwsSessionReady>());

    final tick =
        assembler
                .push(
                  replyFrame(7, 12.5, [
                    (name: 'core', status: SectionStatus.ok, payload: 'ä\nb'),
                    (
                      name: 'probe_os',
                      status: SectionStatus.missing,
                      payload: '',
                    ),
                  ]),
                )
                .single
            as HwsTick;
    expect(tick.seq, 7);
    expect(tick.uptimeSeconds, 12.5);
    expect(
      [
        for (final s in tick.sections)
          (s.collector, s.status, utf8.decode(s.payload)),
      ],
      [
        ('core', SectionStatus.ok, 'ä\nb'),
        ('probe_os', SectionStatus.missing, ''),
      ],
    );
  });

  test('parseProbeSections reads the fixture format', () {
    expect(
      parseProbeSections('### os ok\nID=debian\nX=1\n### shell missing\n\n'),
      [
        (name: 'probe_os', status: SectionStatus.ok, payload: 'ID=debian\nX=1'),
        (name: 'probe_shell', status: SectionStatus.missing, payload: ''),
      ],
    );
  });

  group('ReplaySchedule', () {
    test('open hosts read core, which serves overview; the others read '
        'overview, staggered across the interval', () {
      final schedule = ReplaySchedule(
        hosts: 4,
        overviewEvery: const Duration(seconds: 8),
        openHosts: 1,
        coreEvery: const Duration(seconds: 3),
      );
      expect(schedule.collectorOf(0), Collector.core);
      expect(schedule.streamsOf(0), {SampleStream.overview, SampleStream.core});
      expect(schedule.collectorOf(1), Collector.overview);
      expect(schedule.streamsOf(1), {SampleStream.overview});
      // Three overview hosts share 8 s: offsets 0, 8/3 and 16/3 s.
      expect(schedule.slotTime(1, 0), Duration.zero);
      expect(schedule.slotTime(2, 0), const Duration(microseconds: 2666666));
      expect(schedule.slotTime(3, 2), const Duration(microseconds: 21333333));
      expect(schedule.slotTime(0, 4), const Duration(seconds: 12));

      List<(int, int)> due(int ms) => [
        for (final d in schedule.due(Duration(milliseconds: ms)))
          (d.host, d.slot),
      ];
      expect(due(0), [(0, 0), (1, 0)]);
      expect(due(10), isEmpty);
      expect(due(2700), [(2, 0)]);
      expect(due(3000), [(0, 1)]);
      expect(due(5400), [(3, 0)]);
      expect(due(6000), [(0, 2)]);
      expect(due(8000), [(1, 1)]);
      expect(schedule.skipped, 0);
    });

    test('a late step runs a read once and counts the slots it missed', () {
      final schedule = ReplaySchedule(
        hosts: 1,
        overviewEvery: const Duration(seconds: 10),
        openHosts: 1,
        coreEvery: const Duration(seconds: 2),
      );
      expect(schedule.due(Duration.zero).single.slot, 0);
      expect(schedule.due(const Duration(milliseconds: 6500)).single.slot, 3);
      expect(schedule.skipped, 2);
      expect(schedule.due(const Duration(milliseconds: 7999)), isEmpty);
      expect(schedule.due(const Duration(seconds: 8)).single.slot, 4);
    });

    test('slotsWithin counts the slots that start before the end', () {
      final schedule = ReplaySchedule(
        hosts: 2,
        overviewEvery: const Duration(seconds: 10),
        openHosts: 0,
        coreEvery: const Duration(seconds: 2),
      );
      // Host 0 at 0, 10, 20 s; host 1 at 5, 15, 25 s.
      expect(schedule.slotsWithin(0, const Duration(seconds: 25)), 3);
      expect(schedule.slotsWithin(1, const Duration(seconds: 25)), 2);
      expect(schedule.slotsWithin(1, const Duration(milliseconds: 25001)), 3);
    });
  });

  group('FollowReplay', () {
    String row(int i) =>
        '{"__CURSOR":"s=a;i=$i","PRIORITY":"6","MESSAGE":"m$i"}';
    List<int> rows(Iterable<int> ids) =>
        utf8.encode([for (final i in ids) '${row(i)}\n'].join());

    test('sends batches on a 50 ms beat, holding the records parsed since '
        'the last', () {
      final follow = FollowReplay(streamId: 's', maxPending: 100);
      expect(follow.flush(Duration.zero), isNull, reason: 'nothing pending');

      final bytes = rows([1, 2, 3]);
      // A line cut across two chunks is joined.
      follow
        ..add(bytes.sublist(0, 10))
        ..add(bytes.sublist(10));
      expect(follow.linesParsed, 3);
      final first = follow.flush(const Duration(milliseconds: 5))!;
      expect(first.streamId, 's');
      expect(
        [for (final r in first.records) (r as JournalRecord).cursor],
        ['s=a;i=1', 's=a;i=2', 's=a;i=3'],
      );
      expect(first.dropped, 0);

      follow.add(rows([4]));
      expect(follow.flush(const Duration(milliseconds: 54)), isNull);
      final second = follow.flush(const Duration(milliseconds: 57))!;
      expect(second.records, hasLength(1));
      expect(follow.pending, 0);

      // The batches keep a 50 ms beat whatever the caller's step: the
      // second was due at 55 ms, so the third is due at 105 ms.
      follow.add(rows([5]));
      expect(follow.flush(const Duration(milliseconds: 104)), isNull);
      expect(follow.flush(const Duration(milliseconds: 105)), isNotNull);

      // After a longer pause the beat starts again from the late batch.
      follow.add(rows([6]));
      expect(follow.flush(const Duration(milliseconds: 300)), isNotNull);
      follow.add(rows([7]));
      expect(follow.flush(const Duration(milliseconds: 349)), isNull);
      expect(follow.flush(const Duration(milliseconds: 350)), isNotNull);
    });

    test('sends at most 20 batches in any second and about 20 a second '
        'whatever the steps', () {
      // 10 ms steps with up to 2 ms of jitter, as the harness's periodic
      // timer fires, and the one due at 50 ms running 45 ms late, as on a
      // loaded machine. The VM runs a late periodic timer once and drops
      // the ticks that came due meanwhile (`Timer.tick`), so the steps at
      // 60 to 90 ms never run and the grid holds from 100 ms.
      final random = math.Random(1);
      final steps = [
        for (var ms = 0; ms < 10000; ms += 10)
          if (ms == 50)
            const Duration(milliseconds: 95)
          else if (ms < 50 || ms > 90)
            Duration(microseconds: ms * 1000 + random.nextInt(2000)),
      ];
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], greaterThan(steps[i - 1]), reason: 'step $i');
      }
      final follow = FollowReplay(streamId: 's', maxPending: 100);
      final sent = <Duration>[];
      for (final (i, now) in steps.indexed) {
        follow.add(rows([i]));
        if (follow.flush(now) != null) sent.add(now);
      }

      for (var i = kMaxLogBatchesPerSecond; i < sent.length; i++) {
        expect(
          sent[i] - sent[i - kMaxLogBatchesPerSecond],
          greaterThanOrEqualTo(const Duration(seconds: 1)),
          reason: 'batch $i at ${sent[i]}',
        );
      }
      // The beat holds rather than drifting by the steps' jitter.
      expect(sent.length, greaterThan(190));
    });

    test('drops the oldest records beyond maxPending and counts them in '
        'the next batch', () {
      final follow = FollowReplay(streamId: 's', maxPending: 2)
        ..add(rows([1, 2, 3, 4, 5]));
      expect(follow.pending, 2);
      expect(follow.maxPendingSeen, 2);

      final batch = follow.flush(Duration.zero)!;
      expect(batch.dropped, 3);
      expect(
        [for (final r in batch.records) (r as JournalRecord).message],
        ['m4', 'm5'],
      );
      expect(follow.dropped, 3);

      follow.add(rows([6]));
      expect(follow.flush(const Duration(milliseconds: 50))!.dropped, 0);
    });

    test('counts lines that are not JSON objects and sends no record for '
        'them', () {
      final follow = FollowReplay(streamId: 's', maxPending: 10)
        ..add(utf8.encode('not json\n[1]\n${row(1)}\n'));
      expect(follow.malformed, 2);
      expect(follow.flush(Duration.zero)!.records, hasLength(1));
    });
  });
}
