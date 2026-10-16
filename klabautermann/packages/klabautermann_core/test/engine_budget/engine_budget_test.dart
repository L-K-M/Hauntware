// The engine budget harness end to end (spike S5 part 1), briefly and at
// short cadences so it cannot rot: every replayed host is probed and
// sampled across the isolate hop, the follow delivers what it parsed,
// and the report holds each figure. It checks no budget; the figures of
// a one-second run on a shared machine mean nothing.
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/src/replay/fixture_replay.dart';
import 'package:klabautermann_core/src/replay/host_fixtures.dart';
import 'package:test/test.dart';

import '../../tool/src/engine_budget.dart';

void main() {
  test('a short run replays every host and the follow across the isolate '
      'hop and reports each figure', () async {
    final fixtures = findHostFixtures()!;
    final platforms = loadHostFixtures(fixtures).length;
    final json = await runEngineBudget(
      const BudgetPlan(
        name: 'smoke',
        hosts: 10,
        overviewEvery: Duration(milliseconds: 200),
        openHosts: 2,
        coreEvery: Duration(milliseconds: 100),
        logLinesPerSecond: 1000,
        warmup: Duration(milliseconds: 300),
        measure: Duration(milliseconds: 700),
      ),
      fixturesRoot: fixtures,
    );

    // Plain JSON throughout.
    expect(jsonDecode(jsonEncode(json)), json);
    final plan = json['plan']! as Map<String, Object?>;
    expect((plan['hosts']! as List).toSet(), hasLength(platforms));

    // A SamplingState and a HostProfileChanged per host, then samples and
    // log batches, crossed the isolate hop.
    final ui = json['ui']! as Map<String, Object?>;
    expect(ui['samples']! as int, greaterThan(10 * 2));
    expect(ui['messages']! as int, greaterThan(20 + (ui['samples']! as int)));
    expect(ui['serversProfiled'], 10);
    expect(ui['samplesByServer']! as Map, hasLength(10));
    // The replayed counters advance, so the pipeline derives rates.
    expect(ui['samplesWithCpu']! as int, greaterThan(0));
    expect(ui['samplesWithDiskRates']! as int, greaterThan(0));

    final ticks = json['ticks']! as Map<String, Object?>;
    expect(ticks['count']! as int, greaterThan(0));
    // Every host's first read falls in the 300 ms warm-up, which the
    // window leaves out.
    expect(
      ((ticks['count']! as int) * (ticks['eventsPerTick']! as num)).round(),
      lessThan(ui['samples']! as int),
    );
    expect(
      (ticks['replyBytes']! as Map).keys,
      unorderedEquals(['overview', 'core']),
    );
    for (final key in ['engineMs', 'frameMs', 'pipelineMs', 'sendMs']) {
      expect((ticks[key]! as Map).keys, ['p50', 'p99', 'max', 'mean']);
    }

    final log = json['log']! as Map<String, Object?>;
    expect(log['malformed'], 0);
    expect(log['linesFed']! as int, greaterThan(0));
    // At most 20 batches in any second (03 §10.1).
    expect(
      log['batches']! as int,
      lessThanOrEqualTo(
        kMaxLogBatchesPerSecond * (json['windowSeconds']! as num).ceil(),
      ),
    );
    // Every line the follow parsed reached the UI, was counted dropped or
    // was still waiting for its batch.
    expect(
      (ui['logRecords']! as int) +
          (ui['logDropped']! as int) +
          (log['pendingAtEnd']! as int),
      log['runLinesParsed'],
    );
    expect(log['runLinesParsed']! as int, greaterThan(500));

    final process = json['process']! as Map<String, Object?>;
    final rss = process['rssBytes']! as Map<String, Object?>;
    expect(rss['series'], hasLength(greaterThanOrEqualTo(2)));
    expect(rss['max'], isPositive);
    expect(process['replayReplyBytes'], isPositive);
    expect(
      (json['engine']! as Map<String, Object?>)['busyMsPerSecond']! as num,
      greaterThan(0),
    );
  });

  group('parseBudgetArgs', () {
    test('reads each option and --heap', () {
      final parsed = parseBudgetArgs([
        '--scenario',
        'phone',
        '--heap',
        '--out',
        'run.json',
      ]);
      expect(parsed.options, {'scenario': 'phone', 'out': 'run.json'});
      expect(parsed.heap, HeapReadings.afterFullCollection);
      expect(parseBudgetArgs(const []).heap, HeapReadings.off);
    });

    test('refuses an option where a value belongs', () {
      expect(
        () => parseBudgetArgs(['--out', '--heap']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '--out needs a value, not --heap',
          ),
        ),
      );
    });

    test('refuses an unknown option and a missing value', () {
      for (final args in [
        ['--rate', '5'],
        ['phone'],
        ['--seconds'],
      ]) {
        expect(
          () => parseBudgetArgs(args),
          throwsFormatException,
          reason: '$args',
        );
      }
    });
  });

  test('every journal fixture row parses', () {
    final rows = loadJournalRows(findHostFixtures()!);
    final follow = FollowReplay(streamId: 's', maxPending: 100)
      ..add(utf8.encode('${rows.join('\n')}\n'));
    expect(follow.malformed, 0);
    expect(follow.linesParsed, rows.length);
  });

  test('replays the platform fixtures, not the container or runner-VM '
      'captures', () {
    final root = findHostFixtures()!;
    final dirs = Directory(root).listSync().whereType<Directory>().toList();
    for (final (mark, script) in [
      ('-docker-', 'capture.sh'),
      ('-runner-', 'runner_vm.sh'),
    ]) {
      expect(
        dirs.where((dir) => dir.path.contains(mark)),
        isNotEmpty,
        reason: '$script commits them',
      );
    }
    expect(
      [for (final fixture in loadHostFixtures(root)) fixture.platform],
      allOf(
        isNotEmpty,
        everyElement(
          allOf(isNot(contains('-docker-')), isNot(contains('-runner-'))),
        ),
      ),
    );
  });
}
