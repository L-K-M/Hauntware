import 'dart:io';

/// Moves a corrupt store file aside so a bad file cannot wedge startup.
/// The name is UTC-stamped, so a repeated corruption never overwrites the
/// previous evidence. Best effort, like Séance's app helper: if the file
/// cannot be moved, the caller still starts empty.
///
/// Moved from Poltergeist's app `file_stores.dart` with the file stores
/// (docs/design/catalog-library.md section 8), which share it.
Future<void> quarantineCorruptFile(File file) async {
  try {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll('.', '');
    await file.rename('${file.path}.corrupt-$stamp');
  } catch (_) {
    // Best effort: if we can't move it aside, the caller still starts empty.
  }
}
