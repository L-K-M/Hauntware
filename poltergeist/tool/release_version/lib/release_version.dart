// Release-version arithmetic that the suite tool at the repository root
// (tool/release_version) re-exports. That tool owns the tree checks, the
// metadata rewrites and the CLI; see README.md.

const int _componentLimit = 99;
const int _finalOrdinal = 99;
const int _majorMultiplier = 1_000_000;
const int _minorMultiplier = 10_000;
const int _patchMultiplier = 100;
const int _androidVersionCodeLimit = 2_100_000_000;
const int _majorComponentLimit =
    (_androidVersionCodeLimit - _finalOrdinal) ~/ _majorMultiplier;

final RegExp _versionPattern = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
);

/// A release version whose Android build code preserves semantic ordering.
final class ReleaseVersion {
  final int _major;
  final int _minor;
  final int _patch;

  const ReleaseVersion._({
    required this._major,
    required this._minor,
    required this._patch,
  });

  factory ReleaseVersion.parse(String source) {
    final match = _versionPattern.firstMatch(source);
    if (match == null) {
      throw ReleaseVersionFormatException(
        'invalid release version "$source"; expected X.Y.Z',
      );
    }

    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[2]!);
    final patch = int.tryParse(match[3]!);
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
    if (major > _majorComponentLimit) {
      throw ReleaseVersionFormatException(
        'release version "$source" exceeds Android versionCode '
        '$_androidVersionCodeLimit',
      );
    }

    final version = ReleaseVersion._(major: major, minor: minor, patch: patch);
    // Keep the platform ceiling explicit if component constants drift.
    if (version.androidVersionCode > _androidVersionCodeLimit) {
      throw ReleaseVersionFormatException(
        'release version "$source" exceeds Android versionCode '
        '$_androidVersionCodeLimit',
      );
    }

    return version;
  }

  String get semantic => '$_major.$_minor.$_patch';

  int get androidVersionCode {
    return _major * _majorMultiplier +
        _minor * _minorMultiplier +
        _patch * _patchMultiplier +
        _finalOrdinal;
  }

  String get appVersion => '$semantic+$androidVersionCode';

  // Offset zero-major releases because Apple's first component is positive.
  // Public so the Hauntware suite tool can apply the same formula at
  // monorepo scope instead of inventing a second mapping.
  String get appleBundleVersion => '${_major + 1}.$_minor.$_patch';
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
