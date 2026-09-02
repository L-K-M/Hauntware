import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late File fakeEngine;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-script-test-',
    );
    fakeEngine = File(p.join(sandbox.path, 'fake-release'));
    fakeEngine.writeAsStringSync('''#!/usr/bin/env bash
printf 'pubspecs=%s\n' "\$RELEASE_PUBSPECS"
printf 'regex=%s\n' "\$RELEASE_VERSION_REGEX"
printf 'post=%s\n' "\$RELEASE_POST_BUMP"
printf 'args=%s\n' "\$*"
''');
    Process.runSync('chmod', ['+x', fakeEngine.path]);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('validates and forwards a supported version family', () async {
    final result = await _runRelease(fakeEngine, ['0.2.0-beta2', '--push']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('tool/bench/pubspec.yaml'));
    expect(result.stdout, contains('app/poltergeist_app/pubspec.yaml'));
    expect(result.stdout, contains('release_version/bin/release_version.dart'));
    expect(result.stdout, contains('    sync'));
    expect(result.stdout, contains('args=0.2.0-beta2 --push'));
  });

  test('rejects an invalid version before invoking the engine', () async {
    final result = await _runRelease(fakeEngine, ['0.2.0-alpha1']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('invalid release version'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('checks the current version before a no-argument release', () async {
    final result = await _runRelease(fakeEngine, const []);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, startsWith('0.1.0+10099 synchronized'));
    expect(result.stdout, contains('args=\n'));
  });
}

Future<ProcessResult> _runRelease(File engine, List<String> arguments) {
  final root = Directory.current;
  return Process.run(
    'bash',
    ['scripts/release.sh', ...arguments],
    workingDirectory: root.path,
    environment: {...Platform.environment, 'LKM_RELEASE_BIN': engine.path},
  );
}
