import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/charts/time_series.dart'
    show timeSeriesRuns;

final _start = DateTime(2026, 10, 14, 12);
DateTime _at(int second) => _start.add(Duration(seconds: second));
int _micros(int second) => _at(second).microsecondsSinceEpoch;

TimeSeriesRing _ring({int capacity = 20, int lanes = 1}) {
  final ring = TimeSeriesRing(capacity: capacity, lanes: lanes);
  addTearDown(ring.dispose);
  return ring;
}

/// The runs of lane 0 over the whole ring, one-second columns.
List<List<int>> _runs(TimeSeriesRing ring, {int from = 0, int to = 1000}) =>
    timeSeriesRuns(
      ring,
      0,
      from: _micros(from),
      to: _micros(to),
      bucket: Duration.microsecondsPerSecond,
    );

/// 03 §10.7 and §9.5 item 5: the ring behind the time-series chart and the
/// runs it draws, which never interpolate across a gap or an unknown sample.
void main() {
  group('the ring', () {
    test('keeps the newest ticks with their times and unknown values', () {
      final ring = _ring(capacity: 3, lanes: 2);
      ring.add(_at(0), [1, 2]);
      ring.add(_at(1), [null, double.nan]);
      ring.add(_at(2), [double.infinity, 5]);
      ring.add(_at(3), [7, 8]);

      expect(ring.length, 3);
      expect(
        [for (var i = 0; i < 3; i++) ring.microsAt(i)],
        [_micros(1), _micros(2), _micros(3)],
      );
      expect([for (var i = 0; i < 3; i++) ring.valueAt(0, i)], [null, null, 7]);
      expect([for (var i = 0; i < 3; i++) ring.valueAt(1, i)], [null, 5, 8]);
    });

    test('closes an open gap with the next sample, which does not join', () {
      final ring = _ring();
      ring.add(_at(0), [1]);
      ring.add(_at(1), [2]);
      ring.openGap(_at(1), ChartGapReason.disconnected);
      expect(ring.gaps.single.end, isNull);

      ring.add(_at(9), [3]);
      expect(ring.gaps.single, (
        start: _at(1),
        end: _at(9),
        reason: ChartGapReason.disconnected,
      ));
      expect(
        [for (var i = 0; i < 3; i++) ring.joinsPrevious(i)],
        [false, true, false],
      );
    });

    test('continues a gap with the same reason and ends it on another', () {
      final ring = _ring();
      ring.add(_at(0), [1]);
      ring.openGap(_at(1), ChartGapReason.disconnected);
      ring.openGap(_at(2), ChartGapReason.disconnected);
      ring.openGap(_at(4), ChartGapReason.background);

      expect(ring.gaps, [
        (start: _at(1), end: _at(4), reason: ChartGapReason.disconnected),
        (start: _at(4), end: null, reason: ChartGapReason.background),
      ]);
    });

    test('raises a time that goes backwards to the newest one', () {
      final ring = _ring();
      ring.add(_at(5), [1]);
      ring.openGap(_at(3), ChartGapReason.disconnected);
      expect(ring.gaps.single.start, _at(5));

      ring.add(_at(4), [2]);
      expect(ring.microsAt(1), _micros(5));
      expect(ring.joinsPrevious(1), isFalse);
      expect(ring.indexAtOrAfter(_micros(5)), 0);
    });

    test('drops gaps that ended before the oldest sample', () {
      final ring = _ring(capacity: 2);
      ring.add(_at(0), [1]);
      ring.openGap(_at(1), ChartGapReason.disconnected);
      ring.add(_at(2), [2]);
      // The sample before the gap leaves, but the gap still ends at the
      // oldest sample.
      ring.add(_at(3), [3]);
      expect(ring.gaps, hasLength(1));

      ring.add(_at(4), [4]);
      expect(ring.gaps, isEmpty);
    });

    test('keeps a gap that the first sample closes', () {
      final ring = _ring();
      ring.openGap(_at(0), ChartGapReason.disconnected);
      ring.add(_at(180), [1]);

      expect(ring.gaps.single, (
        start: _at(0),
        end: _at(180),
        reason: ChartGapReason.disconnected,
      ));
    });

    test('keeps at most capacity gaps while no sample arrives', () {
      final ring = _ring(capacity: 2);
      for (var second = 0; second < 6; second++) {
        ring.openGap(
          _at(second),
          ChartGapReason.values[second % ChartGapReason.values.length],
        );
      }

      expect(ring.gaps, hasLength(2));
      expect(ring.gaps.last.end, isNull);
    });

    test('bumps its version and notifies on every change', () {
      final ring = _ring();
      var notified = 0;
      ring.addListener(() => notified++);
      ring.add(_at(0), [1]);
      ring.openGap(_at(1), ChartGapReason.background);
      // The same reason changes nothing.
      ring.openGap(_at(2), ChartGapReason.background);

      expect(ring.version, 2);
      expect(notified, 2);
    });
  });

  group('the runs', () {
    test('never span a gap or an unknown sample', () {
      final ring = _ring();
      for (var second = 0; second < 10; second++) {
        if (second == 7) ring.openGap(_at(6), ChartGapReason.background);
        ring.add(_at(second), [second == 3 ? null : 10.0 + second]);
      }

      expect(_runs(ring), [
        [0, 1, 2],
        [4, 5, 6],
        [7, 8, 9],
      ]);
    });

    test('keep a known sample between unknown ones as its own run', () {
      final ring = _ring();
      for (final value in [null, 4.0, null, 5.0, 6.0]) {
        ring.add(_at(ring.length), [value]);
      }

      expect(_runs(ring), [
        [1],
        [3, 4],
      ]);
    });

    test("keep each column's extremes in arrival order", () {
      final ring = _ring();
      const values = <double>[5, 9, 1, 4, 6, 3, 3, 8, 2, 7];
      for (final (second, value) in values.indexed) {
        ring.add(_at(second), [value]);
      }

      // Five-second columns aligned to the epoch: 12:00:00 to 12:00:04
      // keeps 9 then 1, and 12:00:05 to 12:00:09 keeps 8 then 2.
      final runs = timeSeriesRuns(
        ring,
        0,
        from: _micros(0),
        to: _micros(9),
        bucket: 5 * Duration.microsecondsPerSecond,
      );
      expect(runs, [
        [1, 2, 7, 8],
      ]);
    });

    test('reach one sample past each end of the window', () {
      final ring = _ring();
      for (var second = 0; second < 10; second++) {
        ring.add(_at(second), [1]);
      }

      final runs = timeSeriesRuns(
        ring,
        0,
        from: _micros(4) - 1,
        to: _micros(6) + 1,
        bucket: Duration.microsecondsPerSecond,
      );
      expect(runs, [
        [3, 4, 5, 6, 7],
      ]);
    });
  });
}
