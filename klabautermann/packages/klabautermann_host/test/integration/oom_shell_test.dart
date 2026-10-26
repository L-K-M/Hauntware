// MEM-03's read through a real shell: stand-in journalctl and dmesg on a
// PATH that holds only them and the tools the script uses, and
// `/proc/vmstat` pointed at a stand-in file. Tagged `shell`; a shell that
// is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

/// The tools the script runs besides journalctl and dmesg.
const _tools = ['awk', 'grep'];

const _kill =
    'Out of memory: Killed process 4321 (stress) total-vm:2kB, '
    'anon-rss:1kB';

Future<void> _stub(Directory root, String name, String script) async {
  final file = File('${root.path}/bin/$name');
  await file.writeAsString('#!/bin/sh\n$script\n');
  await Process.run('chmod', ['0755', file.path]);
}

/// Runs the read under [shell] with the stand-ins under [root].
Future<OomKillsRead?> _read(String shell, Directory root) async {
  final bin = Directory('${root.path}/bin')..createSync(recursive: true);
  for (final tool in _tools) {
    final path = [
      '/usr/bin/$tool',
      '/bin/$tool',
    ].firstWhere((path) => File(path).existsSync());
    Link('${bin.path}/$tool').createSync(path);
  }
  final argv = HostCommands.oomKills();
  final result = await Process.run(
    shell,
    [argv[1], argv[2].replaceAll('/proc/vmstat', '${root.path}/vmstat')],
    environment: {'PATH': bin.path},
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect(result.stderr, isEmpty);
  return parseOomKills(result.stdout as String);
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oom_shell_');
    await Directory('${root.path}/bin').create();
    await File(
      '${root.path}/vmstat',
    ).writeAsString('pgfault 12\noom_kill 3\noom_kill_x 9\n');
  });

  tearDown(() => root.delete(recursive: true));

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      test('reads the journal and keeps only the newest kills', () async {
        // 60 kills between other kernel lines; `-n 1` is the probe.
        await _stub(root, 'journalctl', r'''
case " $* " in *" -n 1 "*) echo '1 h kernel: Linux version'; exit 0;; esac
i=1
while [ $i -le 60 ]; do
  echo "17000000$i.000001 h kernel: usb 1-1: new device"
  echo "17000000$i.000002 h kernel: Out of memory: Killed process $i (p$i) total-vm:1kB"
  i=$((i + 1))
done''');
        final read = (await _read(shell, root))!;
        expect(read.killsSinceBoot, 3);
        expect(read.source, OomLogSource.journal);
        expect(read.logRead, isTrue);
        expect(read.kills, hasLength(kOomLinesKept));
        expect(read.kills.first.pid, 60 - kOomLinesKept + 1);
        expect(read.kills.last.pid, 60);
        expect(read.kills.last.at, isNotNull);
      });

      test(
        'falls back to dmesg when the journal shows no kernel line',
        () async {
          await _stub(root, 'journalctl', 'exit 0');
          await _stub(root, 'dmesg', "echo '[  12.000001] $_kill'");
          final read = (await _read(shell, root))!;
          expect(read.source, OomLogSource.dmesg);
          expect(
            read.kills.single.sinceBoot,
            const Duration(seconds: 12, microseconds: 1),
          );
        },
      );

      test('says when no kernel log could be read', () async {
        await _stub(
          root,
          'dmesg',
          "echo 'dmesg: read kernel buffer failed' >&2; exit 1",
        );
        await File('${root.path}/vmstat').writeAsString('pgfault 12\n');
        final read = (await _read(shell, root))!;
        expect(read.source, OomLogSource.dmesg);
        expect(read.logRead, isFalse);
        expect(read.killsSinceBoot, isNull);
      });
    });
  }
}
