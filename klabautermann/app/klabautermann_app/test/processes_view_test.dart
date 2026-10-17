import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/processes_view.dart';
import 'package:klabautermann_app/ui/sortable_table.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

ProcessRow _row(
  int pid, {
  String? name,
  List<MaskedValue>? arguments,
  String? userName,
  int? uid,
}) => ProcessRow(
  pid: pid,
  name: name,
  arguments: arguments,
  userName: userName,
  uid: uid,
);

final _mysql = _row(
  812,
  name: 'mysqld',
  uid: 27,
  arguments: [
    MaskedValue.plain('mysqld'),
    MaskedValue.redacted('-p********', '-phunter2'),
    MaskedValue.secret('s3cr3t'),
  ],
);

/// PRC-01's rules apart from the widgets: what a row shows of its command
/// line and user, what the filter reads and what the list says it left
/// out.
void main() {
  group('commandLineText', () {
    test('joins the shown arguments, so a masked one shows only its mask '
        '(SAF-07)', () {
      expect(commandLineText(_mysql), 'mysqld -p******** ********');
      expect(
        commandLineText(_mysql, maskWord: '(masked)'),
        'mysqld -p(masked) (masked)',
      );
    });

    test('is null where the host gave no command line (7.2)', () {
      expect(commandLineText(_row(2, name: 'kthreadd')), isNull);
      expect(commandLineText(_row(2, arguments: const [])), isNull);
    });

    test('cuts a long line, keeping a surrogate pair whole', () {
      final long = commandLineText(
        _row(3, arguments: [MaskedValue.plain('a' * 5000)]),
      )!;
      expect(long, '${'a' * kProcessTextLimit}…');

      final emoji = clipProcessText(
        '${'a' * (kProcessTextLimit - 1)}\u{1F600}',
      );
      expect(emoji, '${'a' * (kProcessTextLimit - 1)}…');
    });
  });

  test('a user is ps\'s name, the probe\'s login user for its uid, or '
      'unknown by name', () {
    final profile = HostProfile(uid: 1000, user: 'deploy');

    expect(
      processUserName(_row(1, userName: 'www-data', uid: 33), profile),
      'www-data',
    );
    // GNU ps cuts a name wider than its column to seven characters and a
    // plus sign: not the name.
    expect(
      processUserName(_row(1, userName: 'systemd+', uid: 101), profile),
      isNull,
    );
    // GNU and BusyBox ps print the uid where no passwd entry names it.
    expect(
      processUserName(_row(1, userName: '123456', uid: 123456), profile),
      isNull,
    );
    expect(processUserName(_row(1, uid: 1000), profile), 'deploy');
    expect(processUserName(_row(1, uid: 0), profile), isNull);
    expect(processUserName(_row(1, uid: 1000), null), isNull);
  });

  test('users sort by name, then those known by uid alone by number, '
      'then the unknown', () {
    final profile = HostProfile(uid: 1000, user: 'deploy');
    final rows = [
      _row(1, uid: 1000),
      _row(2, uid: 33),
      _row(3),
      _row(4, userName: 'alice'),
      _row(5, uid: 0),
      _row(6, userName: '123456', uid: 123456),
    ];
    final user = SortableTableColumn<ProcessRow>(
      id: 'user',
      label: 'User',
      text: (_) => '',
      sortKey: (row) => processUserSortKey(row, profile),
    );
    final sorted = sortTableRows(rows, [
      user,
    ], const TableSort('user', TableSortDirection.ascending));

    expect([for (final row in sorted) row.pid], [4, 1, 5, 2, 6, 3]);
  });

  group('filterProcesses', () {
    final rows = [
      _mysql,
      _row(
        1,
        name: 'systemd',
        uid: 0,
        arguments: [MaskedValue.plain('/sbin/init')],
      ),
      _row(2, name: 'kthreadd'),
    ];
    // The user column's text without a profile.
    String user(ProcessRow row) => switch ((row.userName, row.uid)) {
      (final name?, _) => name,
      (null, final uid?) => 'UID $uid',
      (null, null) => 'unknown',
    };
    List<int> pids(String query) => [
      for (final row in filterProcesses(rows, query, user)) row.pid,
    ];

    test('keeps every row for a blank query', () {
      expect(pids('  '), [812, 1, 2]);
    });

    test('needs every term, in any case, in the PID, name, user or shown '
        'command line', () {
      expect(pids('MYSQLD -p'), [812]);
      expect(pids('init'), [1]);
      expect(pids('kthread'), [2]);
      expect(pids('812'), [812]);
      expect(pids('UID 27'), [812]);
      expect(pids('uid 0'), [1]);
      expect(pids('mysqld init'), isEmpty);
    });

    test('never matches a masked secret (SAF-07)', () {
      expect(pids('hunter2'), isEmpty);
      expect(pids('s3cr3t'), isEmpty);
    });
  });

  test('a list the host cut says how many it shows of how many (D48)', () {
    ProcsResult result(int? total, ProcsSelection? selection) => ProcsResult(
      [_row(1), _row(2)],
      totalProcesses: total,
      selection: selection,
    );

    expect(processesLeftOut(result(2, ProcsSelection.all)), isNull);
    // A ps fallback may list more rows than it counted.
    expect(processesLeftOut(result(1, ProcsSelection.all)), isNull);
    expect(processesLeftOut(result(null, null)), isNull);
    expect(processesLeftOut(result(900, ProcsSelection.cpuAndMemory)), (
      shown: 2,
      total: 900,
    ));
    expect(processesLeftOut(result(900, null)), (shown: 2, total: 900));
    expect(processesLeftOut(result(null, ProcsSelection.pidOrder)), (
      shown: 2,
      total: null,
    ));
  });
}
