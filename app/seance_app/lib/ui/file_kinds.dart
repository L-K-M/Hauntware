import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:seance_core/seance_core.dart';

/// A listed item's kind, for its glyph only: the Files tab names an
/// item by its file type in words, so a wrong guess from an extension
/// never misleads assistive tech.
///
/// The classifier and glyph/hue table now live in `ghost_ui`
/// (`ghost_file_kinds.dart`), the code Poltergeist's
/// `ui/panes/pane_format.dart` and `ui/panes/kind_glyph.dart` were
/// ported into — the copy this file previously carried. [FileKind]
/// stays a public typedef so call sites and tests keep their names.
typedef FileKind = GhostFileKind;

/// Projects [entry] onto the shared presentation model — the one place
/// `RemoteFileEntry` meets `GhostFileItem`.
GhostFileItem ghostFileItemOf(RemoteFileEntry entry) => GhostFileItem(
  name: entry.name,
  type: switch (entry.type) {
    RemoteFileType.directory => GhostFileNodeType.directory,
    RemoteFileType.symbolicLink => GhostFileNodeType.symbolicLink,
    RemoteFileType.file => GhostFileNodeType.file,
    RemoteFileType.other => GhostFileNodeType.other,
  },
  size: entry.size,
  modifiedAt: entry.modifiedAt,
);

/// [entry]'s kind: its file type first (folders and links are never
/// guessed from a name), then the lowercase extension after the last
/// dot. A leading dot is part of a dotfile's stem, so `.bashrc` has no
/// extension and reads as a generic file.
FileKind fileKind(RemoteFileEntry entry) =>
    ghostFileKind(ghostFileItemOf(entry));

/// [kind]'s glyph and family hue. The glyphs are the filled faces,
/// since a hairline outline at list size carries too little colour to
/// be told apart at a glance.
(IconData, FamilyHue) fileKindGlyph(FileKind kind) => ghostFileKindGlyph(kind);

/// [entry]'s kind glyph as an [Icon] in its hue for [context]'s theme.
Icon fileKindIcon(
  BuildContext context,
  RemoteFileEntry entry, {
  double? size,
}) => ghostFileKindIcon(context, fileKind(entry), size: size ?? 24);
