import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const int _componentLimit = 99;
const int _qualifierLimit = 49;
const int _releaseCandidateOffset = 49;
const int _finalOrdinal = 99;
const int _majorMultiplier = 1_000_000;
const int _minorMultiplier = 10_000;
const int _patchMultiplier = 100;
const int _androidVersionCodeLimit = 2_100_000_000;
const int _debianRevision = 1;
const String _appPubspecPath = 'app/poltergeist_app/pubspec.yaml';
const String _appLockPath = 'app/poltergeist_app/pubspec.lock';
const String _readmePath = 'README.md';

final RegExp _versionPattern = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
  r'(?:-(beta|rc)([1-9][0-9]*))?$',
);
final RegExp _appVersionPattern = RegExp(r'^(.+)\+([0-9]+)$');
final RegExp _versionLinePattern = RegExp(
  r'^version:[ \t]*[^\r\n]*$',
  multiLine: true,
);
final RegExp _readmeVersionPattern = RegExp(
  r'<!-- version -->([^<]+)<!-- /version -->',
);
const Set<String> _ignoredDirectories = {
  '.dart_tool',
  '.git',
  '.plugin_symlinks',
  '.symlinks',
  'build',
  'ephemeral',
  'Pods',
};

enum _ReleaseStage { beta, releaseCandidate, finalRelease }

/// A release version whose Android build code preserves semantic ordering.
final class ReleaseVersion {
  final int _major;
  final int _minor;
  final int _patch;
  final _ReleaseStage _stage;
  final int? _qualifier;

  const ReleaseVersion._({
    required this._major,
    required this._minor,
    required this._patch,
    required this._stage,
    required this._qualifier,
  });

  factory ReleaseVersion.parse(String source) {
    final match = _versionPattern.firstMatch(source);
    if (match == null) {
      throw ReleaseVersionFormatException(
        'invalid release version "$source"; expected X.Y.Z, '
        'X.Y.Z-beta1..49, or X.Y.Z-rc1..49',
      );
    }

    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[2]!);
    final patch = int.tryParse(match[3]!);
    final qualifier = int.tryParse(match[5] ?? '');
    if (major == null || minor == null || patch == null) {
      throw ReleaseVersionFormatException(
        'release version "$source" contains an integer outside the '
        'supported range',
      );
    }
    if (minor > _componentLimit || patch > _componentLimit) {
      throw ReleaseVersionFormatException(
        'release version "$source" requires minor and patch values '
        'between 0 and $_componentLimit',
      );
    }

    final stage = switch (match[4]) {
      'beta' => _ReleaseStage.beta,
      'rc' => _ReleaseStage.releaseCandidate,
      _ => _ReleaseStage.finalRelease,
    };
    if (stage != _ReleaseStage.finalRelease &&
        (qualifier == null || qualifier > _qualifierLimit)) {
      throw ReleaseVersionFormatException(
        'release version "$source" requires a qualifier between 1 and '
        '$_qualifierLimit',
      );
    }

    final version = ReleaseVersion._(
      major: major,
      minor: minor,
      patch: patch,
      stage: stage,
      qualifier: qualifier,
    );
    if (version.androidVersionCode > _androidVersionCodeLimit) {
      throw ReleaseVersionFormatException(
        'release version "$source" exceeds Android versionCode '
        '$_androidVersionCodeLimit',
      );
    }

    return version;
  }

  String get semantic {
    final base = '$_major.$_minor.$_patch';
    return switch (_stage) {
      _ReleaseStage.beta => '$base-beta$_qualifier',
      _ReleaseStage.releaseCandidate => '$base-rc$_qualifier',
      _ReleaseStage.finalRelease => base,
    };
  }

  int get androidVersionCode {
    return _major * _majorMultiplier +
        _minor * _minorMultiplier +
        _patch * _patchMultiplier +
        _stageOrdinal;
  }

  String get appVersion => '$semantic+$androidVersionCode';

  /// Debian's tilde sorts prereleases before the otherwise equal final.
  String get debianPackageVersion {
    final base = '$_major.$_minor.$_patch';
    final upstream = switch (_stage) {
      _ReleaseStage.beta => '$base~beta$_qualifier',
      _ReleaseStage.releaseCandidate => '$base~rc$_qualifier',
      _ReleaseStage.finalRelease => base,
    };

    return '$upstream-$_debianRevision';
  }

  int get _stageOrdinal {
    return switch (_stage) {
      _ReleaseStage.beta => _qualifier!,
      _ReleaseStage.releaseCandidate => _releaseCandidateOffset + _qualifier!,
      _ReleaseStage.finalRelease => _finalOrdinal,
    };
  }
}

