import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';

SeriesRing _ring(int capacity, List<double?> samples) {
  final ring = SeriesRing(capacity);
  addTearDown(ring.dispose);
  samples.forEach(ring.add);
  return ring;
}

/// 03 §10.7: the fixed-capacity ring behind a series, its version counter,
/// and min-max downsampling to the pixel width.
void main() {
  test('a ring keeps its newest samples, with unknown ones as null', () {
    final ring = _ring(4, [1, double.nan, double.infinity, 4, null]);

    expect(ring.samples, [null, null, 4, null]);
    expect((ring.length, ring.added, ring.firstIndex), (4, 5, 1));
    expect(() => ring.samples[0] = 2, throwsUnsupportedError);
    expect(() => ring.samples[4], throwsRangeError);
  });

  test('every sample bumps the version and notifies', () {
    final ring = _ring(2, [1]);
    var notified = 0;
    ring.addListener(() => notified++);

    ring
      ..add(2)
      ..add(3);

    expect((ring.version, notified), (3, 2));
  });

  group('downsampleMinMax', () {
    test('one sample per column is the series itself', () {
      expect(downsampleMinMax([1, null, 3], bucketSize: 1), [
        (start: 0, first: 1, second: 1),
        null,
        (start: 2, first: 3, second: 3),
      ]);
    });

    test('a column keeps its extremes in arrival order', () {
      expect(downsampleMinMax([5, 9, 1, 4, 2, 8, 6, 7], bucketSize: 4), [
        (start: 0, first: 9, second: 1),
        (start: 4, first: 2, second: 8),
      ]);
    });

    test('a spike narrower than a column still shows', () {
      final samples = List<double?>.filled(100, 10)..[37] = 95;

      final columns = downsampleMinMax(samples, bucketSize: 10);

      expect(columns, hasLength(10));
      expect(columns[3], (start: 30, first: 10, second: 95));
    });

    test('only a column with no known sample is a gap', () {
      expect(downsampleMinMax([null, null, null, 4, null], bucketSize: 3), [
        null,
        (start: 3, first: 4, second: 4),
      ]);
      expect(downsampleMinMax(const [], bucketSize: 4), isEmpty);
    });

    test('columns align to running indices, so they keep their samples', () {
      final ring = _ring(6, [1, 2, 3, 4, 5, 6]);
      List<MinMaxColumn?> columns() => downsampleMinMax(
        ring.samples,
        bucketSize: 3,
        firstIndex: ring.firstIndex,
      );
      expect(columns(), [
        (start: 0, first: 1, second: 3),
        (start: 3, first: 4, second: 6),
      ]);

      ring.add(7);

      // The full column [3, 6) is unchanged; the oldest is now partial and
      // the newest has begun.
      expect(columns(), [
        (start: 0, first: 2, second: 3),
        (start: 3, first: 4, second: 6),
        (start: 6, first: 7, second: 7),
      ]);
    });
  });
}
