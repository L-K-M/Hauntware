// CTR-10's container top: the columns ps named and one row of cells per
// process, rows that do not match the columns skipped, and a body that
// is not the answer read as empty with a warning.
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

void main() {
  test('reads the titles and each row, keeping spaces in the command', () {
    final r = parseContainerTop({
      'Titles': ['PID', 'USER', '%CPU', 'RSS', 'ELAPSED', 'COMMAND'],
      'Processes': [
        ['4211', 'root', '0.0', '5120', '01:02:03', 'nginx: master process'],
        ['4250', '101', '0.3', '2048', '01:02:01', 'nginx: worker process'],
        ['bad'],
        'not a row',
      ],
    });
    expect(r.value.titles.last, 'COMMAND');
    expect(r.value.processes, hasLength(2));
    expect(r.value.processes.first.last, 'nginx: master process');
    expect(r.warnings, [
      'container top row skipped',
      'container top row skipped',
    ]);
  });

  test('an empty container lists its titles and no rows', () {
    final r = parseContainerTop({
      'Titles': ['UID', 'PID', 'PPID', 'C', 'STIME', 'TTY', 'TIME', 'CMD'],
      'Processes': null,
    });
    expect(r.value.titles, hasLength(8));
    expect(r.value.processes, isEmpty);
    expect(r.warnings, isEmpty);
  });

  test('a body that is not the answer reads as empty, with a warning', () {
    for (final body in [
      null,
      [],
      {'Titles': 'PID'},
      {
        'Titles': [1],
      },
    ]) {
      final r = parseContainerTop(body);
      expect(r.value.titles, isEmpty, reason: '$body');
      expect(r.warnings, isNotEmpty, reason: '$body');
    }
  });
}
