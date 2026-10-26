// PRC-04's process read through real shells (03 §7.2): a child process
// of the test, read with its own start ticks, and refused with others.
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

void main() {
  late Process child;
  late int startTicks;

  setUp(() async {
    child = await Process.start(
      'sleep',
      ['60'],
      environment: {'KLAB_TEST_TOKEN': 's3cret'},
    );
    final stat = File('/proc/${child.pid}/stat').readAsStringSync();
    startTicks = int.parse(
      stat.substring(stat.lastIndexOf(') ') + 2).split(' ')[19],
    );
  });

  tearDown(() => child.kill());

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      Future<ProcessResult> run(int ticks) {
        final words = [
          for (final w in HostCommands.processDetail(child.pid, ticks))
            w == 'sh' ? shell : w,
        ];
        return Process.run(words.first, words.sublist(1));
      }

      test('reads its own child', () async {
        final r = await run(startTicks);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final detail = parseProcessDetail(r.stdout as String)!;
        expect(detail.cwd, Directory.current.resolveSymbolicLinksSync());
        expect(detail.threads, 1);
        expect(detail.openFiles, greaterThan(0));
        expect(detail.openFilesLimit?.soft, isNotNull);
        expect(detail.environment, contains('KLAB_TEST_TOKEN=s3cret'));
      });

      test('another start ticks value is a reused PID, and a gone PID is '
          'gone', () async {
        expect((await run(startTicks + 1)).exitCode, kProcessDetailReused);
        child.kill();
        await child.exitCode;
        expect((await run(startTicks)).exitCode, kGuardedKillGone);
      });
    });
  }
}
