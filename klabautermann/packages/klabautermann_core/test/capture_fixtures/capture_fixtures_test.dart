// The capture tool's command line: bad arguments end with the usage
// message before any measurement runs.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final args in [
    ['--ticks', '0'],
    ['--ticks', 'x'],
    ['--ticks', '1', '--procs', '-1'],
    ['--ticks', '1', '--procs', '1000,'],
  ]) {
    test('measure ${args.join(' ')} prints the usage', () async {
      final r = await Process.run(Platform.resolvedExecutable, [
        'tool/capture_fixtures.dart',
        'measure',
        ...args,
      ]);
      expect(r.exitCode, 64, reason: '${r.stderr}');
      expect(r.stderr, contains('usage: '));
      expect(r.stdout, isEmpty);
    });
  }
}
