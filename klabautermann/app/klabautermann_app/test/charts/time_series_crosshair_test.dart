import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/charts/time_series_crosshair.dart';

import '../support/charts.dart';

final _start = DateTime.utc(2026, 10, 14, 12);
DateTime _at(int second) => _start.add(Duration(seconds: second));
int _micros(int second) => _at(second).microsecondsSinceEpoch;
const _second = Duration.microsecondsPerSecond;

/// Samples every 10 s from 0 to 50 s with lane 1 unknown at 20 s, a
/// disconnected gap from 50 s to 90 s, samples at 90 s and 100 s, and an
/// open gap in the background since 100 s.
TimeSeriesRing _ring() {
  final ring = TimeSeriesRing(capacity: 20, lanes: 2);
  addTearDown(ring.dispose);
  for (var second = 0; second <= 50; second += 10) {
    ring.add(_at(second), [second.toDouble(), second == 20 ? null : 1.0]);
  }
  ring.openGap(_at(50), ChartGapReason.disconnected);
  ring.add(_at(90), [90, 2]);
  ring.add(_at(100), [100, 3]);
  ring.openGap(_at(100), ChartGapReason.background);
  return ring;
}

/// The hit at [second] in a window of 0 to 120 s.
TimeSeriesHit? _hit(TimeSeriesRing ring, num second, {int reach = 0}) =>
    timeSeriesHitAt(
      ring,
      ring.gaps,
      at: _micros(0) + (second * _second).round(),
      from: _micros(0),
      to: _micros(120),
      gapReach: reach,
    );

