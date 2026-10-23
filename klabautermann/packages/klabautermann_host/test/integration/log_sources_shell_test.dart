// The v1 log source scripts through real shells (03 §7.6): the
// `/var/log` listing on this host, and rotated reads of `.gz` and `.xz`
// files through the real `zcat` and `xzcat`, including a corrupt file and
// a decompressor that is not installed. Each runs as the builder's argv
// with `sh` replaced by the shell under test. Tagged `shell`; a shell or
// tool that is not installed gets no tests.
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

String? _which(String tool) {
  final r = Process.runSync('sh', ['-c', 'command -v $tool']);
  final path = (r.stdout as String).trim();
  return r.exitCode == 0 && path.isNotEmpty ? path : null;
}

/// [argv] with the builder's `sh` replaced by [shell].
List<String> _under(String shell, List<String> argv) => [
  for (final w in argv) w == 'sh' ? shell : w,
];

Future<ProcessResult> _run(
  String shell,
  List<String> argv, {
  Map<String, String>? environment,
}) {
  final words = _under(shell, argv);
  return Process.run(
    words.first,
    words.sublist(1),
    environment: environment,
    includeParentEnvironment: environment == null,
  );
}

void main() {
  late Directory dir;
  final lines = [for (var i = 1; i <= 200; i++) 'line $i'];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('klab-logs-');
    await File('${dir.path}/app.log').writeAsString('${lines.join('\n')}\n');
  });

  tearDown(() => dir.delete(recursive: true));

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      test('the /var/log listing parses cleanly', () async {
        final r = await _run(shell, HostCommands.logFiles());
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final parsed = parseLogFiles(r.stdout as String);
        expect(parsed.warnings, isEmpty);
        expect(parsed.value, isNotEmpty, reason: 'nothing listed');
        for (final f in parsed.value) {
          expect(f.path, startsWith('/var/log/'));
        }
      });

      for (final (tool, compress, suffix) in [
        ('zcat', 'gzip', 'gz'),
        ('xzcat', 'xz', 'xz'),
      ]) {
        test('a .$suffix log reads its last lines through $tool', () async {
          if (_which(tool) == null || _which(compress) == null) {
            markTestSkipped('$tool or $compress is not installed');
            return;
          }
          final plain = '${dir.path}/app.log';
          expect((await Process.run(compress, [plain])).exitCode, 0);
          final r = await _run(
            shell,
            HostCommands.rotatedTail('$plain.$suffix', lines: 3),
          );
          expect(r.stdout, 'line 198\nline 199\nline 200\n');
          expect(rotatedTailFailure(r.stderr as String), isNull);
        });
      }

      test('a corrupt archive reports the failure', () async {
        if (_which('zcat') == null) {
          markTestSkipped('zcat is not installed');
          return;
        }
        final bad = File('${dir.path}/bad.log.gz')..writeAsStringSync('nope');
        final r = await _run(
          shell,
          HostCommands.rotatedTail(bad.path, lines: 3),
        );
        expect(rotatedTailFailure(r.stderr as String), isNot(anyOf(isNull, 0)));
      });

      test('a decompressor that is not installed reports 127', () async {
        final tail = _which('tail');
        if (tail == null) {
          markTestSkipped('tail is not installed');
          return;
        }
        final bin = Directory('${dir.path}/bin')..createSync();
        Link('${bin.path}/tail').createSync(tail);
        final archive = File('${dir.path}/app.log.xz')..writeAsStringSync('');
        final r = await _run(
          shell,
          HostCommands.rotatedTail(archive.path, lines: 3),
          environment: {'PATH': bin.path},
        );
        expect(rotatedTailFailure(r.stderr as String), 127);
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
