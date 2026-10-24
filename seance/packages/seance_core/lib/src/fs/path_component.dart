/// The lexical rule for one path component, shared by Poltergeist's local
/// file safety and the suite's link parsers (docs/design/suite-links.md
/// section 4). Moved from poltergeist_core's `local_fs_safety.dart`.
library;

// NAME_MAX 255 is the floor across the supported platform matrix;
// overshooting it fails the replace rather than truncating into a
// collision (03 §2.3).
const int maxFileNameBytes = 255;

/// The lexical half of the local path safety rules (03 §2.3, 09 §3.5).
///
/// No empty component, no `.`/`..`, no separators. `\` is rejected
/// everywhere on purpose: it is legal POSIX filename data, but a
/// component carrying one is overwhelmingly an escaping bug, and it is
/// the path separator on a Windows destination — a server-reported name
/// like `..\..\x` that passes a `/`-only check becomes traversal the
/// moment a Windows build joins it into a local path.
void validatePathComponent(String component) {
  if (component.isEmpty ||
      component == '.' ||
      component == '..' ||
      component.contains('/') ||
      component.contains(r'\') ||
      component.contains('\x00')) {
    throw FormatException('"$component" is not a safe path component.');
  }
  // 09 §3.5's boundary rule: an over-long component fails here with a
  // clean FormatException instead of mid-transfer as an opaque
  // ENAMETOOLONG — enforced at the component level so every caller of
  // this half inherits it. POSIX NAME_MAX counts UTF-8 bytes.
  if (utf8ByteLength(component) > maxFileNameBytes) {
    throw FormatException(
      '"$component" exceeds the $maxFileNameBytes-byte file-name limit.',
    );
  }
}

/// UTF-8 byte count without transcoding: 1 per ASCII unit, 2/3 per BMP
/// unit, 4 across a surrogate pair. A lone surrogate counts 3 — the
/// encoder substitutes U+FFFD, itself a 3-byte sequence — so the
/// NAME_MAX guard never under-counts.
int utf8ByteLength(String value) {
  var total = 0;
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit < 0x80) {
      total += 1;
    } else if (unit < 0x800) {
      total += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < units.length &&
        units[i + 1] >= 0xDC00 &&
        units[i + 1] <= 0xDFFF) {
      total += 4;
      i++;
    } else {
      total += 3;
    }
  }
  return total;
}
