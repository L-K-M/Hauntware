// Release tooling stays outside the shipped applications.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

// The version arithmetic — parse/bounds, the bounded monotonic Android
// code, the app `+code` form, and the Apple bundle-version offset — is the
// proven poltergeist implementation. Reusing it keeps one source of truth
// for every mapping a suite release depends on; this file adds only the
// monorepo-wide workspace contract around it.
import '../../../poltergeist/tool/release_version/lib/release_version.dart'
    show
        ReleaseVersion,
        ReleaseVersionFormatException,
        ReleaseVersionReport,
        ReleaseVersionStateException;

export '../../../poltergeist/tool/release_version/lib/release_version.dart'
    show
        ReleaseVersion,
        ReleaseVersionFormatException,
        ReleaseVersionReport,
        ReleaseVersionStateException;

const int _temporaryTokenByteCount = 16;
const int _byteValueCount = 256;
const int _hexRadix = 16;
const int _hexByteWidth = 2;
const String _temporaryPrefix = '.hauntware-';
const String _temporarySuffix = '.tmp';
const String _rootPubspecPath = 'pubspec.yaml';
const String _rootReadmePath = 'README.md';

// The suite's three projects ship one coordinated release.
const List<String> _projectNames = ['planchette', 'seance', 'poltergeist'];

// Versioned trees the suite release does not own.
//
// third_party/ carries vendored forks pinned to upstream versions and
// licenses; test/fixture/example trees may pin their own versions. The
// M0 benchmark evidence under poltergeist docs/ is prose, not pubspec —
// tool/bench itself is the live compat shim and stays in lockstep.
const Set<String> _unmanagedDirectories = {
  'example',
  'examples',
  'fixture',
  'fixtures',
  'test',
  'third_party',
};

const Set<String> _ignoredDirectories = {
  '.dart_tool',
  '.git',
  '.plugin_symlinks',
  '.symlinks',
  'build',
  'ephemeral',
  'Pods',
};

final RegExp _appVersionPattern = RegExp(r'^(.+)\+([0-9]+)$');
final RegExp _versionLinePattern = RegExp(
  r'^(version:[ \t]*)([^#\s]+)([ \t]*(?:#[^\r\n]*)?)$',
  multiLine: true,
);
final RegExp _readmeVersionPattern = RegExp(
  r'<!-- version -->([^<]+)<!-- /version -->',
);
final RegExp _appleBundleVersionPattern = RegExp(
  r'(<key>CFBundleVersion</key>\s*<string>)([^<]*)(</string>)',
);
// A lockfile package entry is a two-space name key followed, later in the
// same entry, by a four-space quoted `version:` — the same shape the old
// sed hook rewrote.
final RegExp _lockEntryNamePattern = RegExp(r'^  (\w+):');
final RegExp _lockEntryVersionPattern = RegExp(r'^(    version: ")[^"]*(".*)$');
const String _flutterBuildNumberVariable = r'$(FLUTTER_BUILD_NUMBER)';
final Random _secureRandom = Random.secure();

/// Rewrites the `version:` pin of every `packages:` entry whose name is
/// owned by the suite, preserving everything else — dependency stanzas,
/// sources, hashes, and non-owned pins all stay byte-identical.
String _rewriteLockPins(String contents, Set<String> names, String version) {
  var currentName = '';
  final lines = contents.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final nameMatch = _lockEntryNamePattern.firstMatch(lines[index]);
    if (nameMatch != null) {
      currentName = nameMatch[1]!;
      continue;
    }

    final versionMatch = _lockEntryVersionPattern.firstMatch(lines[index]);
    if (versionMatch != null && names.contains(currentName)) {
      lines[index] = '${versionMatch[1]}$version${versionMatch[2]}';
    }
  }
  return lines.join('\n');
}

/// One product in the coordinated suite release.
final class SuiteProduct {
  final String name;
  final String appPubspecPath;
  final String readmePath;
  final List<String> literalBundlePlistPaths;
  final List<String> flutterVariablePlistPaths;

