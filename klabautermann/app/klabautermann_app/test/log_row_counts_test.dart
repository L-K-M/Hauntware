import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/logs/log_row_counts.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

List<String> _lines(int from, int count) => [
  for (var i = from; i < from + count; i++) 'line $i',
];

void main() {
  group('RowCounts', () {
    test('appends estimates and sums the rows before an entry', () {
      final logs = LogViewController(buffer: LogBuffer(maxLines: 100));
      logs.add(_lines(0, 3));
      final counts = RowCounts(
        (index, _) => index + 1,
        (index, _) => index + 1,
      );

      expect(counts.sync(logs), (entries: 0, rows: 0));
      expect(counts.length, 3);
      expect(counts.total, 6);
      expect(
        [for (var index = 0; index < 3; index++) counts.rowsOf(index)],
        [1, 2, 3],
      );
      expect(
        [for (var index = 0; index <= 3; index++) counts.rowsBefore(index)],
        [0, 1, 3, 6],
      );
    });

    test('remembers an empty buffer', () {
      final counts = RowCounts((index, _) => 1, (index, _) => 1);
      final empty = LogViewController();

      expect(counts.sync(empty), (entries: 0, rows: 0));
      expect(counts.length, 0);
      expect(counts.total, 0);
      expect(counts.indexAtRow(0), 0);
      expect(counts.indexAtRow(5), 0);
      expect(counts.rowsBefore(0), 0);
      expect(counts.measure(0, 0, 10, 200), 0);
    });

    test('measures an entry again and reports the change', () {
      final logs = LogViewController(buffer: LogBuffer(maxLines: 100));
      logs.add(_lines(0, 3));
      final rows = [1, 2, 3];
      final counts = RowCounts(
        (index, _) => rows[index],
        (index, _) => rows[index],
      );
      counts.sync(logs);
      counts.measure(0, 0, 10, 200);

      final revision = counts.revision;
      rows[1] = 5;

      expect(counts.remeasure(1), 3);
      expect(counts.rowsOf(1), 5);
      expect(counts.total, 9);
      expect(counts.revision, greaterThan(revision));
    });

    test('moves the offset by a change above it', () {
      final logs = LogViewController(buffer: LogBuffer(maxLines: 100));
      logs.add(_lines(0, 3));
      final rows = [1, 2, 3];
      final counts = RowCounts(
        (index, _) => rows[index],
        (index, _) => rows[index],
      );
      counts.sync(logs);

      // Row 2 opens entry 1; entry 0 growing moves the offset by as much.
      rows[0] = 4;
      expect(counts.measure(0, 2, 10, 200), 3);
      expect(counts.rowsOf(0), 4);
      expect(counts.total, 9);
    });

    test('keeps its share of the entry the offset is in', () {
      final logs = LogViewController(buffer: LogBuffer(maxLines: 100));
      logs.add(_lines(0, 2));
      final rows = [2, 2];
      final counts = RowCounts(
        (index, _) => rows[index],
        (index, _) => rows[index],
      );
      counts.sync(logs);

      // Row 3 is the second row of entry 1; shrinking entry 1 to one row
      // moves the offset to that row, not past it.
      rows[1] = 1;
      expect(counts.measure(0, 3, 10, 200), -1);
      expect(counts.rowsOf(1), 1);
      expect(counts.total, 3);
    });

    test('evicts entries that left the front', () {
      final logs = LogViewController(buffer: LogBuffer(maxLines: 2));
      logs.add(_lines(0, 2));
      final counts = RowCounts((index, _) => 1, (index, _) => 1);
      counts.sync(logs);

      logs.add(_lines(2, 3));
      expect(counts.sync(logs), (entries: 2, rows: 2));

      expect(counts.length, 2);
      expect(counts.total, 2);
      expect(
        [for (var index = 0; index <= 2; index++) counts.rowsBefore(index)],
        [0, 1, 2],
      );
      expect(counts.indexAtRow(0), 0);
      expect(counts.indexAtRow(99), 1);
    });

    test('finds the entry holding a row and clamps past the ends', () {
      final logs = LogViewController(buffer: LogBuffer(maxLines: 100));
      logs.add(_lines(0, 3));
      final counts = RowCounts(
        (index, _) => index + 1,
        (index, _) => index + 1,
      );
      counts.sync(logs);

      expect(counts.indexAtRow(0), 0);
      expect(counts.indexAtRow(1), 1);
      expect(counts.indexAtRow(2), 1);
      expect(counts.indexAtRow(3), 2);
      expect(counts.indexAtRow(6), 2);
      expect(counts.indexAtRow(99), 2);
    });

    test('compacts its slots and keeps the sums', () {
      final logs = LogViewController(buffer: LogBuffer(maxLines: 2000));
      logs.add(_lines(0, 1100));
      final counts = RowCounts((index, _) => 1, (index, _) => 1);
      counts.sync(logs);

      expect(counts.length, 1100);
      expect(counts.total, 1100);
      expect(counts.rowsBefore(550), 550);
      expect(counts.rowsBefore(1100), 1100);
      expect(counts.indexAtRow(1099), 1099);
    });
  });
}
