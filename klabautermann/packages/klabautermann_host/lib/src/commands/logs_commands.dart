part of 'commands.dart';

/// How a rotated log under `/var/log` is compressed (LOG-08, 03 §7.6),
/// from its name.
enum LogCompression {
  none,
  gzip,
  xz;

  /// The compression [path]'s suffix names.
  static LogCompression of(String path) {
    if (path.endsWith('.gz')) return gzip;
    if (path.endsWith('.xz')) return xz;
    return none;
  }
}

/// The marker [HostCommands.rotatedTail] writes to stderr when the
/// decompressor fails, followed by its exit status (127: not installed).
const String kDecompressFailedMarker = 'klabautermann-decompress-failed';

/// Reads the tail of a compressed log: the decompressor's failure is
/// reported on stderr, since the pipeline's status is `tail`'s.
const String _kRotatedTailScript =
    '{ "\$1" -- "\$2" || echo "$kDecompressFailedMarker \$?" >&2; } '
    '| tail -n "\$3"';

/// Lists the regular files under `/var/log`, two levels deep (LOG-08,
/// 03 §7.6): `<readable> <bytes> <mtime> <path>` per file, where
/// readable is 1 or 0. `stat -c` and `find -maxdepth` work under GNU
/// and BusyBox alike, unlike `find -printf`. A name holding a newline
/// is not listed.
const String _kLogFilesScript = r'''
find /var/log -maxdepth 2 -type f 2>/dev/null | while IFS= read -r f; do
  if [ -r "$f" ]; then r=1; else r=0; fi
  s=$(stat -c '%s %Y' -- "$f" 2>/dev/null) || continue
  printf '%s %s %s
' "$r" "$s" "$f"
done''';
