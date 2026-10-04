// Release tooling stays outside the shipped applications.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/release_version.dart';

void main() {
  late Directory sandbox;
  late Directory root;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'hauntware-release-version-test-',
    );
    root = Directory(p.join(sandbox.path, 'repository'))..createSync();
    _writeFixture(root);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('check passes on a coherent suite tree', () {
    final report = SuiteReleaseWorkspace(root).check();

    expect(report.version.semantic, '1.1.0');
    expect(report.version.appVersion, '1.1.0+1010099');
    // Manifest + 10 packages + the live bench shim + 3 apps; workspace
    // roots (unversioned) and vendored forks stay out of the count.
    expect(report.pubspecCount, 15);
    expect(report.lockedPackageCount, greaterThan(0));
  });

  test('check accepts an explicit expected version', () {
    final report = SuiteReleaseWorkspace(
      root,
    ).check(expected: ReleaseVersion.parse('1.1.0'));

    expect(report.version.semantic, '1.1.0');
  });

  test('check refuses a mismatched package version', () {
    _bump(root, 'planchette/packages/planchette_core/pubspec.yaml', '0.9.9');

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('planchette_core'),
        ),
      ),
    );
  });

  test('check refuses an app build-code mismatch', () {
    _bump(root, 'seance/app/seance_app/pubspec.yaml', '1.1.0+1000199');

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          allOf(contains('seance'), contains('1010099')),
        ),
      ),
    );
  });

  test('check refuses an app version without a build code', () {
    _bump(root, 'poltergeist/app/poltergeist_app/pubspec.yaml', '1.1.0');

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('lacks a numeric build code'),
        ),
      ),
    );
  });

  test('check refuses a stale literal Apple bundle version', () {
    _replace(
      root,
      'poltergeist/app/poltergeist_app/macos/Runner/Info.plist',
      '<string>2.1.0</string>',
      '<string>2.0.1</string>',
    );

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Info.plist'), contains('2.1.0')),
        ),
      ),
    );
  });

  test('check refuses a literal where Flutter variable metadata belongs', () {
    _replace(
      root,
      'seance/app/seance_app/macos/Runner/Info.plist',
      r'<string>$(FLUTTER_BUILD_NUMBER)</string>',
      '<string>2.1.0</string>',
    );

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('FLUTTER_BUILD_NUMBER'),
        ),
      ),
    );
  });

  test('check refuses a stale README marker', () {
    _replace(
      root,
      'planchette/README.md',
      '<!-- version -->1.1.0<!-- /version -->',
      '<!-- version -->0.1.0<!-- /version -->',
    );

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('planchette'),
        ),
      ),
    );
  });

  test('check refuses a stale owned pin in a lockfile', () {
    _replace(
      root,
      'seance/app/seance_app/pubspec.lock',
      'version: "1.1.0"',
      'version: "0.9.2"',
    );

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          allOf(contains('pubspec.lock'), contains('seance_core')),
        ),
      ),
    );
  });

  test('the live bench compat shim stays inside lockstep', () {
    // tool/bench is a live forwarding package, not frozen evidence — a
    // stale version there must fail like any other owned pubspec.
    _bump(root, 'poltergeist/tool/bench/pubspec.yaml', '1.0.1');

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('tool/bench/pubspec.yaml'),
        ),
      ),
    );
  });

  test('a stale owned pin in the bench lockfile is refused', () {
    _replace(
      root,
      'poltergeist/tool/bench/pubspec.lock',
      'version: "1.1.0"',
      'version: "0.9.2"',
    );

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          allOf(contains('tool/bench/pubspec.lock'), contains('0.9.2')),
        ),
      ),
    );
  });

  test('vendored packages stay outside lockstep', () {
    // The fixture's vendored xterm (4.0.0+seance.1) and flutter_pty
    // (0.4.2) pubspecs keep upstream versions — the passing baseline
    // already proves it; make it explicit.
    final report = SuiteReleaseWorkspace(root).check();
    expect(report.version.semantic, '1.1.0');
  });

  test('sync rewrites app pubspecs and literal plists atomically', () {
    _bump(root, 'planchette/app/planchette_app/pubspec.yaml', '0.1.0+1');
    _bump(root, 'seance/app/seance_app/pubspec.yaml', '0.9.2');
    _bump(
      root,
      'poltergeist/app/poltergeist_app/pubspec.yaml',
      '1.0.1+1000199',
    );
    _replace(
      root,
      'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
      '<string>2.1.0</string>',
      '<string>2.0.1</string>',
    );

    SuiteReleaseWorkspace(
      root,
    ).syncAppMetadata(version: ReleaseVersion.parse('1.1.0'));

    expect(
      _pubspecVersion(root, 'planchette/app/planchette_app/pubspec.yaml'),
      '1.1.0+1010099',
    );
    expect(
      _pubspecVersion(root, 'seance/app/seance_app/pubspec.yaml'),
      '1.1.0+1010099',
    );
    expect(
      _pubspecVersion(root, 'poltergeist/app/poltergeist_app/pubspec.yaml'),
      '1.1.0+1010099',
    );
    for (final plist in [
      'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
      'poltergeist/app/poltergeist_app/macos/Runner/Info.plist',
    ]) {
      expect(_read(root, plist), contains('<string>2.1.0</string>'));
    }
    // Package pubspecs and the Flutter-variable plists are untouched.
    expect(
      _pubspecVersion(root, 'planchette/packages/planchette_core/pubspec.yaml'),
      '1.1.0',
    );
    expect(
      _read(root, 'seance/app/seance_app/macos/Runner/Info.plist'),
      contains(r'$(FLUTTER_BUILD_NUMBER)'),
    );
  });

  test('checkReleaseOrder accepts a target ahead of tree and tags', () {
    final checked = SuiteReleaseWorkspace(root).checkReleaseOrder(
      target: ReleaseVersion.parse('1.1.1'),
      priorTags: const ['v1.0.0', 'v1.1.0'],
    );

    expect(checked.semantic, '1.1.1');
  });

  test('checkReleaseOrder permits tagging the current version', () {
    final checked = SuiteReleaseWorkspace(
      root,
    ).checkReleaseOrder(priorTags: const ['v1.0.0']);

    expect(checked.semantic, '1.1.0');
  });

  test('checkReleaseOrder refuses a target behind the newest tag', () {
    expect(
      () => SuiteReleaseWorkspace(root).checkReleaseOrder(
        target: ReleaseVersion.parse('1.1.0'),
        priorTags: const ['v1.2.0'],
      ),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('v1.2.0'),
        ),
      ),
    );
  });

  test('checkReleaseOrder refuses a downgrade against the tree', () {
    expect(
      () => SuiteReleaseWorkspace(
        root,
      ).checkReleaseOrder(target: ReleaseVersion.parse('1.0.9')),
      throwsA(isA<ReleaseVersionStateException>()),
    );
  });

  test('checkTag verifies a release tag against the tree', () {
    final report = SuiteReleaseWorkspace(root).checkTag('v1.1.0');
    expect(report.version.semantic, '1.1.0');

    expect(
      () => SuiteReleaseWorkspace(root).checkTag('1.1.0'),
      throwsA(isA<ReleaseVersionFormatException>()),
    );
    expect(
      () => SuiteReleaseWorkspace(root).checkTag('v1.2.0'),
      throwsA(isA<ReleaseVersionStateException>()),
    );
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

  String readme(String version) =>
      '# readme\n**Version:** v<!-- version -->$version<!-- /version -->\n';

  String plist(String bundleVersion) =>
      '<?xml version="1.0"?>\n<plist><dict>\n'
      '\t<key>CFBundleShortVersionString</key>\n'
      '\t<string>\$(FLUTTER_BUILD_NAME)</string>\n'
      '\t<key>CFBundleVersion</key>\n'
      '\t<string>$bundleVersion</string>\n'
      '</dict></plist>\n';

  String lock(Map<String, String> pathPackages) {
    final buffer = StringBuffer('packages:\n');
    pathPackages.forEach((name, version) {
      buffer.write(
        '  $name:\n'
        '    dependency: "direct main"\n'
        '    description:\n'
        '      path: "../packages/$name"\n'
        '      relative: true\n'
        '    source: path\n'
        '    version: "$version"\n',
      );
    });
    buffer.write('sdks:\n  dart: ">=3.12.0 <4.0.0"\n');
    return buffer.toString();
  }

  // Suite manifest.
  write('pubspec.yaml', 'name: hauntware\npublish_to: none\nversion: 1.1.0\n');

  // --- Planchette ---
  write('planchette/pubspec.yaml', 'name: _planchette_workspace\n');
  for (final package in [
    'ghost_desktop',
    'ghost_ui',
    'planchette_core',
    'planchette_editor',
  ]) {
    write('planchette/packages/$package/pubspec.yaml', pubspec(package));
  }
  write(
    'planchette/app/planchette_app/pubspec.yaml',
    pubspec('planchette_app', '1.1.0+1010099'),
  );
  write(
    'planchette/app/planchette_app/pubspec.lock',
    lock({'planchette_core': '1.1.0'}),
  );
  write(
    'planchette/app/planchette_app/macos/Runner/Info.plist',
    plist(r'$(FLUTTER_BUILD_NUMBER)'),
  );
  write('planchette/README.md', readme('1.1.0'));
  write('planchette/pubspec.lock', lock({'planchette_core': '1.1.0'}));

  // --- Séance ---
  write('seance/pubspec.yaml', 'name: _seance_workspace\n');
  for (final package in [
    'seance_core',
    'seance_protocol',
    'seance_sync_server',
  ]) {
    write('seance/packages/$package/pubspec.yaml', pubspec(package));
  }
  write(
    'seance/app/seance_app/pubspec.yaml',
    pubspec('seance_app', '1.1.0+1010099'),
  );
  write(
    'seance/app/seance_app/pubspec.lock',
    lock({'seance_core': '1.1.0', 'planchette_core': '1.1.0'}),
  );
  write(
    'seance/app/seance_app/ios/Runner/Info.plist',
    plist(r'$(FLUTTER_BUILD_NUMBER)'),
  );
  write(
    'seance/app/seance_app/macos/Runner/Info.plist',
    plist(r'$(FLUTTER_BUILD_NUMBER)'),
  );
  write('seance/README.md', readme('1.1.0'));

  // Vendored forks keep upstream versions and licenses.
  write(
    'seance/third_party/xterm/pubspec.yaml',
    pubspec('xterm', '4.0.0+seance.1'),
  );
  write(
    'seance/third_party/flutter_pty/pubspec.yaml',
    pubspec('flutter_pty', '0.4.2'),
  );

  // --- Poltergeist ---
  write('poltergeist/pubspec.yaml', 'name: _poltergeist_workspace\n');
  // The bench package's directory and pubspec name differ in the real
  // tree — keep the fixture faithful.
  write(
    'poltergeist/packages/poltergeist_bench/pubspec.yaml',
    pubspec('poltergeist_m0_bench'),
  );
  for (final package in ['poltergeist_core', 'poltergeist_sync']) {
    write('poltergeist/packages/$package/pubspec.yaml', pubspec(package));
  }
  write(
    'poltergeist/app/poltergeist_app/pubspec.yaml',
    pubspec('poltergeist_app', '1.1.0+1010099'),
  );
  write(
    'poltergeist/app/poltergeist_app/pubspec.lock',
    lock({'poltergeist_core': '1.1.0', 'seance_core': '1.1.0'}),
  );
  write(
    'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
    plist('2.1.0'),
  );
  write(
    'poltergeist/app/poltergeist_app/macos/Runner/Info.plist',
    plist('2.1.0'),
  );
  write('poltergeist/README.md', readme('1.1.0'));

  // The live compat shim — versioned and locked like every other owned
  // package. Only the M0 evidence docs are frozen (they carry no
  // pubspec).
  write(
    'poltergeist/tool/bench/pubspec.yaml',
    pubspec('poltergeist_m0_bench_compat'),
  );
  write(
    'poltergeist/tool/bench/pubspec.lock',
    lock({'poltergeist_m0_bench': '1.1.0', 'seance_core': '1.1.0'}),
  );
}

void _bump(Directory root, String relativePath, String version) {
  final file = File(p.join(root.path, relativePath));
  final contents = file.readAsStringSync();
  file.writeAsStringSync(
    contents.replaceFirst(
      RegExp(r'^version: .*$', multiLine: true),
      'version: $version',
    ),
  );
}

void _replace(
  Directory root,
  String relativePath,
  String pattern,
  String replacement,
) {
  final file = File(p.join(root.path, relativePath));
  file.writeAsStringSync(
    file.readAsStringSync().replaceFirst(pattern, replacement),
  );
}

String _read(Directory root, String relativePath) =>
    File(p.join(root.path, relativePath)).readAsStringSync();

String _pubspecVersion(Directory root, String relativePath) =>
    _read(root, relativePath)
        .split('\n')
        .firstWhere((line) => line.startsWith('version:'))
        .split(':')[1]
        .trim();
