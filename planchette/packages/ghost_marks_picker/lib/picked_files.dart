/// Séance's and Poltergeist's file glue over file_picker 13 and
/// file_selector: bounded reads of a picked file, and the save-as panel for
/// a file the app writes itself. Android's document provider (SAF) stays in
/// each app, behind its own method channel.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' show getSaveLocation;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

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

/// Asks where to save [fileName] and saves it there. The saved location, or
/// null when the user cancelled.
///
/// On the desktops only the destination comes from the panel (file_selector)
/// and [writeTo] writes it, so the app keeps its own atomic, owner-only or
/// streamed write: file_picker's own save needs the whole file in memory and
/// writes it before returning. iOS has no such panel (file_selector_ios
/// implements none), so there file_picker's document picker exports
/// [readBytes] itself and [writeTo] is not called.
///
/// Android saves through the app's document provider instead, and the web
/// has no save panel: both throw [UnsupportedError].
Future<String?> saveAs({
  required String fileName,
  required Future<void> Function(String path) writeTo,
  required Future<Uint8List> Function() readBytes,
  String mimeType = 'application/octet-stream',
}) async {
  if (kIsWeb) throw UnsupportedError('The web has no save panel');
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      final saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: await readBytes(),
        mimeType: mimeType,
      );
      if (saved == null) return null;
      return saved.isScheme('file') ? saved.toFilePath() : saved.toString();
    case TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows:
      final location = await getSaveLocation(suggestedName: fileName);
      if (location == null) return null;
      await writeTo(location.path);
      return location.path;
    case TargetPlatform.android || TargetPlatform.fuchsia:
      throw UnsupportedError(
        'Android saves through the document provider, not a save panel',
      );
  }
}