/// 03 §10.7's crosshair: what a pointer or a key lands on, and the words
/// its readout shows, as pure functions.
void main() {
  setUpAll(loadChartDateFormats);

  group('hit testing', () {
    test('snaps to the nearest sample time', () {
      final ring = _ring();
      expect(_hit(ring, 12), TimeSeriesSampleHit(1, _micros(10)));
      expect(_hit(ring, 16), TimeSeriesSampleHit(2, _micros(20)));
      // Exactly between two samples, the earlier one.
      expect(_hit(ring, 15), TimeSeriesSampleHit(1, _micros(10)));
      expect(_hit(ring, 0), TimeSeriesSampleHit(0, _micros(0)));
    });

    test('inside a gap names the gap at the pointed time', () {
      final ring = _ring();
      final hit = _hit(ring, 70);
      expect(hit, isA<TimeSeriesGapHit>());
      hit as TimeSeriesGapHit;
      expect(hit.gap.reason, ChartGapReason.disconnected);
      expect(hit.at, _micros(70));
      // The open gap reaches the window's right edge.
      final open = _hit(ring, 120)! as TimeSeriesGapHit;
      expect(open.gap.reason, ChartGapReason.background);
      expect(open.at, _micros(120));
    });

    test("a gap's closing sample is a sample, not the gap", () {
      expect(_hit(_ring(), 90), TimeSeriesSampleHit(6, _micros(90)));
      expect(_hit(_ring(), 50), TimeSeriesSampleHit(5, _micros(50)));
    });

    test('reaches a narrow gap within its widened band', () {
      final ring = TimeSeriesRing(capacity: 10, lanes: 1);
      addTearDown(ring.dispose);
      ring.add(_at(10), [1]);
      ring.openGap(_at(30), ChartGapReason.readingFailed);
      ring.add(_at(31), [1]);
      ring.add(_at(60), [1]);

      // Two seconds off the gap's middle, outside its one-second span.
      final near = _hit(ring, 32.5, reach: 3 * _second);
      expect(near, isA<TimeSeriesGapHit>());
      // Outside the gap's own span the rule takes its middle.
      expect(near!.at, _micros(30) + _second ~/ 2);
      expect(_hit(ring, 32.5), TimeSeriesSampleHit(1, _micros(31)));
    });

    test('clamps to the window and finds nothing in an empty one', () {
      final ring = _ring();
      expect(
        timeSeriesHitAt(
          ring,
          ring.gaps,
          at: _micros(-50),
          from: _micros(0),
          to: _micros(120),
        ),
        TimeSeriesSampleHit(0, _micros(0)),
      );
      final empty = TimeSeriesRing(capacity: 2, lanes: 1);
      addTearDown(empty.dispose);
      expect(_hit(empty, 30), isNull);
    });

    test('a window of one sample always hits it', () {
      final ring = TimeSeriesRing(capacity: 2, lanes: 1);
      addTearDown(ring.dispose);
      ring.add(_at(40), [double.nan]);
      expect(_hit(ring, 0), TimeSeriesSampleHit(0, _micros(40)));
      expect(_hit(ring, 120), TimeSeriesSampleHit(0, _micros(40)));
    });
  });

  group('stepping', () {
    int? step(TimeSeriesRing ring, int? second, TimeSeriesStep step) =>
        timeSeriesStepFrom(
          ring,
          ring.gaps,
          at: second == null ? null : _micros(second),
          step: step,
          from: _micros(0),
          to: _micros(120),
          stride: _second,
        );

    test('starts at the newest stop', () {
      final ring = _ring();
      // The open gap's middle, from 100 s to the edge, is newer than 100 s.
      expect(step(ring, null, TimeSeriesStep.earlier), _micros(110));
      expect(step(ring, null, TimeSeriesStep.later), _micros(110));
      expect(step(ring, 10, TimeSeriesStep.newest), _micros(110));
      expect(step(ring, 70, TimeSeriesStep.oldest), _micros(0));
    });

    test('walks samples and stops once inside each gap', () {
      final ring = _ring();
      final visited = <int>[];
      int? at = _micros(0);
      while (true) {
        visited.add((at! - _micros(0)) ~/ _second);
        final next = timeSeriesStepFrom(
          ring,
          ring.gaps,
          at: at,
          step: TimeSeriesStep.later,
          from: _micros(0),
          to: _micros(120),
          stride: _second,
        );
        if (next == at) break;
        at = next;
      }
      expect(visited, [0, 10, 20, 30, 40, 50, 70, 90, 100, 110]);
      expect(step(ring, 90, TimeSeriesStep.earlier), _micros(70));
      expect(step(ring, 70, TimeSeriesStep.earlier), _micros(50));
      expect(step(ring, 0, TimeSeriesStep.earlier), _micros(0));
    });

    test('skips samples closer than the stride, a pixel apart', () {
      final ring = TimeSeriesRing(capacity: 100, lanes: 1);
      addTearDown(ring.dispose);
      for (var second = 0; second < 100; second++) {
        ring.add(_at(second), [1]);
      }
      int? stride(int at, TimeSeriesStep direction) => timeSeriesStepFrom(
        ring,
        ring.gaps,
        at: _micros(at),
        step: direction,
        from: _micros(0),
        to: _micros(120),
        stride: 10 * _second,
      );
      expect(stride(20, TimeSeriesStep.later), _micros(30));
      expect(stride(20, TimeSeriesStep.earlier), _micros(10));
      // Short of a stride from either end, to the end.
      expect(stride(95, TimeSeriesStep.later), _micros(99));
      expect(stride(4, TimeSeriesStep.earlier), _micros(0));
      expect(stride(99, TimeSeriesStep.later), _micros(99));
    });

    test('has nowhere to go in an empty window', () {
      final empty = TimeSeriesRing(capacity: 2, lanes: 1);
      addTearDown(empty.dispose);
      expect(step(empty, null, TimeSeriesStep.later), isNull);
    });
  });

  group('the readout', () {
    TimeSeriesReadout readout(
      TimeSeriesRing ring,
      TimeSeriesHit hit, {
      Duration span = const Duration(minutes: 10),
      Duration zone = Duration.zero,
    }) => timeSeriesReadout(
      hit,
      ring,
      labels: const ['User', 'System'],
      unit: ChartUnit.percent,
      strings: testChartStrings,
      span: span,
      zoneOffsetOf: (_) => zone,
    );

    test("names each series' value and the time to the second", () {
      final ring = _ring();
      final values = readout(ring, _hit(ring, 10)!);
      expect(values.time, '12:00:10\u202fPM');
      expect(values.values, ['User 10%', 'System 1%']);
      expect(values.gap, isNull);
    });

    test('says no reading for an unknown value', () {
      final ring = _ring();
      expect(readout(ring, _hit(ring, 20)!).values, [
        'User 20%',
        'System no reading',
      ]);
    });

    test('says no reading and why inside a gap', () {
      final ring = _ring();
      final values = readout(ring, _hit(ring, 70)!);
      expect(values.time, '12:01:10\u202fPM');
      expect(values.values, isEmpty);
      expect(values.gap, 'No reading: disconnected');
      expect(
        timeSeriesReadoutText(values, testChartStrings),
        '12:01:10\u202fPM, No reading: disconnected',
      );
    });

    test("reads the time in the chart's zone, with a date past a day", () {
      final ring = _ring();
      final hit = _hit(ring, 10)!;
      expect(
        readout(ring, hit, zone: const Duration(hours: 5, minutes: 45)).time,
        '5:45:10\u202fPM',
      );
      expect(
        readout(ring, hit, span: const Duration(hours: 6)).time,
        '12:00\u202fPM',
      );
      expect(
        readout(ring, hit, span: const Duration(hours: 48)).time,
        'Oct 14 12:00\u202fPM',
      );
      expect(
        timeSeriesReadoutText(readout(ring, hit), testChartStrings),
        '12:00:10\u202fPM, User 10%, System 1%',
      );
    });
  });
}
