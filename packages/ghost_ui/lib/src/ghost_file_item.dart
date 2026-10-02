/// The presentation-only file entry both Ghost apps hand the shared
/// file/folder rows.
///
/// The model is intentionally neutral: neither `seance_core`'s
/// `RemoteFileEntry`/`RemoteFileType` nor Poltergeist's own entry
/// adapters appear here, so `ghost_ui` stays free of SSH/core
/// dependencies and hosts project their own listings into it.
library;

/// How a listing row is shaped, corresponding to the POSIX node types
/// the remote file systems report (regular file, directory, symbolic
/// link, or anything else such as a socket or FIFO).
enum GhostFileNodeType {
  file,
  directory,
  symbolicLink,

  /// A node the remote end did not type as file/directory/link: the
  /// row still shows, classified by the fallback glyph.
  other,
}

/// A single listed entry as the shared rows need it.
///
/// Only presentation-relevant data lives here — the name as displayed
/// (hosts decode bytes before constructing the item), the node type,
/// and the optional size/modified metadata the columns render.
final class GhostFileItem {
  const GhostFileItem({
    required this.name,
    required this.type,
    this.size,
    this.modifiedAt,
  });

  /// The displayed basename (already decoded for the locale).
  final String name;

  /// What the remote end typed the node as.
  final GhostFileNodeType type;

  /// Byte size when known; `null` renders the unavailable dash.
  final int? size;

  /// Modification timestamp when known; `null` renders the dash.
  final DateTime? modifiedAt;

  bool get isDirectory => type == GhostFileNodeType.directory;

  bool get isSymbolicLink => type == GhostFileNodeType.symbolicLink;
}
