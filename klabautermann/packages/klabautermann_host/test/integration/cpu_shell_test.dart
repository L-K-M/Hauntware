// CPU-07's script through real shells (03 §7.11): the read on this host
// against `nproc`, and without `lscpu` on PATH, where `/proc/cpuinfo`
// alone answers. Each runs as the builder's argv with `sh` replaced by
// the shell under test. Tagged `shell`; a shell that is not installed
// gets no tests.
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

/// The directories holding the tools the script calls, but not `lscpu`.
Future<Directory> _pathWithoutLscpu() async {
  final bin = await Directory.systemTemp.createTemp('klab-cpu-');
  for (final tool in ['nproc', 'getconf', 'grep']) {
    final found =
        (Process.runSync('sh', ['-c', 'command -v $tool']).stdout as String)
            .trim();
    if (found.isNotEmpty) await Link('${bin.path}/$tool').create(found);
  }
  return bin;
}

void main() {
  final usable = int.parse(
    (Process.runSync('nproc', []).stdout as String).trim(),
  );

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      List<String> under(List<String> argv) => [
        for (final w in argv) w == 'sh' ? shell : w,
      ];

      test('the read parses on this host', () async {
        final words = under(HostCommands.cpuTopology());
        final r = await Process.run(words.first, words.sublist(1));
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final cpu = parseCpuTopology(r.stdout as String)!;
        expect(cpu.usableCpus, usable);
        expect(cpu.logicalCpus, greaterThanOrEqualTo(usable));
      });

      test('without lscpu, /proc/cpuinfo answers', () async {
        final bin = await _pathWithoutLscpu();
        addTearDown(() => bin.delete(recursive: true));
        final words = under(HostCommands.cpuTopology());
        final r = await Process.run(
          words.first,
          words.sublist(1),
          environment: {'PATH': bin.path},
          includeParentEnvironment: false,
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final cpu = parseCpuTopology(r.stdout as String)!;
        expect(cpu.vendor, isNull);
        expect(cpu.usableCpus, usable);
        expect(cpu.logicalCpus, greaterThanOrEqualTo(usable));
      });
    });
  }
}
