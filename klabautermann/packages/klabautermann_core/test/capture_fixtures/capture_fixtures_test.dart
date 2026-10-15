// The capture tool's command line: bad arguments end with the usage
// message before any capture or measurement runs.
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
  final out = Directory.systemTemp.path;
  // Holds an existing platform directory `p`.
  final root = Directory.systemTemp.createTempSync('klab-capture-out-').path;
  Directory('$root/p').createSync();
  tearDownAll(() => Directory(root).deleteSync(recursive: true));
  // Compiled once: each run from source compiles seance_core again.
  late final String kernel;
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('klab-capture-tool-');
    addTearDown(() => dir.deleteSync(recursive: true));
    kernel = '${dir.path}/capture_fixtures.dill';
    final r = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '-o',
      kernel,
      _toolPath(),
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });

  for (final (args, message) in [
    (['measure', '--ticks', '0'], '--ticks'),
    (['measure', '--ticks', 'x'], '--ticks'),
    (['measure', '--ticks', '1', '--procs', '-1'], '--procs'),
    (['measure', '--ticks', '1', '--procs', '1000,'], '--procs'),
    (['measure', '--replace'], 'unexpected argument --replace'),
    (['capture', '--ticks', '1'], 'unexpected argument --ticks'),
    (['capture', '--out', '$out/klab-missing'], 'does not exist'),
    (['capture', '--out', out, '--platform', '../x'], '--platform'),
    (['capture', '--out', root, '--platform', 'p'], 'pass --replace'),
    (
      ['capture', '--out', out, '--sh', 'dash', '--login-shell', 'bash'],
      '--sh',
    ),
    (['capture', '--out', out, '--sh', 'klab-no-shell'], 'not on'),
  ]) {
    // Stable names: the temporary paths differ between runs.
    final name = args
        .join(' ')
        .replaceAll(root, '<dir>')
        .replaceAll(out, '<tmp>');
    test('$name prints the usage', () async {
      final r = await Process.run(Platform.resolvedExecutable, [
        kernel,
        ...args,
      ]);
      expect(r.exitCode, 64, reason: '${r.stderr}');
      expect(r.stderr, allOf(contains(message), contains('usage: ')));
      expect(r.stdout, isEmpty);
    });
  }
}
