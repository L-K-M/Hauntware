// NET-04's script through real shells (03 §7.11), with a stand-in `ss`
// or `netstat` on a PATH that holds only the tools the script calls, so
// the tool choice does not depend on the runner. The stand-ins name this
// test's own process, whose real cgroups the script then reads. Each
// runs as the builder's argv with `sh` replaced by the shell under test.
// Tagged `shell`; a shell that is not installed gets no tests.
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
  late Directory bin;

  setUp(() async {
    bin = await Directory.systemTemp.createTemp('klab-ports-');
    for (final tool in ['grep', 'tr', 'sort', 'cat']) {
      final found =
          (Process.runSync('sh', ['-c', 'command -v $tool']).stdout as String)
              .trim();
      expect(found, isNotEmpty, reason: '$tool is not installed');
      await Link('${bin.path}/$tool').create(found);
    }
  });

  tearDown(() => bin.delete(recursive: true));

  Future<void> standIn(String name, String output) async {
    final file = File('${bin.path}/$name');
    await file.writeAsString("#!/bin/sh\ncat <<'END'\n$output\nEND\n");
    final chmod = await Process.run('chmod', ['+x', file.path]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
  }

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      Future<ListeningPortsRead> run() async {
        final argv = [
          for (final w in HostCommands.listeningPorts()) w == 'sh' ? shell : w,
        ];
        final r = await Process.run(
          argv.first,
          argv.sublist(1),
          environment: {'PATH': bin.path},
          includeParentEnvironment: false,
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final read = parseListeningPorts(r.stdout as String);
        expect(read, isNotNull, reason: '${r.stdout}');
        return read!;
      }

      test('ss sockets and their processes\' cgroups', () async {
        await standIn(
          'ss',
          'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* '
              'users:(("dart",pid=$pid,fd=3))',
        );
        final read = await run();
        expect(read.tool, PortsTool.ss);
        expect(read.sockets.single.processes.single.pid, pid);
        expect(read.owners.keys, [pid]);
      });

      test('netstat where there is no ss', () async {
        await standIn(
          'netstat',
          'tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN $pid/dart',
        );
        final read = await run();
        expect(read.tool, PortsTool.netstat);
        expect(read.sockets.single.port, 22);
        expect(read.owners.keys, [pid]);
      });

      test('neither tool', () async {
        final read = await run();
        expect(read.tool, PortsTool.none);
        expect(read.sockets, isEmpty);
      });
    });
  }
}
