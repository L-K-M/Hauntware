import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../browse/unicode_simple_fold.dart';
import '../fs/file_system_name_traits.dart';

/// How a destination filesystem compares names.
enum DestinationNameComparison {
  /// Byte-distinct names remain distinct.
  exact,

  /// Upcase-table variants refer to one entry; canonical variants do not.
  caseInsensitive,

  /// Canonically equivalent Unicode names refer to one entry.
  normalized,

  /// Canonically equivalent upcase-table variants refer to one entry.
  normalizedCaseInsensitive,
}

/// The refusal shown when two sources in one task target one entry.
const withinTaskDestinationCollisionMessage =
    'two source items map to the same destination name on this volume';

/// Builds the identity key used by scan and execution collision guards.
String destinationNameKey(String value, DestinationNameComparison comparison) =>
    switch (comparison) {
      DestinationNameComparison.exact => value,
      DestinationNameComparison.caseInsensitive => simpleCaseFold(value),
      DestinationNameComparison.normalized => unorm.nfc(value),
      DestinationNameComparison.normalizedCaseInsensitive => unorm.nfc(
        simpleCaseFold(unorm.nfc(value)),
      ),
    };

/// Builds the broad alias key used because the exact fold table is not probed.
String conservativeDestinationNameKey(String value) =>
    unorm.nfc(fullCaseFold(removeDefaultIgnorableCodePoints(unorm.nfd(value))));

/// Selects the identity operation matching both filesystem name axes.
DestinationNameComparison destinationNameComparisonFor(
  FileSystemNameTraits traits,
) => switch ((traits.caseSensitivity, traits.normalizationSensitivity)) {
  (FileSystemNameSensitivity.sensitive, FileSystemNameSensitivity.sensitive) =>
    DestinationNameComparison.exact,
  (
    FileSystemNameSensitivity.insensitive,
    FileSystemNameSensitivity.sensitive,
  ) =>
    DestinationNameComparison.caseInsensitive,
  (
    FileSystemNameSensitivity.sensitive,
    FileSystemNameSensitivity.insensitive,
  ) =>
    DestinationNameComparison.normalized,
  (
    FileSystemNameSensitivity.insensitive,
    FileSystemNameSensitivity.insensitive,
  ) =>
    DestinationNameComparison.normalizedCaseInsensitive,
};