  const SuiteProduct({
    required this.name,
    required this.appPubspecPath,
    required this.readmePath,
    this.literalBundlePlistPaths = const [],
    this.flutterVariablePlistPaths = const [],
  });
}

const List<SuiteProduct> _defaultProducts = [
  SuiteProduct(
    name: 'planchette',
    appPubspecPath: 'planchette/app/planchette_app/pubspec.yaml',
    readmePath: 'planchette/README.md',
    flutterVariablePlistPaths: [
      'planchette/app/planchette_app/macos/Runner/Info.plist',
    ],
  ),
  SuiteProduct(
    name: 'seance',
    appPubspecPath: 'seance/app/seance_app/pubspec.yaml',
    readmePath: 'seance/README.md',
    flutterVariablePlistPaths: [
      'seance/app/seance_app/ios/Runner/Info.plist',
      'seance/app/seance_app/macos/Runner/Info.plist',
    ],
  ),
  SuiteProduct(
    name: 'poltergeist',
    appPubspecPath: 'poltergeist/app/poltergeist_app/pubspec.yaml',
    readmePath: 'poltergeist/README.md',
    literalBundlePlistPaths: [
      'poltergeist/app/poltergeist_app/ios/Runner/Info.plist',
      'poltergeist/app/poltergeist_app/macos/Runner/Info.plist',
    ],
  ),
];

/// Synchronizes and verifies the suite's release-version declarations.
///
/// The root `pubspec.yaml` is the suite manifest: every owned versioned
/// pubspec must equal its semantic version, each product's app pubspec
/// adds the shared bounded build code, each product README marker and
/// literal `CFBundleVersion` carries the matching forms, and every
/// committed lockfile pins owned path packages at the suite version.
final class SuiteReleaseWorkspace {
  final Directory _root;
  final List<SuiteProduct> _products;

  SuiteReleaseWorkspace(Directory root, {List<SuiteProduct>? products})
    : _root = Directory(p.normalize(p.absolute(root.path))),
      _products = products ?? _defaultProducts {
    if (!_root.existsSync()) {
      throw ReleaseVersionStateException(
        'repository root does not exist: ${_root.path}',
      );
    }
  }

  ReleaseVersion currentVersion() {
    final file = _resolveInsideRoot(_rootPubspecPath);
    if (!file.existsSync()) {
      throw const ReleaseVersionStateException(
        'suite manifest is missing: $_rootPubspecPath',
      );
    }

    final value = _readPubspecVersion(
      file,
      requirement: _VersionRequirement.required,
    )!;
    try {
      return ReleaseVersion.parse(value);
    } on ReleaseVersionFormatException catch (error) {
      throw ReleaseVersionStateException(
        'suite manifest version is invalid: ${error.message}',
      );
    }
  }

  /// Verifies the whole tree declares [expected] (or the manifest's own
  /// version) consistently. Checking mutates nothing.
  ReleaseVersionReport check({ReleaseVersion? expected}) {
    final version = expected ?? currentVersion();
    final appPaths = <String>{
      for (final product in _products) product.appPubspecPath,
    };

    final declarations = <_PubspecVersion>[];
    for (final file in _findPubspecs()) {
      final relativePath = p.relative(file.path, from: _root.path);
      if (_isUnmanagedPath(relativePath)) continue;

      final value = _readPubspecVersion(file);
      if (value == null) continue;

      declarations.add(
        _PubspecVersion(file: file, relativePath: relativePath, value: value),
      );
    }

    final appDeclarations = <String, _PubspecVersion>{};
    for (final declaration in declarations) {
      if (appPaths.contains(declaration.relativePath)) {
        appDeclarations[declaration.relativePath] = declaration;
        continue;
      }

      final actual = _parsePubspecVersion(declaration);
      if (actual.semantic != version.semantic) {
        throw ReleaseVersionStateException(
          'pubspec ${declaration.relativePath} declares ${actual.semantic}; '
          'expected ${version.semantic}',
        );
      }
    }

    for (final product in _products) {
      final declaration = appDeclarations[product.appPubspecPath];
      if (declaration == null) {
        throw ReleaseVersionStateException(
          '${product.name} app pubspec is missing or unversioned: '
          '${product.appPubspecPath}',
        );
      }
      _checkAppVersion(product, declaration, version);
      _checkReadme(product, version);
      _checkAppleVersions(product, version);
    }

    _checkRootReadme(version);
    final lockedPackageCount = _checkLocks(
      _ownedPackageNames(declarations),
      version,
    );

    return ReleaseVersionReport(
      version: version,
      pubspecCount: declarations.length,
      lockedPackageCount: lockedPackageCount,
    );
  }

