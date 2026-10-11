import 'package:flutter/foundation.dart';

import 'pane_location.dart' show paneSeparator;

/// Why a typed inline-rename name was rejected (02 §2.6).
///
/// The three shapes the field checks before the engine call:
/// [empty] covers a blank or whitespace-only input, [separator] covers a
/// name containing the listing's path separator `/`, and [invalid]
/// covers characters the pane's filesystem family forbids — a local pane
/// on Windows rejects the NTFS set (`<>:"\|?*` and control characters),
/// the DOS device names, and a trailing dot or space, rather than
/// letting the engine fail the request — while a remote pane stays
/// POSIX-permissive because an SFTP server may accept names the client's
/// OS would not.
enum RenameNameError { empty, separator, invalid }

/// Validates one typed inline-rename name.
///
/// Returns null for an acceptable name. [remote] keeps remote panes on
/// the POSIX rule set (only empty and `/` are rejected); [platform]
/// decides which local rules apply — Windows adds the NTFS forbidden
/// set, the DOS device names, and a trailing dot or space. Callers pass
/// the typed string untrimmed: leading/trailing spaces are legal POSIX
/// names (Windows alone rejects a trailing one), so only an
/// all-whitespace input counts as [RenameNameError.empty].
RenameNameError? renameNameError(
  String name, {
  required bool remote,
  required TargetPlatform platform,
}) {
  if (name.trim().isEmpty) return RenameNameError.empty;
  if (name.contains('/')) return RenameNameError.separator;
  if (!remote && platform == TargetPlatform.windows) {
    if (name.contains(_windowsForbidden) ||
        name.codeUnits.any(_isControl) ||
        _windowsReserved.hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' ')) {
      return RenameNameError.invalid;
    }
  }
  return null;
}

final _windowsForbidden = RegExp(r'[<>:"\\|?*]');

/// The DOS device names Win32 reserves with or without an extension —
/// `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`. Suffix
/// digits past 9 (`COM10`) and longer stems (`console`) are ordinary
/// names.
final _windowsReserved = RegExp(
  r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
  caseSensitive: false,
);

bool _isControl(int unit) => unit < 0x20 || unit == 0x7F;

/// The directory part of an entry's [path], separator included, so the
/// renamed path is this plus the new name (02 §2.6). [fallbackDirectory]
/// is joined only when the path itself names no parent.
///
/// The parent prefix keeps the entry path's own separators — never a
/// synthesized join — so the re-anchored path matches the refreshed
/// listing's normalization. The grammar comes from the path itself:
/// a remote or POSIX local path separates on '/' only, so a '\' in
/// a name is a filename byte, never a separator. The exact basename
/// is removed BEFORE any separator trimming — a POSIX name may end
/// in '\' and trimming it first would leave a path that no longer
/// ends with its name — and the prefix counts only when the cut
/// lands on a separator boundary. The last-separator split is the
/// fallback for a path that does not end with its name, the
/// directory join the last resort.
String renameParentPrefix({
  required String path,
  required String name,
  required String? fallbackDirectory,
}) {
  final separator = paneSeparator(path);
  var parent = '';
  if (path.endsWith(name)) {
    final prefix = path.substring(0, path.length - name.length);
    if (prefix.isEmpty || prefix.endsWith(separator)) {
      parent = prefix;
    }
  }
  if (parent.isEmpty && path != name) {
    var trimmed = path;
    while (trimmed.length > 1 && trimmed.endsWith(separator)) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.endsWith(name)) {
      final prefix = trimmed.substring(0, trimmed.length - name.length);
      if (prefix.endsWith(separator)) parent = prefix;
    }
    if (parent.isEmpty) {
      final lastSep = trimmed.lastIndexOf(separator);
      if (lastSep >= 0) parent = trimmed.substring(0, lastSep + 1);
    }
  }
  if (parent.isEmpty) {
    // The last resort still respects the base's own terminator — a
    // root location ('/', 'C:\', a UNC root) already ends with its
    // separator, and doubling it would synthesize a spelling the
    // refreshed listing never matches.
    final base = fallbackDirectory ?? '';
    final baseSeparator = paneSeparator(base);
    parent = base.endsWith(baseSeparator) ? base : '$base$baseSeparator';
  }
  return parent;
}
