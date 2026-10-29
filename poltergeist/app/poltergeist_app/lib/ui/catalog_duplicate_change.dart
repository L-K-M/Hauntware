import 'package:ghost_ui/ghost_ui.dart'
    show GhostUndoDeclined, GhostUndoableChange;
import 'package:poltergeist_core/poltergeist_core.dart' show ServerConfig;

import '../l10n/app_localizations.dart';
import '../services/bookmark_backup_service.dart';

/// The change a catalog duplicate records into the window's undo
/// history: Undo removes the copy; Redo duplicates again — whatever copy
/// it makes is what the next Undo removes. A copy still bound to live
/// panes can only go once they close; the change stays put meanwhile
/// (Séance's duplicateServerInteractively).
GhostUndoableChange catalogDuplicateChange({
  required BookmarkBackupService backups,
  required ServerConfig server,
  required ServerConfig copy,
  required bool Function(String serverId) isBound,
  required AppLocalizations l10n,
}) {
  var latest = copy;
  return GhostUndoableChange(
    name: l10n.undoChangeDuplicateServer,
    undo: () async {
      if (isBound(latest.id)) {
        throw GhostUndoDeclined(l10n.undoDeclineServerBound(latest.label));
      }
      await backups.deleteServer(latest);
    },
    redo: () async => latest = await backups.duplicateServer(server),
  );
}
