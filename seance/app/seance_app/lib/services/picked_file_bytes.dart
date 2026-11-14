import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A selected file exceeds the caller's read budget, including when its size
/// metadata was missing or stale.
class PickedFileTooLargeException implements Exception {
  const PickedFileTooLargeException();
}

/// Reads a picked file, bounded by [maxBytes]. The picker's reported length
/// is only a hint: the byte stream is bounded too, so a stale or missing size
/// cannot load a huge file, and an oversized one stops at the first chunk past
/// the limit. Android document-provider picks stream from the picker's cached
/// copy rather than needing a filesystem path.
/// Any failure to read throws [FileSystemException].
Future<Uint8List> readPickedFileBytes(
  PlatformFile file, {
  required int maxBytes,
}) async {
  final reported = file.lengthSync();
  if (reported != null && reported > maxBytes) {
    throw const PickedFileTooLargeException();
  }

  final contents = BytesBuilder(copy: false);
  try {
    await for (final chunk in file.readAsByteStream()) {
      if (chunk.length > maxBytes - contents.length) {
        throw const PickedFileTooLargeException();
      }
      contents.add(chunk);
    }
  } on PickedFileTooLargeException {
    rethrow;
  } on FileSystemException {
    rethrow;
  } on Object {
    // A platform's own read error (an iOS photo-library reference, a
    // provider that went away) reaches callers as the one documented type.
    throw const FileSystemException('The picker provided no readable data');
  }
  return contents.takeBytes();
}
