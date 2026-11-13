import 'dart:io';

import 'package:path/path.dart' as paths;

import 'document_store.dart';

/// What Open Recent finds at a remembered path.
enum RecentDocumentState {
  /// A regular file is there to open.
  available,

  /// The file is gone but its folder is not: it was moved or deleted, so
  /// the entry can go.
  missing,

  /// The folder is gone too. It may be on a disk or share that is not
  /// connected right now, so the entry stays for when it is.
  folderUnavailable,
}

/// Decides what Open Recent finds at [path] without opening the file. The
/// file is checked through [store], the shell's filesystem boundary; only
/// the folder check, which the store has no question for, reads the disk
/// directly.
Future<RecentDocumentState> recentDocumentState(
  DocumentStore store,
  String path,
) async {
  if (await store.stamp(path) != null) return RecentDocumentState.available;
  final folder = Directory(paths.dirname(path));
  try {
    return await folder.exists()
        ? RecentDocumentState.missing
        : RecentDocumentState.folderUnavailable;
  } on FileSystemException {
    // A folder Planchette may not look into, unlike a missing one, throws
    // here; it is as unavailable to this user, so the entry stays.
    return RecentDocumentState.folderUnavailable;
  }
}