  ReleaseVersionReport checkTag(String tag) {
    final version = _parseReleaseTag(tag);
    return check(expected: version);
  }

  /// A release candidate must exceed the version in the tree (when it
  /// differs) and the newest prior `v*` tag — comparing by the bounded
  /// code so ordering is identical to semantic ordering.
  ReleaseVersion checkReleaseOrder({
    ReleaseVersion? target,
    Iterable<String> priorTags = const [],
  }) {
    final current = check().version;
    final candidate = target ?? current;
    if (candidate.semantic != current.semantic &&
        candidate.androidVersionCode <= current.androidVersionCode) {
      throw ReleaseVersionStateException(
        'target ${candidate.appVersion} must exceed current tree '
        '${current.appVersion}',
      );
    }

    String? newestTag;
    ReleaseVersion? newestVersion;
    for (final tag in priorTags) {
      final version = _parsePriorTag(tag);
      if (newestVersion != null &&
          version.androidVersionCode <= newestVersion.androidVersionCode) {
        continue;
      }

      newestTag = tag;
      newestVersion = version;
    }
    if (newestVersion != null &&
        candidate.androidVersionCode <= newestVersion.androidVersionCode) {
      throw ReleaseVersionStateException(
        'target ${candidate.appVersion} must exceed prior tag $newestTag '
        '(${newestVersion.appVersion})',
      );
    }

    return candidate;
  }

  /// Rewrites every product's app pubspec to `X.Y.Z+code` and each
  /// literal `CFBundleVersion` to the Apple form. Every rewrite is staged
  /// and verified before any target is replaced — like the poltergeist
  /// tool this mirrors.
  void syncAppMetadata({required ReleaseVersion version}) {
    final rewrites = <_PreparedRewrite>[];
    for (final product in _products) {
      // Missing product files are skipped, not fatal — the release
      // engine's post-bump hook may run against a tree where a product
      // hasn't been scaffolded yet; `check` is what enforces presence.
      if (!_resolveInsideRoot(product.appPubspecPath).existsSync()) {
        continue;
      }
      rewrites.add(_prepareAppPubspec(product, version));
      for (final path in product.literalBundlePlistPaths) {
        if (_resolveInsideRoot(path).existsSync()) {
          rewrites.add(_prepareAppleInfoPlist(path, version));
        }
      }
      for (final path in product.flutterVariablePlistPaths) {
        if (_resolveInsideRoot(path).existsSync()) {
          _requireFlutterVariablePlist(path);
        }
      }
    }

    _commitRewrites(rewrites);
  }

  /// The owned versioned pubspecs the release bumps, as
  /// `RELEASE_PUBSPECS` needs them: the root manifest first — the engine
  /// reads the suite version from it — then every managed pubspec in
  /// sorted order. Vendored forks, fixture trees and the unversioned
  /// workspace roots never appear.
  List<String> bumpPubspecPaths() {
    final rest = <String>[];
    for (final file in _findPubspecs()) {
      final relativePath = p.relative(file.path, from: _root.path);
      if (relativePath == _rootPubspecPath) continue;
      if (_isUnmanagedPath(relativePath)) continue;
      if (_readPubspecVersion(file) == null) continue;

      rest.add(relativePath);
    }
    rest.sort();
    return [_rootPubspecPath, ...rest];
  }

