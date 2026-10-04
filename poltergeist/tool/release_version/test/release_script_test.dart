@TestOn('posix')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late File fakeEngine;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-forwarder-test-',
    );
    fakeEngine = File(p.join(sandbox.path, 'fake-release'))
      ..writeAsStringSync('''#!/usr/bin/env bash
set -euo pipefail
printf 'args=%s\n' "\$*"
printf 'cwd=%s\n' "\$PWD"
printf 'app=%s\n' "\$RELEASE_APP_NAME"
''');
    Process.runSync('chmod', ['+x', fakeEngine.path]);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('scripts/release.sh forwards the whole-suite release to the root', () async {
    final root = _repositoryRoot();
    final result = await Process.run(
      'bash',
      [p.join(root.path, 'poltergeist/scripts/release.sh'), '--help'],
      workingDirectory: sandbox.path,
      environment: {
        ...Platform.environment,
        'LKM_RELEASE_BIN': fakeEngine.path,
      },
    );

    // The child never releases independently: it execs the root stub,
    // which reaches the engine from the repository root with the suite
    // configuration.
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('args=--help'));
    expect(result.stdout, contains('cwd=${root.path}'));
    expect(result.stdout, contains('app=Hauntware'));
  });
}

/// Finds the monorepo root — the directory that owns the root release
/// stub plus the three project trees.
Directory _repositoryRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(p.join(candidate.path, 'scripts', 'release.sh')).existsSync() &&
        File(p.join(candidate.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(candidate.path, 'poltergeist')).existsSync()) {
      return candidate;
    }

    final parent = candidate.parent;
    if (p.equals(parent.path, candidate.path)) {
      throw StateError('repository root not found from ${Directory.current}');
    }
    candidate = parent;
  }
}
