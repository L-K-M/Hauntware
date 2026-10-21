/// The platform image picker behind ghost_marks' mark picker
/// (`ServerMarkImageReader`), for the apps on file_picker 11: Séance and
/// Poltergeist pass [pickServerMarkImage] as `readImage`.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:ghost_ui/ghost_ui.dart'
    show kBadgeImageAppleExtensions, kBadgeImageExtensions;

/// What [pickServerMarkImage] asks the picker for on [platform].
///
/// Desktop pickers get an explicit extension list, because the plugin's own
/// image type is a fixed list without SVG on Linux and Windows. Mobile keeps
/// the platform image type: on Android that is `image/*`, which SVG's MIME
/// type already matches, and on iOS it is the photo picker, which an
/// extension list would replace with the document browser.
({FileType type, List<String>? extensions}) serverMarkImageFilter(
  TargetPlatform platform, {
  bool web = kIsWeb,
}) {
  final desktop =
      !web &&
      switch (platform) {
        TargetPlatform.linux ||
        TargetPlatform.macOS ||
        TargetPlatform.windows => true,
        _ => false,
      };
  return (
    type: desktop ? FileType.custom : FileType.image,
    extensions: desktop
        ? [
            ...kBadgeImageExtensions,
            if (platform == TargetPlatform.macOS) ...kBadgeImageAppleExtensions,
          ]
        : null,
  );
}

/// The bytes of an image chosen from the platform picker, or null if the user
/// cancelled. `withData` because the bytes are re-encoded rather than kept:
/// there is nothing to stream to, and on Android a document provider may have
/// no path at all (see AGENTS.md on file_picker).
Future<Uint8List?> pickServerMarkImage() async {
  final filter = serverMarkImageFilter(defaultTargetPlatform);
  final result = await FilePicker.pickFiles(
    type: filter.type,
    allowedExtensions: filter.extensions,
    withData: true,
  );
  final files = result?.files ?? const [];
  if (files.isEmpty) return null;
  final bytes = files.first.bytes;
  if (bytes == null) {
    // `withData` was asked for and the picker produced a file without any:
    // reported on some Android document providers. Returning null here would
    // be read as a cancel and the dialog would sit there having silently done
    // nothing, so it is raised for the caller's handler to show.
    throw Exception('the file picker returned no image bytes');
  }
  return bytes;
}