  /// Everything the release stub's preflight must prove before the
  /// engine runs: the candidate exceeds the tree and every prior `v*`
  /// tag — collected here from local and remote, failing closed when
  /// either can't be read.
  ReleaseVersion preflight({ReleaseVersion? target}) {
    return checkReleaseOrder(target: target, priorTags: _releaseTags());
  }

  List<String> _releaseTags() {
    final tags = <String>{};
    final local = _git(const [
      'tag',
      '--list',
      'v*',
    ], 'could not read local release tags');
    for (final line in local.split('\n')) {
      final tag = line.trim();
      if (tag.isNotEmpty) tags.add(tag);
    }

    final remote = _git(const [
      'ls-remote',
      '--tags',
      '--refs',
      'origin',
      'v*',
    ], "could not read release tags from 'origin'");
    for (final line in remote.split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length != 2) continue;
      final ref = fields[1];
      if (ref.startsWith('refs/tags/')) {
        tags.add(ref.substring('refs/tags/'.length));
      }
    }
    return tags.toList();
  }

  String _git(List<String> arguments, String failureMessage) {
    try {
      final result = Process.runSync('git', ['-C', _root.path, ...arguments]);
      if (result.exitCode != 0) {
        throw ReleaseVersionStateException(failureMessage);
      }
      return result.stdout as String;
    } on ProcessException {
      throw ReleaseVersionStateException(failureMessage);
    }
  }

  /// The release engine's post-bump hook, in Dart where the rewrites are
  /// verifiable and sed-portability is a non-issue: sync the app
  /// metadata, re-pin every owned package name in every managed
  /// lockfile, and move the product README version markers. The engine
  /// itself handles the pubspec bumps and the root README marker.
  void postBump(ReleaseVersion version) {
    syncAppMetadata(version: version);
    _rewriteLocks(version);
    _rewriteReadmeMarkers(version);
  }

  void _rewriteLocks(ReleaseVersion version) {
    final names = <String>{};
    for (final file in _findPubspecs()) {
      final relativePath = p.relative(file.path, from: _root.path);
      if (_isUnmanagedPath(relativePath)) continue;
      if (_readPubspecVersion(file) == null) continue;
      final name = _readPubspecName(file);
      if (name != null) names.add(name);
    }

    final rewrites = <_PreparedRewrite>[];
    for (final file in _findLockfiles()) {
      final relativePath = p.relative(file.path, from: _root.path);
      if (_isUnmanagedPath(relativePath)) continue;

      rewrites.add(_prepareLockRewrite(file, relativePath, names, version));
    }
    _commitRewrites(rewrites);
  }

  _PreparedRewrite _prepareLockRewrite(
    File file,
    String relativePath,
    Set<String> names,
    ReleaseVersion version,
  ) {
    final original = file.readAsStringSync();
    final rewritten = _rewriteLockPins(original, names, version.semantic);
    return _PreparedRewrite(
      file: file,
      contents: rewritten,
      changed: rewritten != original,
      validate: (temporary) {
        final yaml = _readYamlMap(temporary, 'lock $relativePath');
        final packages = yaml['packages'];
        if (packages is! YamlMap) return;

        for (final entry in packages.entries) {
          if (entry.key is! String || !names.contains(entry.key)) {
            continue;
          }
          final locked = entry.value;
          if (locked is! YamlMap || locked['version'] == version.semantic) {
            continue;
          }

          throw ReleaseVersionStateException(
            'lock pin sync produced ${locked['version']} for ${entry.key} '
            'in $relativePath instead of ${version.semantic}',
          );
        }
      },
    );
  }

  void _rewriteReadmeMarkers(ReleaseVersion version) {
    final rewrites = <_PreparedRewrite>[];
    for (final product in _products) {
      final file = _resolveInsideRoot(product.readmePath);
      if (!file.existsSync()) continue;

      final original = file.readAsStringSync();
      final rewritten = original.replaceAllMapped(
        _readmeVersionPattern,
        (match) => '<!-- version -->${version.semantic}<!-- /version -->',
      );
      rewrites.add(
        _PreparedRewrite(
          file: file,
          contents: rewritten,
          changed: rewritten != original,
          validate: (temporary) {
            final matches = _readmeVersionPattern
                .allMatches(temporary.readAsStringSync())
                .toList();
            if (matches.length == 1 && matches.single[1] == version.semantic) {
              return;
            }

            throw ReleaseVersionStateException(
              '${product.name} README marker sync produced the wrong '
              'marker',
            );
          },
        ),
      );
    }
    _commitRewrites(rewrites);
  }

  void _commitRewrites(List<_PreparedRewrite> rewrites) {
    final staged = <_StagedRewrite>[];
    var committedCount = 0;
    try {
      for (final rewrite in rewrites) {
        if (!rewrite.changed) continue;

        staged.add(_stageRewrite(rewrite));
      }
      for (final rewrite in staged) {
        rewrite.temporary.renameSync(rewrite.target.path);
        committedCount++;
      }
    } finally {
      for (var index = committedCount; index < staged.length; index++) {
        _deleteTemporaryBestEffort(staged[index].temporary);
      }
    }
  }

  void _checkAppVersion(
    SuiteProduct product,
    _PubspecVersion declaration,
    ReleaseVersion expected,
  ) {
    final parsed = _parseAppVersion(declaration);
    if (parsed.version.semantic != expected.semantic) {
      throw ReleaseVersionStateException(
        '${product.name} app pubspec declares ${parsed.version.semantic}; '
        'expected ${expected.semantic}',
      );
    }
    if (parsed.buildCode != expected.androidVersionCode) {
      throw ReleaseVersionStateException(
        '${product.name} app pubspec version code is ${parsed.buildCode}; '
        'expected ${expected.androidVersionCode}',
      );
    }
  }

  void _checkReadme(SuiteProduct product, ReleaseVersion expected) {
    final readme = _resolveInsideRoot(product.readmePath);
    if (!readme.existsSync()) {
      throw ReleaseVersionStateException(
        '${product.name} README is missing: ${product.readmePath}',
      );
    }

    final matches = _readmeVersionPattern
        .allMatches(readme.readAsStringSync())
        .toList();
    if (matches.length != 1 || matches.single[1] != expected.semantic) {
      throw ReleaseVersionStateException(
        '${product.name} README version marker must equal '
        '${expected.semantic}',
      );
    }
  }

  void _checkRootReadme(ReleaseVersion expected) {
    final readme = _resolveInsideRoot(_rootReadmePath);
    if (!readme.existsSync()) return;

    // The root README is main's to write; once it carries the marker the
    // release engine keeps it in step — until then verify-if-present.
    final matches = _readmeVersionPattern
        .allMatches(readme.readAsStringSync())
        .toList();
    if (matches.isEmpty) return;
    if (matches.length == 1 && matches.single[1] == expected.semantic) return;

    throw ReleaseVersionStateException(
      'root README version marker must equal ${expected.semantic}',
    );
  }

  void _checkAppleVersions(SuiteProduct product, ReleaseVersion expected) {
    for (final path in product.literalBundlePlistPaths) {
      final file = _resolveInsideRoot(path);
      final contents = _readRequiredFile(file, 'Apple Info.plist $path');
      final actual = _appleBundleVersionMatch(contents, path)[2];
      if (actual == expected.appleBundleVersion) continue;

      throw ReleaseVersionStateException(
        'Apple bundle version in $path is "$actual"; expected '
        '"${expected.appleBundleVersion}"',
      );
    }
    for (final path in product.flutterVariablePlistPaths) {
      _requireFlutterVariablePlist(path);
    }
  }

  void _requireFlutterVariablePlist(String path) {
    final file = _resolveInsideRoot(path);
    final contents = _readRequiredFile(file, 'Apple Info.plist $path');
    final actual = _appleBundleVersionMatch(contents, path)[2];
    if (actual == _flutterBuildNumberVariable) return;

    throw ReleaseVersionStateException(
      'Apple bundle version in $path is "$actual"; expected '
      '"$_flutterBuildNumberVariable" so the pubspec +code reaches '
      'the bundle',
    );
  }

  /// Every committed lockfile (except the frozen bench lock) must pin any
  /// owned path-package name at the suite version.
  int _checkLocks(Set<String> ownedNames, ReleaseVersion expected) {
    var checked = 0;
    for (final file in _findLockfiles()) {
      final relativePath = p.relative(file.path, from: _root.path);
      if (_isUnmanagedPath(relativePath)) continue;

      final yaml = _readYamlMap(file, 'lock $relativePath');
      final packages = yaml['packages'];
      if (packages is! YamlMap) continue;

      for (final entry in packages.entries) {
        if (entry.key is! String || !ownedNames.contains(entry.key)) {
          continue;
        }
        final locked = entry.value;
        if (locked is! YamlMap) continue;
        // Any owned package name must pin the suite version regardless of
        // how it resolved — a stale pin is stale whether path- or
        // git-sourced.
        if (locked['version'] != expected.semantic) {
          throw ReleaseVersionStateException(
            '$relativePath pins ${entry.key} at ${locked['version']}; '
            'expected ${expected.semantic}',
          );
        }
        checked++;
      }
    }
    return checked;
  }

  Set<String> _ownedPackageNames(List<_PubspecVersion> declarations) {
    final names = <String>{};
    for (final declaration in declarations) {
      final name = _readPubspecName(declaration.file);
      if (name != null) names.add(name);
    }
    return names;
  }

  _PreparedRewrite _prepareAppPubspec(
    SuiteProduct product,
    ReleaseVersion version,
  ) {
    final file = _resolveInsideRoot(product.appPubspecPath);
    if (!file.existsSync()) {
      throw ReleaseVersionStateException(
        '${product.name} app pubspec does not exist: '
        '${product.appPubspecPath}',
      );
    }

    _readYamlMap(file, '${product.name} app pubspec');
    final original = file.readAsStringSync();
    final matches = _versionLinePattern.allMatches(original).toList();
    if (matches.length != 1) {
      throw ReleaseVersionStateException(
        '${product.name} app pubspec must contain exactly one top-level '
        'version',
      );
    }

    final rewritten = original.replaceRange(
      matches.single.start,
      matches.single.end,
      '${matches.single[1]}${version.appVersion}${matches.single[3]}',
    );

    return _PreparedRewrite(
      file: file,
      contents: rewritten,
      changed: rewritten != original,
      validate: (temporary) {
        final stored = _readPubspecVersion(
          temporary,
          requirement: _VersionRequirement.required,
        )!;
        if (stored == version.appVersion) return;

        throw ReleaseVersionStateException(
          'app pubspec version sync produced "$stored" instead of '
          '"${version.appVersion}"',
        );
      },
    );
  }

  _PreparedRewrite _prepareAppleInfoPlist(String path, ReleaseVersion version) {
    final file = _resolveInsideRoot(path);
    final original = _readRequiredFile(file, 'Apple Info.plist $path');
    final match = _appleBundleVersionMatch(original, path);
    final expected = version.appleBundleVersion;
    final rewritten = original.replaceRange(
      match.start,
      match.end,
      '${match[1]}$expected${match[3]}',
    );

    return _PreparedRewrite(
      file: file,
      contents: rewritten,
      changed: rewritten != original,
      validate: (temporary) {
        final stored = _appleBundleVersionMatch(
          temporary.readAsStringSync(),
          path,
        )[2];
        if (stored == expected) return;

        throw ReleaseVersionStateException(
          'Apple bundle version sync produced "$stored" instead of '
          '"$expected" in $path',
        );
      },
    );
  }

  _StagedRewrite _stageRewrite(_PreparedRewrite rewrite) {
    final temporary = File(
      p.join(rewrite.file.parent.path, _newTemporaryFileName()),
    );
    final temporaryType = FileSystemEntity.typeSync(
      temporary.path,
      followLinks: false,
    );
    if (temporaryType != FileSystemEntityType.notFound) {
      throw ReleaseVersionStateException(
        'stale release-version file exists: ${temporary.path}',
      );
    }

    var created = false;
    try {
      temporary.createSync(exclusive: true);
      created = true;
      temporary.writeAsStringSync(rewrite.contents, flush: true);
      rewrite.validate(temporary);
    } on Object {
      if (created) _deleteTemporaryBestEffort(temporary);

      rethrow;
    }

    return _StagedRewrite(target: rewrite.file, temporary: temporary);
  }

  List<File> _findPubspecs() {
    return _findFiles('pubspec.yaml');
  }

  List<File> _findLockfiles() {
    return _findFiles('pubspec.lock');
  }

  List<File> _findFiles(String name) {
    final files = <File>[];
    final pending = <Directory>[_root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is Directory) {
          if (_ignoredDirectories.contains(p.basename(entity.path))) {
            continue;
          }

          pending.add(entity);
          continue;
        }
        if (entity is File && p.basename(entity.path) == name) {
          files.add(entity);
        }
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  bool _isUnmanagedPath(String relativePath) {
    final segments = p.split(relativePath);
    if (segments.isEmpty) return true;

    // Root level: only the suite manifest and its lockfile are managed.
    if (segments.length == 1) {
      return relativePath != _rootPubspecPath && relativePath != 'pubspec.lock';
    }
    if (!_projectNames.contains(segments.first)) return true;
    return segments.any(_unmanagedDirectories.contains);
  }

  File _resolveInsideRoot(String pathFromRoot) {
    final candidate = p.isAbsolute(pathFromRoot)
        ? pathFromRoot
        : p.join(_root.path, pathFromRoot);
    final resolved = File(p.normalize(p.absolute(candidate)));

    final rootPath = _root.resolveSymbolicLinksSync();
    final resolvedPath = _canonicalPath(resolved);
    if (p.equals(resolvedPath, rootPath)) {
      throw ReleaseVersionStateException(
        'path must identify a file inside repository root: $pathFromRoot',
      );
    }
    if (p.isWithin(rootPath, resolvedPath)) {
      return resolved;
    }

    throw ReleaseVersionStateException(
      'path leaves repository root: $pathFromRoot',
    );
  }

  String _canonicalPath(File file) {
    if (file.existsSync()) return file.resolveSymbolicLinksSync();

    var ancestor = file.parent;
    while (!ancestor.existsSync()) {
      final parent = ancestor.parent;
      if (p.equals(ancestor.path, parent.path)) return file.path;

      ancestor = parent;
    }

    return p.join(
      ancestor.resolveSymbolicLinksSync(),
      p.relative(file.path, from: ancestor.path),
    );
  }
}

