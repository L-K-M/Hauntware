// The anacron script through real shells (03 §7.7, JOB-04): on this host
// it either lists the table and stamps, which then parse cleanly, or
// reports anacron missing or unreadable. Tagged `shell`; a shell that is
// not installed gets no tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test('$name: the anacron script exits with one of its statuses', () async {
      final argv = HostCommands.anacron();
      final r = await Process.run(shell, argv.sublist(1));
      expect(
        r.exitCode,
        isIn([kAnacronListed, kAnacronMissing, kAnacronUnreadable]),
      );
      if (r.exitCode == kAnacronListed) {
        expect(r.stdout, contains(kAnacronStampsMarker));
        expect(parseAnacron(r.stdout as String).warnings, isEmpty);
      }
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
