// Runs the procs fragment in a real `sh` with a PATH that lacks some
// tools, to check what its `meta` block claims about the command lines.
@Tags(['shell'])
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// Runs `c_procs` under `/bin/sh` with only [tools] on PATH and returns
/// the `o` it builds.
Future<String> _runProcs(List<String> tools) async {
  final bin = await Directory.systemTemp.createTemp('procs_path');
  addTearDown(() => bin.delete(recursive: true));
  for (final tool in tools) {
    final path = [
      '/usr/bin/$tool',
      '/bin/$tool',
    ].firstWhere((p) => File(p).existsSync());
    await Link('${bin.path}/$tool').create(path);
  }
  final script = StringBuffer()
    ..writeln("NL='\n'")
    ..writeln(r'hw_run() { "$@"; }')
    ..writeln(collectorFragments[Collector.procs]!)
    ..writeln(r'c_procs; printf "%s\n" "$o"');
  final result = await Process.run(
    '/bin/sh',
    ['-c', script.toString()],
    environment: {'PATH': bin.path},
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result.stdout as String;
}

String _meta(String o) => o.split('== rows ==').first;

void main() {
  test(
    'cmdline_cap is claimed when head and tr read the command lines',
    () async {
      final o = await _runProcs(['head', 'tr', 'sort', 'ps']);
      expect(o, contains('== cmdline =='));
      expect(_meta(o), contains('cmdline_cap=$kProcsCmdlineByteCap'));
    },
  );

  test(
    'cmdline_cap is not claimed when tr is missing and ps is used',
    () async {
      final o = await _runProcs(['head', 'sort', 'ps']);
      expect(o, contains('== ps =='));
      expect(_meta(o), isNot(contains('cmdline_cap=')));
    },
  );
}
