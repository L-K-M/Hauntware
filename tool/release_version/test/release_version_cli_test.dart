// Release tooling stays outside the shipped applications.
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
      'hauntware-release-cli-test-',
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

  test('validate prints the bounded build code', () {
    expect(run(['validate', '--version', '1.1.0']), 0);
    expect(output, ['1.1.0+1010099']);
    expect(errors, isEmpty);
  });

  test('validate rejects a qualifier and an out-of-bounds component', () {
    expect(run(['validate', '--version', '1.1.0-alpha1']), 1);
    expect(errors.single, contains('invalid release version'));

    errors.clear();
    expect(run(['validate', '--version', '1.100.0']), 1);
    expect(errors.single, contains('between 0 and 99'));
  });

  test('check verifies the suite tree', () {
    expect(run(['check']), 0);
    expect(output.single, contains('1.1.0+1010099'));
    expect(output.single, contains('7 pubspecs'));
    expect(errors, isEmpty);
  });

  test('check resolves a relative root from the working directory', () {
    final result = runReleaseVersionCommand(
      ['check', '--root', p.basename(root.path)],
      workingDirectory: sandbox,
      writeOutput: output.add,
      writeError: errors.add,
    );

    expect(result, 0);
    expect(errors, isEmpty);
  });

  test('sync rewrites all products without a pubspec argument', () {
    expect(run(['sync', '--version', '1.1.1']), 0);
    expect(output.single, contains('1.1.1+1010199'));
    expect(
      _pubspecVersion(root, 'seance/app/seance_app/pubspec.yaml'),
      '1.1.1+1010199',
    );
  });

  test('check-order verifies target ordering against prior tags', () {
    expect(
      run([
        'check-order',
        '--version',
        '1.2.0',
        '--prior-tag',
        'v1.1.0',
        '--prior-tag',
        'v1.0.9',
      ]),
      0,
    );
    expect(output.single, contains('preserves release order'));
  });

  test('check-tag compares a release tag with the tree', () {
    expect(run(['check-tag', '--tag', 'v1.1.0']), 0);
    expect(output.single, contains('v1.1.0'));
  });

  test('pubspecs lists the bump set, root manifest first', () {
    expect(run(['pubspecs']), 0);
    expect(output.single, startsWith('pubspec.yaml '));
    expect(output.single, contains('seance/app/seance_app/pubspec.yaml'));
    expect(
      output.single,
      contains('poltergeist/packages/poltergeist_core/pubspec.yaml'),
    );
  });

  test('post-bump syncs app metadata, locks, and README markers', () {
    expect(run(['post-bump', '--version', '1.1.1']), 0);
    expect(output.single, contains('1.1.1+1010199'));
    expect(
      _pubspecVersion(root, 'seance/app/seance_app/pubspec.yaml'),
      '1.1.1+1010199',
    );
    expect(
      File(
        p.join(root.path, 'seance/app/seance_app/pubspec.lock'),
      ).readAsStringSync(),
      contains('version: "1.1.1"'),
    );
    expect(
      File(p.join(root.path, 'seance/README.md')).readAsStringSync(),
      contains('<!-- version -->1.1.1<!-- /version -->'),
    );
    expect(
      File(
        p.join(
          root.path,
          'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
        ),
      ).readAsStringSync(),
      contains('<string>2.1.1</string>'),
    );
  });

  test('post-bump requires a version', () {
    expect(run(['post-bump']), 64);
    expect(errors.single, startsWith('usage:'));
  });

  test('usage failures and option misuse return 64', () {
    expect(run(const []), 64);
    expect(errors.single, startsWith('usage:'));

    errors.clear();
    expect(run(['sync']), 64);
    expect(errors.single, startsWith('usage:'));

    errors.clear();
    expect(run(['check', '--pubspec', 'x/pubspec.yaml']), 64);
    expect(errors.single, startsWith('usage:'));

    errors.clear();
    expect(run(['check', '--root', '--version']), 64);
    expect(errors.single, startsWith('usage:'));
  });
}

void _writeFixture(Directory root) {
  void write(String path, String contents) {
    File(p.join(root.path, path))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  String pubspec(String name, [String version = '1.1.0']) =>
      'name: $name\nversion: $version\n';
  String plist(String bundleVersion) =>
      '<plist><dict>\n'
      '\t<key>CFBundleVersion</key>\n'
      '\t<string>$bundleVersion</string>\n'
      '</dict></plist>\n';
  String readme(String version) =>
      'v<!-- version -->$version<!-- /version -->\n';

  write('pubspec.yaml', 'name: hauntware\nversion: 1.1.0\n');
  for (final project in ['planchette', 'seance', 'poltergeist']) {
    write(
      '$project/packages/${project}_core/pubspec.yaml',
      pubspec('${project}_core'),
    );
    write(
      '$project/app/${project}_app/pubspec.yaml',
      pubspec('${project}_app', '1.1.0+1010099'),
    );
    write('$project/README.md', readme('1.1.0'));
  }
  write(
    'seance/app/seance_app/pubspec.lock',
    'packages:\n'
        '  seance_core:\n'
        '    dependency: "direct main"\n'
        '    description:\n'
        '      path: "../../packages/seance_core"\n'
        '      relative: true\n'
        '    source: path\n'
        '    version: "1.1.0"\n'
        'sdks:\n  dart: ">=3.12.0 <4.0.0"\n',
  );
  write(
    'planchette/app/planchette_app/macos/Runner/Info.plist',
    plist(r'$(FLUTTER_BUILD_NUMBER)'),
  );
  write(
    'seance/app/seance_app/ios/Runner/Info.plist',
    plist(r'$(FLUTTER_BUILD_NUMBER)'),
  );
  write(
    'seance/app/seance_app/macos/Runner/Info.plist',
    plist(r'$(FLUTTER_BUILD_NUMBER)'),
  );
  write(
    'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
    plist('2.1.0'),
  );
  write(
    'poltergeist/app/poltergeist_app/macos/Runner/Info.plist',
    plist('2.1.0'),
  );
}

String _pubspecVersion(Directory root, String relativePath) =>
    File(p.join(root.path, relativePath))
        .readAsLinesSync()
        .singleWhere((line) => line.startsWith('version:'))
        .substring('version:'.length)
        .trim();