final class ReleaseVersionFormatException implements Exception {
  final String message;

  const ReleaseVersionFormatException(this.message);

  @override
  String toString() => message;
}

final class ReleaseVersionStateException implements Exception {
  final String message;

  const ReleaseVersionStateException(this.message);

  @override
  String toString() => message;
}

final class ReleaseVersionReport {
  final ReleaseVersion version;
  final int pubspecCount;
  final int lockedPackageCount;

  const ReleaseVersionReport({
    required this.version,
    required this.pubspecCount,
    required this.lockedPackageCount,
  });
}

/// Synchronizes and verifies the repository's release-version declarations.
final class ReleaseVersionWorkspace {
  final Directory _root;

  ReleaseVersionWorkspace(Directory root)
    : _root = Directory(p.normalize(p.absolute(root.path))) {
    if (!_root.existsSync()) {
      throw ReleaseVersionStateException(
        'repository root does not exist: ${_root.path}',
      );
    }
  }

  void syncAppPubspec({
    required ReleaseVersion version,
    required String pubspecPath,
  }) {
    final file = _resolveInsideRoot(pubspecPath);
    if (!file.existsSync()) {
      throw ReleaseVersionStateException(
        'app pubspec does not exist: $pubspecPath',
      );
    }

    _readYamlMap(file, 'app pubspec');
    final original = file.readAsStringSync();
    final matches = _versionLinePattern.allMatches(original).toList();
    if (matches.length != 1) {
      throw ReleaseVersionStateException(
        'app pubspec must contain exactly one top-level version',
      );
    }

    final rewritten = original.replaceRange(
      matches.single.start,
      matches.single.end,
      'version: ${version.appVersion}',
    );
    if (rewritten == original) return;

    try {
      file.writeAsStringSync(rewritten, flush: true);
      final stored = _readPubspecVersion(
        file,
        requirement: _VersionRequirement.required,
      )!;
      if (stored != version.appVersion) {
        throw ReleaseVersionStateException(
          'app pubspec version sync produced "$stored" instead of '
          '"${version.appVersion}"',
        );
      }
    } catch (_) {
      file.writeAsStringSync(original, flush: true);
      rethrow;
    }
  }

  ReleaseVersionReport check({ReleaseVersion? expected}) {
    final pubspecs = _findPubspecs();
    final app = _resolveInsideRoot(_appPubspecPath);
    if (!app.existsSync()) {
      throw const ReleaseVersionStateException(
        'app pubspec is missing: $_appPubspecPath',
      );
    }

    final declarations = <_PubspecVersion>[];
    for (final file in pubspecs) {
      final value = _readPubspecVersion(file);
      if (value == null) continue;

      declarations.add(
        _PubspecVersion(
          file: file,
          relativePath: p.relative(file.path, from: _root.path),
          value: value,
        ),
      );
    }

    final appDeclaration = declarations
        .where((declaration) => p.equals(declaration.file.path, app.path))
        .singleOrNull;
    if (appDeclaration == null) {
      throw const ReleaseVersionStateException(
        'app pubspec has no top-level version',
      );
    }

    final parsedApp = _parseAppVersion(appDeclaration);
    final ordinary = declarations
        .where((declaration) => !p.equals(declaration.file.path, app.path))
        .toList();
    final inferred = ordinary.isEmpty
        ? parsedApp.version
        : _parsePubspecVersion(ordinary.first);
    final version = expected ?? inferred;

    for (final declaration in ordinary) {
      final actual = _parsePubspecVersion(declaration);
      if (actual.semantic == version.semantic) continue;

      throw ReleaseVersionStateException(
        'pubspec ${declaration.relativePath} declares ${actual.semantic}; '
        'expected ${version.semantic}',
      );
    }
    if (parsedApp.version.semantic != version.semantic) {
      throw ReleaseVersionStateException(
        'app pubspec declares ${parsedApp.version.semantic}; expected '
        '${version.semantic}',
      );
    }
    if (parsedApp.buildCode != version.androidVersionCode) {
      throw ReleaseVersionStateException(
        'app pubspec version code is ${parsedApp.buildCode}; expected '
        '${version.androidVersionCode}',
      );
    }

    final lockedPackageCount = _checkAppLock(app, declarations, version);
    _checkReadme(version);

    return ReleaseVersionReport(
      version: version,
      pubspecCount: declarations.length,
      lockedPackageCount: lockedPackageCount,
    );
  }

