// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/release_version_cli.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late List<String> output;
  late List<String> errors;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-cli-test-',
    );
    root = Directory(p.join(sandbox.path, 'repository'))..createSync();
    _writeFixture(root);
    output = [];
    errors = [];
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  int run(List<String> arguments) {
    return runReleaseVersionCommand(
      arguments,
      workingDirectory: root,
      writeOutput: output.add,
      writeError: errors.add,
    );
  }

  test('validate prints the Android version code', () {
    expect(run(['validate', '--version', '0.1.0']), 0);
    expect(output, ['0.1.0+10099']);
    expect(errors, isEmpty);
  });

  test('validate rejects an unsupported qualifier', () {
    expect(run(['validate', '--version', '1.0.0-alpha1']), 1);
    expect(errors.single, contains('invalid release version'));
  });

  test('debian-version prints the ordered package version', () {
    expect(run(['debian-version', '--version', '0.2.0-beta1']), 0);
    expect(output, ['0.2.0~beta1-1']);
    expect(errors, isEmpty);
  });

  test('missing command arguments return usage failure', () {
    expect(run(['sync', '--version', '0.1.0']), 64);
    expect(errors.single, startsWith('usage:'));
  });

  test('sync writes the deterministic app version', () {
    expect(
      run([
        'sync',
        '--version',
        '1.1.0-beta2',
        '--pubspec',
        'app/poltergeist_app/pubspec.yaml',
      ]),
      0,
    );

    expect(
      _read(root, 'app/poltergeist_app/pubspec.yaml'),
      contains('version: 1.1.0-beta2+1010002'),
    );
  });

  test('check verifies repository synchronization', () {
    expect(run(['check', '--version', '0.1.0']), 0);
    expect(output.single, contains('3 pubspecs'));
  });

  test('check-transition accepts an upgrade', () {
    expect(run(['check-transition', '--version', '0.2.0']), 0);
    expect(output.single, contains('0.1.0 -> 0.2.0'));
  });

  test('check-transition rejects a downgrade', () {
    expect(run(['check-transition', '--version', '0.0.99']), 1);
    expect(errors.single, contains('older than 0.1.0'));
  });

  test('check-tag verifies tag grammar and repository synchronization', () {
    expect(run(['check-tag', '--tag', 'v0.1.0']), 0);
    expect(output.single, contains('v0.1.0'));
  });
}

void _writeFixture(Directory root) {
  _write(root, 'pubspec.yaml', 'name: _workspace\n');
  _write(
    root,
    'packages/poltergeist_core/pubspec.yaml',
    'name: poltergeist_core\nversion: 0.1.0\n',
  );
  _write(
    root,
    'tool/bench/pubspec.yaml',
    'name: poltergeist_bench\nversion: 0.1.0\n',
  );
  _write(root, 'app/poltergeist_app/pubspec.yaml', '''
name: poltergeist_app
version: 0.1.0+10099
dependencies:
  poltergeist_core:
    path: ../../packages/poltergeist_core
''');
  _write(root, 'app/poltergeist_app/pubspec.lock', '''
packages:
  poltergeist_core:
    dependency: "direct main"
    description:
      path: "../../packages/poltergeist_core"
    source: path
    version: "0.1.0"
''');
  _write(root, 'README.md', '<!-- version -->0.1.0<!-- /version -->\n');
}

String _read(Directory root, String path) {
  return File(p.join(root.path, path)).readAsStringSync();
}

void _write(Directory root, String path, String contents) {
  final file = File(p.join(root.path, path));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}
