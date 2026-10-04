// Release tooling stays outside the shipped applications.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test('sync changes only app release metadata', () {
    _bump(root, 'seance/app/seance_app/pubspec.yaml', '0.9.2');
    _replace(
      root,
      'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
      '<string>2.1.0</string>',
      '<string>2.0.1</string>',
    );
    final others = [
      for (final file in root.listSync(recursive: true).whereType<File>())
        p.relative(file.path, from: root.path),
    ]..removeWhere(_syncTargets.contains);
    expect(others, isNotEmpty);
    final before = _snapshot(root, others);

    SuiteReleaseWorkspace(
      root,
    ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1'));

    expect(
      _pubspecVersion(root, 'seance/app/seance_app/pubspec.yaml'),
      '1.1.1+1010199',
    );
    // Package pubspecs, lockfiles, READMEs and Flutter-variable plists
    // belong to post-bump and the release engine, not to sync.
    expect(_snapshot(root, others), before);
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

  test('check refuses an app pubspec with a drifted semantic version', () {
    _bump(root, 'seance/app/seance_app/pubspec.yaml', '1.2.0+1020099');

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('seance app pubspec declares 1.2.0; expected 1.1.0'),
        ),
      ),
    );
  });

  test('check refuses whitespace inside a README version marker', () {
    _replace(
      root,
      'planchette/README.md',
      '<!-- version -->1.1.0<!-- /version -->',
      '<!-- version --> 1.1.0 <!-- /version -->',
    );

    expect(
      () => SuiteReleaseWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('planchette README version marker must equal 1.1.0'),
        ),
      ),
    );
  });

  test('checkReleaseOrder refuses a target equal to the newest tag', () {
    expect(
      () => SuiteReleaseWorkspace(root).checkReleaseOrder(
        target: ReleaseVersion.parse('1.1.0'),
        priorTags: const ['v1.1.0'],
      ),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('must exceed prior tag v1.1.0'),
        ),
      ),
    );
  });

  test('checkReleaseOrder without a target refuses re-tagging the tree', () {
    expect(
      () => SuiteReleaseWorkspace(
        root,
      ).checkReleaseOrder(priorTags: const ['v1.1.0']),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('must exceed prior tag v1.1.0'),
        ),
      ),
    );
  });

  test('checkReleaseOrder fails closed on an unsupported prior tag', () {
    expect(
      () => SuiteReleaseWorkspace(root).checkReleaseOrder(
        target: ReleaseVersion.parse('1.2.0'),
        priorTags: const ['v1.1.0-alpha1'],
      ),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('cannot establish release order from prior tag'),
        ),
      ),
    );
  });

  test('checkReleaseOrder accepts duplicate prior tags', () {
    final checked = SuiteReleaseWorkspace(root).checkReleaseOrder(
      target: ReleaseVersion.parse('1.2.0'),
      priorTags: const ['v1.1.0', 'v1.1.0'],
    );

    expect(checked.semantic, '1.2.0');
  });

  test('sync preserves a trailing app version comment', () {
    const pubspecPath = 'planchette/app/planchette_app/pubspec.yaml';
    _replace(
      root,
      pubspecPath,
      'version: 1.1.0+1010099',
      'version: 1.1.0+1010099 # release metadata',
    );

    SuiteReleaseWorkspace(
      root,
    ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1'));

    expect(
      _read(root, pubspecPath),
      contains('version: 1.1.1+1010199 # release metadata\n'),
    );
  });

  for (final (name, contents) in [
    ('a missing', 'name: seance_app\n'),
    ('a bare', 'name: seance_app\nversion:\n'),
  ]) {
    test('sync rejects $name app version before writing', () {
      _write(root, 'seance/app/seance_app/pubspec.yaml', contents);
      final before = _snapshot(root, _syncTargets);

      expect(
        () => SuiteReleaseWorkspace(
          root,
        ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
        throwsA(
          isA<ReleaseVersionStateException>().having(
            (e) => e.message,
            'message',
            contains('exactly one top-level version'),
          ),
        ),
      );
      expect(_snapshot(root, _syncTargets), before);
    });
  }

  test('sync validates every metadata source before writing', () {
    _replace(
      root,
      'poltergeist/app/poltergeist_app/macos/Runner/Info.plist',
      '<key>CFBundleVersion</key>',
      '<key>CFBundleIdentifier</key>',
    );
    final before = _snapshot(root, _syncTargets);

    expect(
      () => SuiteReleaseWorkspace(
        root,
      ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('exactly one CFBundleVersion'),
        ),
      ),
    );
    expect(_snapshot(root, _syncTargets), before);
  });

  test('sync stages every rewrite before replacing metadata', () {
    final before = _snapshot(root, _syncTargets);
    var temporaryCount = 0;

    expect(
      () => IOOverrides.runZoned(
        () => SuiteReleaseWorkspace(
          root,
        ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
        createFile: (path) {
          final file = _unoverriddenFile(path);
          if (!_isReleaseTemporary(path)) return file;

          temporaryCount++;
          if (temporaryCount == 2) return _CreateFailingFile(file);

          return file;
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(_snapshot(root, _syncTargets), before);
    expect(
      _releaseTemporaries(root),
      isEmpty,
      reason: 'staging failure must not leak temporary files',
    );
  });

  test('post-bump stages every lock rewrite before replacing a lock', () {
    const failingDirectory = 'poltergeist/tool/bench';
    final locks = [
      'planchette/app/planchette_app/pubspec.lock',
      'planchette/pubspec.lock',
      'poltergeist/app/poltergeist_app/pubspec.lock',
      '$failingDirectory/pubspec.lock',
      'seance/app/seance_app/pubspec.lock',
    ];
    final before = _snapshot(root, locks);

    expect(
      () => IOOverrides.runZoned(
        () =>
            SuiteReleaseWorkspace(root).postBump(ReleaseVersion.parse('1.1.1')),
        createFile: (path) {
          final file = _unoverriddenFile(path);
          if (!_isReleaseTemporary(path)) return file;
          // Only the bench lock is rewritten in this directory, and it
          // stages after the planchette and poltergeist app locks.
          if (p.equals(p.dirname(path), p.join(root.path, failingDirectory))) {
            return _CreateFailingFile(file);
          }

          return file;
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(_snapshot(root, locks), before);
    expect(
      _releaseTemporaries(root),
      isEmpty,
      reason: 'staging failure must not leak temporary files',
    );
  });

  test('sync removes a temporary file after staged validation fails', () {
    late File temporary;

    expect(
      () => IOOverrides.runZoned(
        () => SuiteReleaseWorkspace(
          root,
        ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
        createFile: (path) {
          final file = _unoverriddenFile(path);
          if (!_isReleaseTemporary(path)) return file;

          temporary = file;
          return _InvalidatingFile(file, _DeleteMode.delegate);
        },
      ),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('version'),
        ),
      ),
    );
    expect(temporary.existsSync(), isFalse);
  });

  test('sync preserves the primary error when temporary cleanup fails', () {
    late File temporary;

    expect(
      () => IOOverrides.runZoned(
        () => SuiteReleaseWorkspace(
          root,
        ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
        createFile: (path) {
          final file = _unoverriddenFile(path);
          if (!_isReleaseTemporary(path)) return file;

          temporary = file;
          return _InvalidatingFile(file, _DeleteMode.fail);
        },
      ),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('missing or non-string version'),
        ),
      ),
    );
    expect(temporary.existsSync(), isTrue);
  });

  test('sync does not follow a predictable dangling temporary link', () {
    const pubspecPath = 'planchette/app/planchette_app/pubspec.yaml';
    final target = File(p.join(root.path, pubspecPath));
    final outside = File(p.join(sandbox.path, 'outside-pubspec.yaml'));
    Link('${target.path}.$pid.release-version.tmp').createSync(outside.path);

    SuiteReleaseWorkspace(
      root,
    ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1'));

    expect(outside.existsSync(), isFalse);
    expect(_pubspecVersion(root, pubspecPath), '1.1.1+1010199');
  }, skip: Platform.isWindows ? 'requires symbolic-link permission' : false);

  test('sync does not delete a path recreated after its rename', () {
    const foreignContents = 'concurrent file';
    final recreated = <File>[];

    IOOverrides.runZoned(
      () => SuiteReleaseWorkspace(
        root,
      ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
      createFile: (path) {
        final file = _unoverriddenFile(path);
        if (!_isReleaseTemporary(path)) return file;

        recreated.add(file);
        return _RecreatingRenameFile(file, foreignContents);
      },
    );

    // Three app pubspecs plus the two literal poltergeist plists.
    expect(recreated, hasLength(5));
    for (final file in recreated) {
      expect(file.readAsStringSync(), foreignContents);
    }
  });

  test('sync rejects the repository root as a product file', () {
    expect(
      () => SuiteReleaseWorkspace(
        root,
        products: const [
          SuiteProduct(name: 'root', appPubspecPath: '.', readmePath: '.'),
        ],
      ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('must identify a file inside repository root'),
        ),
      ),
    );
  });

  test('sync rejects a product path outside the repository', () {
    const outsideContents = 'name: outside\nversion: 0.1.0\n';
    _write(sandbox, 'outside-pubspec.yaml', outsideContents);

    expect(
      () => SuiteReleaseWorkspace(
        root,
        products: const [
          SuiteProduct(
            name: 'outside',
            appPubspecPath: '../outside-pubspec.yaml',
            readmePath: 'README.md',
          ),
        ],
      ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (e) => e.message,
          'message',
          contains('path leaves repository root'),
        ),
      ),
    );
    expect(_read(sandbox, 'outside-pubspec.yaml'), outsideContents);
  });

  for (final (name, pubspecPath) in [
    ('a product path through a symlink', 'linked/pubspec.yaml'),
    (
      'a symlinked product path with a missing tail',
      'linked/missing/pubspec.yaml',
    ),
  ]) {
    test('sync rejects $name leaving the repository', () {
      final outside = Directory(p.join(sandbox.path, 'outside'))..createSync();
      const outsideContents = 'name: outside\nversion: 0.1.0\n';
      _write(outside, 'pubspec.yaml', outsideContents);
      Link(p.join(root.path, 'linked')).createSync(outside.path);

      expect(
        () => SuiteReleaseWorkspace(
          root,
          products: [
            SuiteProduct(
              name: 'linked',
              appPubspecPath: pubspecPath,
              readmePath: 'README.md',
            ),
          ],
        ).syncAppMetadata(version: ReleaseVersion.parse('1.1.1')),
        throwsA(
          isA<ReleaseVersionStateException>().having(
            (e) => e.message,
            'message',
            contains('path leaves repository root'),
          ),
        ),
      );
      expect(_read(outside, 'pubspec.yaml'), outsideContents);
    }, skip: Platform.isWindows ? 'requires symbolic-link permission' : false);
  }
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

// Every file a default-products sync may rewrite.
const _syncTargets = [
  'planchette/app/planchette_app/pubspec.yaml',
  'seance/app/seance_app/pubspec.yaml',
  'poltergeist/app/poltergeist_app/pubspec.yaml',
  'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
  'poltergeist/app/poltergeist_app/macos/Runner/Info.plist',
];

Map<String, String> _snapshot(Directory root, List<String> relativePaths) => {
  for (final path in relativePaths) path: _read(root, path),
};

void _write(Directory root, String relativePath, String contents) {
  File(p.join(root.path, relativePath))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

String _read(Directory root, String relativePath) =>
    File(p.join(root.path, relativePath)).readAsStringSync();

String _pubspecVersion(Directory root, String relativePath) =>
    _read(root, relativePath)
        .split('\n')
        .firstWhere((line) => line.startsWith('version:'))
        .split(':')[1]
        .trim();

final RegExp _releaseTemporaryNamePattern = RegExp(
  r'^\.hauntware-[0-9a-f]{32}\.tmp$',
);

bool _isReleaseTemporary(String path) {
  return _releaseTemporaryNamePattern.hasMatch(p.basename(path));
}

Iterable<File> _releaseTemporaries(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => _isReleaseTemporary(file.path));

/// Bypasses the zone's `createFile` override, which would otherwise
/// recurse into itself.
File _unoverriddenFile(String path) {
  return File.fromRawPath(Uint8List.fromList(utf8.encode(path)));
}

final class _CreateFailingFile implements File {
  final File _delegate;

  const _CreateFailingFile(this._delegate);

  @override
  String get path => _delegate.path;

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    throw FileSystemException('temporary creation failed', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

/// Recreates its own path right after a successful rename, standing in
/// for a concurrent writer that must not lose its file to cleanup.
final class _RecreatingRenameFile implements File {
  final File _delegate;
  final String _foreignContents;

  const _RecreatingRenameFile(this._delegate, this._foreignContents);

  @override
  String get path => _delegate.path;

  @override
  bool existsSync() => _delegate.existsSync();

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    _delegate.createSync(recursive: recursive, exclusive: exclusive);
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _delegate.writeAsStringSync(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    return _delegate.readAsStringSync(encoding: encoding);
  }

  @override
  File renameSync(String newPath) {
    final renamed = _delegate.renameSync(newPath);
    _delegate.writeAsStringSync(_foreignContents);
    return renamed;
  }

  @override
  void deleteSync({bool recursive = false}) {
    _delegate.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

enum _DeleteMode { delegate, fail }

/// Reads back malformed contents so staged validation fails.
final class _InvalidatingFile implements File {
  final File _delegate;
  final _DeleteMode _deleteMode;

  const _InvalidatingFile(this._delegate, this._deleteMode);

  @override
  String get path => _delegate.path;

  @override
  bool existsSync() => _delegate.existsSync();

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    _delegate.createSync(recursive: recursive, exclusive: exclusive);
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _delegate.writeAsStringSync(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) => ': malformed';

  @override
  void deleteSync({bool recursive = false}) {
    if (_deleteMode == _DeleteMode.fail) {
      throw FileSystemException('temporary cleanup failed', path);
    }

    _delegate.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
