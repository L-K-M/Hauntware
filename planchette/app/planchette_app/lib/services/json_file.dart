import 'dart:convert';
import 'dart:io';

import 'package:seance_core/catalog.dart' show AtomicFileWriter;

/// Writes [json] to [file] as two-space JSON with a trailing newline through
/// the shared [AtomicFileWriter], so a crash mid-write leaves the previous file
/// rather than a truncated one. A link at [file] stays a link: the writer
/// lands the content where it points.
Future<void> writeJsonFileAtomically(File file, Object? json) {
  final encoded = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  return const AtomicFileWriter().write(file, encoded);
}