final class _PubspecVersion {
  final File file;
  final String relativePath;
  final String value;

  const _PubspecVersion({
    required this.file,
    required this.relativePath,
    required this.value,
  });
}

final class _AppVersion {
  final ReleaseVersion version;
  final int buildCode;

  const _AppVersion(this.version, this.buildCode);
}

final class _PreparedRewrite {
  final File file;
  final String contents;
  final bool changed;
  final void Function(File temporary) validate;

  const _PreparedRewrite({
    required this.file,
    required this.contents,
    required this.changed,
    required this.validate,
  });
}

final class _StagedRewrite {
  final File target;
  final File temporary;

  const _StagedRewrite({required this.target, required this.temporary});
}

String _newTemporaryFileName() {
  final token = StringBuffer();
  for (var index = 0; index < _temporaryTokenByteCount; index++) {
    token.write(
      _secureRandom
          .nextInt(_byteValueCount)
          .toRadixString(_hexRadix)
          .padLeft(_hexByteWidth, '0'),
    );
  }

  return '$_temporaryPrefix$token$_temporarySuffix';
}

void _deleteTemporaryBestEffort(File temporary) {
  try {
    final type = FileSystemEntity.typeSync(temporary.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) temporary.deleteSync();
  } on Object {
    // Preserve the write, validation, or rename failure that matters.
  }
}

