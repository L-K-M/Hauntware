@TestOn('posix')
library;

// Release tooling stays outside the shipped applications.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'hauntware-build-script-test-',
    );
    _writeProducts(sandbox);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('--check prints the resolved config without building', () async {
    final result = await _runBuild(sandbox, ['--check']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('planchette'));
    expect(result.stdout, contains('seance'));
    expect(result.stdout, contains('poltergeist'));
    expect(result.stdout, contains('ready'));
    expect(result.stdout, contains('missing'));
    // --check builds nothing.
    expect(Directory(p.join(sandbox.path, 'dist')).existsSync(), isFalse);
  });

  test('--help prints the contract header', () async {
    final result = await _runBuild(sandbox, ['--help']);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('Usage'));
  });

  test('unknown arguments fail with a usage hint', () async {
    final result = await _runBuild(sandbox, ['--bogus']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Unknown argument'));
  });

  test(
    'a default run builds feasible products, skips missing, stages dist',
    () async {
      final result = await _runBuild(sandbox, const []);

      expect(result.exitCode, 0, reason: result.stderr as String);
      // The fake product builds emitted their marker artifacts.
      expect(
        File(p.join(sandbox.path, 'dist', 'planchette-artifact')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(sandbox.path, 'dist', 'seance-artifact')).existsSync(),
        isTrue,
      );
      // poltergeist has no build script in this fixture — skipped.
      expect(result.stdout, contains('skip poltergeist'));
      expect(result.stdout, contains('Build summary'));
    },
  );

  test('an explicitly named missing product fails', () async {
    final result = await _runBuild(sandbox, ['poltergeist']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('poltergeist'));
  });

  test('a failing product build propagates a nonzero exit', () async {
    final result = await _runBuild(
      sandbox,
      const [],
      environment: {'FAKE_BUILD_FAIL': 'seance'},
    );

    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('seance  FAILED'));
    // The summary still reports the products that built.
    expect(result.stdout, contains('planchette  built'));
  });

  test('--debug forwards the debug profile to each product', () async {
    final result = await _runBuild(sandbox, ['--debug', 'seance']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(
      File(p.join(sandbox.path, 'seance', 'mode.marker')).readAsStringSync(),
      contains('--debug'),
    );
  });

  test('runs from an arbitrary working directory', () async {
    final elsewhere = Directory(p.join(sandbox.path, 'elsewhere'))
      ..createSync();
    final script = File(p.join(_repositoryRoot().path, 'scripts', 'build.sh'));
    final result = await Process.run(
      'bash',
      [script.path, '--check'],
      workingDirectory: elsewhere.path,
      environment: {
        ...Platform.environment,
        'HAUNTWARE_BUILD_ROOT': sandbox.path,
      },
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('Root:  ${sandbox.path}'));
  });
}

Future<ProcessResult> _runBuild(
  Directory root,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) {
  return Process.run(
    'bash',
    [p.join(_repositoryRoot().path, 'scripts', 'build.sh'), ...arguments],
    environment: {
      ...Platform.environment,
      ...environment,
      'HAUNTWARE_BUILD_ROOT': root.path,
    },
  );
}

/// Fake product scripts: planchette and seance build (each emits a dist
/// marker and records its args in mode.marker), seance fails on demand via
/// FAKE_BUILD_FAIL, and poltergeist has no script at all.
void _writeProducts(Directory root) {
  void writeScript(String product, String body) {
    final script = File(p.join(root.path, product, 'scripts', 'build.sh'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(body);
    Process.runSync('chmod', ['+x', script.path]);
  }

  writeScript('planchette', '''#!/usr/bin/env bash
set -euo pipefail
dist="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)/dist"
printf '%s' "\$*" > "\$(dirname "\${BASH_SOURCE[0]}")/../mode.marker"
mkdir -p "\$dist"
touch "\$dist/planchette-artifact"
''');
  writeScript('seance', '''#!/usr/bin/env bash
set -euo pipefail
[[ "\${FAKE_BUILD_FAIL:-}" == seance ]] && exit 1
dist="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)/dist"
printf '%s' "\$*" > "\$(dirname "\${BASH_SOURCE[0]}")/../mode.marker"
mkdir -p "\$dist"
touch "\$dist/seance-artifact"
''');
}

Directory _repositoryRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(p.join(candidate.path, 'scripts', 'build.sh')).existsSync() &&
        File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate;
    }

    final parent = candidate.parent;
    if (p.equals(parent.path, candidate.path)) {
      throw StateError('repository root not found from ${Directory.current}');
    }
    candidate = parent;
  }
}
