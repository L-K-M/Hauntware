import 'package:ghost_ui/ghost_ui.dart';
import 'package:seance_core/seance_core.dart';

/// Projects [entry] onto the shared presentation model — the one place
/// `RemoteFileEntry` meets `GhostFileItem`. The kind classifier and its
/// glyph/hue table live in `ghost_ui` (`ghost_file_kinds.dart`), the code
/// Poltergeist's `ui/panes/pane_format.dart` and `ui/panes/kind_glyph.dart`
/// were ported into.
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
