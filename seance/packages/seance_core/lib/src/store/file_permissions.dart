import 'dart:io';

import 'package:posix/posix.dart' as posix;

const _ownerReadWriteMode = 0x180; // POSIX 0600: owner read + write only.
const _ownerOnlyDirectoryMode = 0x1c0; // POSIX 0700: owner only.

/// Applies owner-only mode bits to files that carry path-bearing or
/// otherwise private data (the identity audit log names private-key
/// paths). Windows and mobile rely on their per-user/application
/// storage ACLs instead.
void restrictFileToOwner(File file) {
  if (!Platform.isLinux && !Platform.isMacOS) return;

  posix.chmodWithMode(file.path, _ownerReadWriteMode);
}

/// Owner-only access to a directory of private files, so nothing below it
/// is reachable by other users whatever its own mode.
void restrictDirectoryToOwner(Directory directory) {
  if (!Platform.isLinux && !Platform.isMacOS) return;

  posix.chmodWithMode(directory.path, _ownerOnlyDirectoryMode);
}

/// Owner-only mode bits on [path] — `'600'` for files, `'700'` for
/// directories — on Linux and macOS; other platforms keep their
/// per-user storage ACLs (09 §3.5/06 §3.1's posture). A failed or
/// unavailable chmod aborts the caller's operation: private content
/// either lands owner-only or not at all — the incident store's rule,
/// shared so the managed-checkout index, its temps, its quarantines,
/// and the checkout dirs/files cannot drift into a laxer posture.
Future<void> restrictLocalPathPermissions(String path, String mode) async {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  // Resolve chmod by absolute path where it exists — a PATH-hijacked
  // shim exiting 0 would silently defeat the owner-only invariant.
  var chmod = 'chmod';
  for (final candidate in const ['/usr/bin/chmod', '/bin/chmod']) {
    if (await File(candidate).exists()) {
      chmod = candidate;
      break;
    }
  }
  ProcessResult result;
  try {
    result = await Process.run(chmod, ['--', mode, path]);
  } on ProcessException catch (error) {
    throw FileSystemException(
      'chmod is unavailable; cannot restrict $path to the owner '
      '(${error.message})',
      path,
    );
  }
  if (result.exitCode != 0) {
    final detail = (result.stderr as String).trim();
    throw FileSystemException(
      'Could not restrict $path to the owner (chmod exited '
      '${result.exitCode}${detail.isEmpty ? '' : ': $detail'})',
      path,
    );
  }
}