_AppVersion _parseAppVersion(_PubspecVersion declaration) {
  final match = _appVersionPattern.firstMatch(declaration.value);
  if (match == null) {
    throw ReleaseVersionStateException(
      'app pubspec version "${declaration.value}" lacks a numeric build '
      'code',
    );
  }

  final version = _parsePubspecSemantic(match[1]!, 'app pubspec');
  final buildCode = int.tryParse(match[2]!);
  if (buildCode == null || '$buildCode' != match[2]) {
    throw ReleaseVersionStateException(
      'app pubspec version code "${match[2]}" is not canonical',
    );
  }

  return _AppVersion(version, buildCode);
}

ReleaseVersion _parsePubspecVersion(_PubspecVersion declaration) {
  return _parsePubspecSemantic(
    declaration.value,
    'pubspec ${declaration.relativePath}',
  );
}

ReleaseVersion _parsePubspecSemantic(String value, String source) {
  try {
    return ReleaseVersion.parse(value);
  } on ReleaseVersionFormatException catch (error) {
    throw ReleaseVersionStateException('$source is invalid: ${error.message}');
  }
}

enum _VersionRequirement { optional, required }

String? _readPubspecVersion(
  File file, {
  _VersionRequirement requirement = _VersionRequirement.optional,
}) {
  final yaml = _readYamlMap(file, 'pubspec ${file.path}');
  final value = yaml['version'];
  if (value == null && requirement == _VersionRequirement.optional) {
    return null;
  }
  if (value is String) return value;

  throw ReleaseVersionStateException(
    'pubspec ${file.path} has a missing or non-string version',
  );
}

