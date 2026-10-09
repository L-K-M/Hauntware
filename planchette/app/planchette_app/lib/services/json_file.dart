import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as paths;

/// Writes [json] to [file] as two-space JSON with a trailing newline. The
/// text goes to a sibling `.tmp` first and is renamed over the file, so a
/// crash mid-write leaves the previous file rather than a truncated one
/// that would read as none at all. A link at [file] stays a link: the write
/// lands where it points, so a file kept elsewhere, such as in a dotfiles
/// folder, keeps receiving changes instead of being replaced by a copy.
Future<void> writeJsonFileAtomically(File file, Object? json) async {
  final target = await _destination(file);
  await target.parent.create(recursive: true);
  final staging = File('${target.path}.tmp');
  await staging.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    flush: true,
  );
  await staging.rename(target.path);
}

/// The file a write replaces: [file] itself, or where a link at it points.
Future<File> _destination(File file) async {
  if (!await FileSystemEntity.isLink(file.path)) return file;
  try {
    return File(await file.resolveSymbolicLinks());
  } on FileSystemException {
    // A link to a file that does not exist yet: write where it points.
    final target = await Link(file.path).target();
    return File(
      paths.isAbsolute(target) ? target : paths.join(file.parent.path, target),
    );
  }
}