  /// Rejects any release that would lower Android's upgrade ordering.
  ReleaseVersionReport checkTransition(ReleaseVersion target) {
    final current = check();
    if (target.semantic == current.version.semantic) return current;
    if (target.androidVersionCode > current.version.androidVersionCode) {
      return current;
    }

    throw ReleaseVersionStateException(
      'release ${target.semantic} is older than ${current.version.semantic} '
      'in Android version-code order',
    );
  }

  ReleaseVersionReport checkTag(String tag) {
    if (!tag.startsWith('v')) {
      throw ReleaseVersionFormatException(
        'invalid release tag "$tag"; expected vX.Y.Z, vX.Y.Z-betaN, '
        'or vX.Y.Z-rcN',
      );
    }

    final version = ReleaseVersion.parse(tag.substring(1));
    return check(expected: version);
  }

  List<File> _findPubspecs() {
    final files = <File>[];
    final pending = <Directory>[_root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is Directory) {
          if (_ignoredDirectories.contains(p.basename(entity.path))) continue;

          pending.add(entity);
          continue;
        }
        if (entity is File && p.basename(entity.path) == 'pubspec.yaml') {
          files.add(entity);
        }
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  File _resolveInsideRoot(String pathFromRoot) {
    final candidate = p.isAbsolute(pathFromRoot)
        ? pathFromRoot
        : p.join(_root.path, pathFromRoot);
    final resolved = File(p.normalize(p.absolute(candidate)));
    if (p.equals(resolved.path, _root.path) ||
        p.isWithin(_root.path, resolved.path)) {
      return resolved;
    }

    throw ReleaseVersionStateException(
      'path leaves repository root: $pathFromRoot',
    );
  }

  int _checkAppLock(
    File appPubspec,
    List<_PubspecVersion> declarations,
    ReleaseVersion expected,
  ) {
    final dependencies = _pathDependencyNames(appPubspec);
    final lock = _resolveInsideRoot(_appLockPath);
    final lockYaml = _readYamlMap(lock, 'app lock');
    final packages = lockYaml['packages'];
    if (packages is! YamlMap) {
      throw const ReleaseVersionStateException('app lock has no packages map');
    }

    var checked = 0;
    for (final dependency in dependencies) {
      final matchingPubspec = declarations
          .where(
            (declaration) => _readPubspecName(declaration.file) == dependency,
          )
          .toList();
      if (matchingPubspec.length != 1) {
        throw ReleaseVersionStateException(
          'app path dependency $dependency must resolve to exactly one '
          'versioned pubspec',
        );
      }

      final locked = packages[dependency];
      if (locked is! YamlMap ||
          locked['source'] != 'path' ||
          locked['version'] != expected.semantic) {
        throw ReleaseVersionStateException(
          'app lock does not pin path dependency $dependency at '
          '${expected.semantic}',
        );
      }
      checked++;
    }
    return checked;
  }

  Set<String> _pathDependencyNames(File appPubspec) {
    final yaml = _readYamlMap(appPubspec, 'app pubspec');
    final dependencies = yaml['dependencies'];
    if (dependencies is! YamlMap) return const {};

    return {
      for (final entry in dependencies.entries)
        if (entry.key is String &&
            entry.value is YamlMap &&
            (entry.value as YamlMap).containsKey('path'))
          entry.key as String,
    };
  }

  void _checkReadme(ReleaseVersion expected) {
    final readme = _resolveInsideRoot(_readmePath);
    if (!readme.existsSync()) {
      throw const ReleaseVersionStateException('README.md is missing');
    }

    final matches = _readmeVersionPattern
        .allMatches(readme.readAsStringSync())
        .toList();
    if (matches.length != 1 || matches.single[1] != expected.semantic) {
      throw ReleaseVersionStateException(
        'README version marker must contain ${expected.semantic}',
      );
    }
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

_AppVersion _parseAppVersion(_PubspecVersion declaration) {
  final match = _appVersionPattern.firstMatch(declaration.value);
  if (match == null) {
    throw ReleaseVersionStateException(
      'app pubspec version "${declaration.value}" lacks a numeric build code',
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
  if (value == null && requirement == _VersionRequirement.optional) return null;
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
