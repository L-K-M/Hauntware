// The capture tool's command line: bad arguments end with the usage
// message before any measurement runs.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The tool's entry point from the workspace root (as CI runs the suite)
/// or from the package directory.
String _toolPath() {
  const packageRelative = 'tool/capture_fixtures.dart';
  return [
    'packages/klabautermann_core/$packageRelative',
    packageRelative,
  ].firstWhere((path) => File(path).existsSync());
}

void main() {
  for (final args in [
    ['--ticks', '0'],
    ['--ticks', 'x'],
    ['--ticks', '1', '--procs', '-1'],
    ['--ticks', '1', '--procs', '1000,'],
  ]) {
    test('measure ${args.join(' ')} prints the usage', () async {
      final r = await Process.run(Platform.resolvedExecutable, [
        _toolPath(),
        'measure',
        ...args,
      ]);
      expect(r.exitCode, 64, reason: '${r.stderr}');
      expect(r.stderr, contains('usage: '));
      expect(r.stdout, isEmpty);
    });
  }
}
