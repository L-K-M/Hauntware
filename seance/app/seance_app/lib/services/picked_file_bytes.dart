import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A selected file exceeds the caller's read budget, including when its size
/// metadata was missing or stale.
class PickedFileTooLargeException implements Exception {
  const PickedFileTooLargeException();
}

/// Reads a file picked without eager data loading, bounded by [maxBytes].
/// Provider-only files use their stream; macOS supplies a filesystem path.
/// A missing source or failed filesystem read throws [FileSystemException].
Future<Uint8List> readPickedFileBytes(
  PlatformFile file, {
  required int maxBytes,
}) async {
  if (file.size > maxBytes) throw const PickedFileTooLargeException();

  final bytes = file.bytes;
  if (bytes != null) {
    if (bytes.length > maxBytes) throw const PickedFileTooLargeException();
    return bytes;
  }

  var source = file.readStream;
  if (source == null) {
    final path = file.path;
    if (path == null) {
      throw const FileSystemException('The picker provided no readable data');
    }
    // One extra byte detects overflow without reading the entire file.
    source = File(path).openRead(0, maxBytes + 1);
  }

  final contents = BytesBuilder(copy: false);
  await for (final chunk in source) {
    if (chunk.length > maxBytes - contents.length) {
      throw const PickedFileTooLargeException();
    }
    contents.add(chunk);
  }
  return contents.takeBytes();
}
