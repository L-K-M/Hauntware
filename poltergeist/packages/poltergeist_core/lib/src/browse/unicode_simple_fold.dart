part 'unicode_simple_fold_data.dart';

const _asciiUpperA = 0x41;
const _asciiUpperZ = 0x5a;
const _asciiLowerOffset = 0x20;
const _asciiMaximum = 0x7f;

/// Unicode 17.0.0 simple folding, independent of platform and Dart's tables.
///
/// Uses CaseFolding.txt statuses C and S only. It neither normalizes text nor
/// expands letters (ß stays ß); Turkic tailoring is excluded (İ stays İ).
String simpleCaseFold(String value) {
  final result = StringBuffer();
  for (final point in value.runes) {
    result.writeCharCode(_foldCodePoint(point));
  }
  return result.toString();
}

/// Unicode 17.0.0 full folding without locale-specific tailoring.
///
/// Destination identity uses expansions such as ß → ss because Linux
/// casefold filesystems treat those spellings as the same name.
String fullCaseFold(String value) {
  final result = StringBuffer();
  for (final point in value.runes) {
    final expansion = _fullFoldExpansions[point];
    if (expansion == null) {
      result.writeCharCode(_foldCodePoint(point));
      continue;
    }

    for (final target in expansion) {
      result.writeCharCode(target);
    }
  }
  return result.toString();
}

/// Removes Unicode 17.0.0 default-ignorable code points.
///
/// Linux casefold directories remove these before comparing names.
String removeDefaultIgnorableCodePoints(String value) {
  final result = StringBuffer();
  for (final point in value.runes) {
    if (_isDefaultIgnorable(point)) continue;

    result.writeCharCode(point);
  }
  return result.toString();
}

bool _isDefaultIgnorable(int point) {
  var lower = 0;
  var upper = _defaultIgnorableRanges.length - 1;
  while (lower <= upper) {
    final middle = (lower + upper) ~/ 2;
    final range = _defaultIgnorableRanges[middle];
    if (point < range.start) {
      upper = middle - 1;
      continue;
    }
    if (point > range.end) {
      lower = middle + 1;
      continue;
    }

    return true;
  }
  return false;
}

int _foldCodePoint(int point) {
  // Most filenames need only the fixed ASCII mapping.
  if (point <= _asciiMaximum) {
    return point >= _asciiUpperA && point <= _asciiUpperZ
        ? point + _asciiLowerOffset
        : point;
  }

  var lower = 0;
  var upper = _foldRanges.length - 1;
  while (lower <= upper) {
    final middle = (lower + upper) ~/ 2;
    final range = _foldRanges[middle];
    if (point < range.start) {
      upper = middle - 1;
      continue;
    }
    if (point > range.end) {
      lower = middle + 1;
      continue;
    }

    // Alternating uppercase/lowercase runs leave the intervening letters alone.
    return (point - range.start) % range.stride == 0
        ? point + range.delta
        : point;
  }
  return point;
}
