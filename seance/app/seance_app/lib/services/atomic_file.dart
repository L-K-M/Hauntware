import 'dart:io';

import 'package:seance_core/catalog.dart'
    show AtomicFilePrivacy, AtomicFileWriter;

export 'package:seance_core/catalog.dart' show AtomicFilePrivacy;

/// Durable, crash-safe helpers for the JSON-file stores.
///
/// The stores used to write with a bare `file.writeAsString(...)`, which
/// truncates the file and then writes — so a crash or power-loss mid-write left
/// a truncated, unparseable file (including `vault.json`, which holds secrets).
/// These helpers make that impossible.

/// Write [contents] through the shared writer. Symlink aliases and lexical
/// or case variants share its ordered queue.
Future<void> writeStringAtomically(File file, String contents,
    {AtomicFilePrivacy privacy = AtomicFilePrivacy.processDefault}) =>
    const AtomicFileWriter().write(file, contents, privacy: privacy);

/// Move a file that failed to parse aside (to `*.corrupt`) so a single bad byte
/// can't wedge startup on every launch. Best-effort — any failure is swallowed
/// and the caller simply starts from an empty store.
Future<void> quarantineCorruptFile(File file) async {
  try {
    final dest = File('${file.path}.corrupt');
    if (await dest.exists()) await dest.delete();
    await file.rename(dest.path);
  } catch (_) {
    // Best effort: if we can't move it aside, the caller still starts empty.
  }
}

File _syncCollectionMarker(File file) => File('${file.path}.sync-recovery');

/// Persist that [file] was quarantined and its empty replacement is not proof
/// that previously published domain rows were deleted deliberately.
Future<void> markSyncCollectionRecovery(File file) =>
    writeStringAtomically(_syncCollectionMarker(file), 'pending\n');

Future<bool> hasSyncCollectionRecovery(File file) =>
    _syncCollectionMarker(file).exists();

/// Clear the quarantine provenance only after the coordinator has applied and
/// recollected the durable mirror successfully.
Future<void> clearSyncCollectionRecovery(File file) async {
  final marker = _syncCollectionMarker(file);
  if (await marker.exists()) await marker.delete();
}

/// [writeStringAtomically] with owner-only privacy: the rewrite the
/// identity audit log rotates through.
Future<void> writeOwnerOnlyAtomically(File file, String contents) =>
    writeStringAtomically(file, contents, privacy: AtomicFilePrivacy.ownerOnly);
