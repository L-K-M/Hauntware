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

  test(
    'scripts/release.sh forwards the whole-suite release to the root',
    () async {
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
    },
  );

  // Inside the monorepo the module CLI's tree checks must report the
  // suite — a module-scoped scan can no longer resolve the app's path
  // dependencies, which now point outside the module root.
  test('module check forwards to the suite root inside the monorepo', () async {
    final root = _repositoryRoot();
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/release_version/bin/release_version.dart',
      'check',
    ], workingDirectory: p.join(root.path, 'poltergeist'));

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('1.1.0+1010099'));
    // The suite-wide count proves the report came from the root tool.
    expect(result.stdout, contains('15 pubspecs'));
  });

  test('module check-tag and check-order forward to the suite root', () async {
    final root = _repositoryRoot();
    for (final arguments in [
      ['check-tag', '--tag', 'v1.1.0'],
      ['check-order', '--version', '1.2.0'],
    ]) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/release_version/bin/release_version.dart',
        ...arguments,
      ], workingDirectory: p.join(root.path, 'poltergeist'));

      expect(
        result.exitCode,
        0,
        reason: '${arguments.first}: ${result.stderr}',
      );
    }
  });

  test('module check keeps standalone semantics outside a monorepo', () async {
    final standalone = Directory(p.join(sandbox.path, 'standalone'))
      ..createSync();
    _writeStandaloneFixture(standalone);

    final root = _repositoryRoot();
    final result = await Process.run(Platform.resolvedExecutable, [
      p.join(
        root.path,
        'poltergeist/tool/release_version/bin/release_version.dart',
      ),
      'check',
      '--root',
      standalone.path,
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    // A module report, not the suite's 15-pubspec one.
    expect(result.stdout, contains('3 pubspecs'));
  });
}

/// A standalone poltergeist-shaped tree — the module check must still
/// pass on it unforwarded.
void _writeStandaloneFixture(Directory root) {
  void write(String path, String contents) {
    File(p.join(root.path, path))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  write('pubspec.yaml', 'name: _workspace\npublish_to: none\n');
  write(
    'packages/poltergeist_core/pubspec.yaml',
    'name: poltergeist_core\nversion: 0.1.0\n',
  );
  write('tool/bench/pubspec.yaml', 'name: poltergeist_bench\nversion: 0.1.0\n');
  write('app/poltergeist_app/pubspec.yaml', '''
name: poltergeist_app
version: 0.1.0+10099
dependencies:
  poltergeist_core:
    path: ../../packages/poltergeist_core
''');
  write('app/poltergeist_app/pubspec.lock', '''
packages:
  poltergeist_core:
    dependency: "direct main"
    description:
      path: "../../packages/poltergeist_core"
      relative: true
    source: path
    version: "0.1.0"
''');
  for (final path in [
    'app/poltergeist_app/ios/Runner/Info.plist',
    'app/poltergeist_app/macos/Runner/Info.plist',
  ]) {
    write(path, '''
<plist>
<dict>
  <key>CFBundleVersion</key>
  <string>1.1.0</string>
</dict>
</plist>
''');
  }
  write(
    'README.md',
    '**Current version:** v<!-- version -->0.1.0<!-- /version -->\n',
  );
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
