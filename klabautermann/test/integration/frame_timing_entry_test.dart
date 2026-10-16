// The entry point of the S5 frame-timing leg (03 §11.4, §11.6): CI's
// klabautermann_frame_timing job runs it directly, on main pushes only,
// so a lost executable bit or a renamed test would first show there.
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  late Uri klabautermann;

  setUpAll(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_klabautermann_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');
    klabautermann = workspace.resolve('../');
  });

  File script() =>
      File.fromUri(klabautermann.resolve('scripts/bench-frame-timing.sh'));

  test('is an executable bash script that parses', () async {
    expect(script().statSync().mode & 0x40, isNot(0), reason: 'owner x bit');

    final syntax = await Process.run('bash', ['-n', script().path]);
    expect(syntax.exitCode, 0, reason: '${syntax.stderr}');
  });

  test('drives the app\'s frame-timing test in profile mode', () {
    final text = script().readAsStringSync();
    expect(text, contains('--profile'));
    for (final path in [
      'test_driver/integration_test.dart',
      'integration_test/frame_timing_test.dart',
    ]) {
      expect(text, contains(path));
      expect(
        File.fromUri(
          klabautermann.resolve('app/klabautermann_app/$path'),
        ).existsSync(),
        isTrue,
        reason: path,
      );
    }
  });
}
