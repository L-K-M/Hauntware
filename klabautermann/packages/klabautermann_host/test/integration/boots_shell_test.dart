// BOOT-02 and BOOT-03's scripts through real shells (03 §7.11): the boot
// ends against a stand-in `journalctl` on PATH that answers each earlier
// boot as clean, unclean or unreadable, and the kernel read on this host.
// Each runs as the builder's argv with `sh` replaced by the shell under
// test. Tagged `shell`; a shell that is not installed gets no tests.
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

final _clean = 'a' * 32;
final _unclean = 'b' * 32;
final _unreadable = 'c' * 32;
final _current = 'd' * 32;

/// A `journalctl` that lists four boots, the current one last, and
/// answers each earlier boot's journal as its name says.
String get _fakeJournalctl =>
    '''#!/bin/sh
case "\$*" in
  *--list-boots*)
    echo "IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY"
    echo " -3 $_clean Mon 2026-10-19 08:00:00 UTC Mon 2026-10-19 20:00:00 UTC"
    echo " -2 $_unclean Tue 2026-10-20 08:00:00 UTC Tue 2026-10-20 20:00:00 UTC"
    echo " -1 $_unreadable Wed 2026-10-21 08:00:00 UTC Wed 2026-10-21 20:00:00 UTC"
    echo "  0 $_current Thu 2026-10-22 08:00:00 UTC Thu 2026-10-22 20:00:00 UTC"
    ;;
  *"-b $_unreadable"*) ;;
  *_PID=1*) echo "Started Session 1 of User root." ;;
  *"-b $_clean"*) printf 'Stopping Docker...\\nReached target Reboot.\\nJournal stopped\\n' ;;
  *"-b $_unclean"*) printf 'nginx: worker started\\nkernel: EXT4-fs mounted\\n' ;;
esac
''';

void main() {
  late Directory bin;

  setUp(() async {
    bin = await Directory.systemTemp.createTemp('klab-boots-');
    final script = File('${bin.path}/journalctl');
    await script.writeAsString(_fakeJournalctl);
    await Process.run('chmod', ['+x', script.path]);
  });

  tearDown(() => bin.delete(recursive: true));

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      List<String> under(List<String> argv) => [
        for (final w in argv) w == 'sh' ? shell : w,
      ];

      test('each earlier boot ends clean, unclean or unknown, and the '
          'current boot is left out', () async {
        final words = under(HostCommands.bootEnds());
        final r = await Process.run(
          words.first,
          words.sublist(1),
          environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(parseBootEnds(r.stdout as String), {
          _clean: BootEnd.clean,
          _unclean: BootEnd.unclean,
          _unreadable: BootEnd.unknown,
        });
      });

      test('without journalctl nothing is listed', () async {
        final words = under(HostCommands.bootEnds());
        final r = await Process.run(
          words.first,
          words.sublist(1),
          environment: {'PATH': bin.path},
          includeParentEnvironment: false,
        );
        // The stand-in is on PATH but the shell utilities are not, so the
        // list reads as empty.
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(parseBootEnds(r.stdout as String), isEmpty);
      });

      test('the kernel read parses on this host', () async {
        final words = under(HostCommands.kernels());
        final r = await Process.run(words.first, words.sublist(1));
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final check = parseKernels(r.stdout as String)!;
        final release = (Process.runSync('uname', ['-r']).stdout as String)
            .trim();
        expect(check.running, release);
      });
    });
  }
}