String? _readPubspecName(File file) {
  final yaml = _readYamlMap(file, 'pubspec ${file.path}');
  final value = yaml['name'];
  return value is String ? value : null;
}

YamlMap _readYamlMap(File file, String label) {
  if (!file.existsSync()) {
    throw ReleaseVersionStateException('$label is missing: ${file.path}');
  }

  try {
    final yaml = loadYaml(file.readAsStringSync());
    if (yaml is YamlMap) return yaml;
  } on YamlException catch (error) {
    throw ReleaseVersionStateException('$label is malformed: $error');
  }

  throw ReleaseVersionStateException('$label must contain a YAML map');
}

String _readRequiredFile(File file, String label) {
  if (file.existsSync()) return file.readAsStringSync();

  throw ReleaseVersionStateException('$label is missing: ${file.path}');
}

RegExpMatch _appleBundleVersionMatch(String contents, String path) {
  final matches = _appleBundleVersionPattern.allMatches(contents).toList();
  if (matches.length == 1) return matches.single;

  throw ReleaseVersionStateException(
    'Apple Info.plist $path must contain exactly one CFBundleVersion '
    'string',
  );
}

ReleaseVersion _parseReleaseTag(String tag) {
  if (!tag.startsWith('v')) {
    throw ReleaseVersionFormatException(
      'invalid release tag "$tag"; expected vX.Y.Z',
    );
  }

  return ReleaseVersion.parse(tag.substring(1));
}

ReleaseVersion _parsePriorTag(String tag) {
  try {
    return _parseReleaseTag(tag);
  } on ReleaseVersionFormatException catch (error) {
    throw ReleaseVersionStateException(
      'cannot establish release order from prior tag "$tag": '
      '${error.message}',
    );
  }
}
