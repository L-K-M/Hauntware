part of 'sidebar_view.dart';

/// The rail's one-field name prompt (rename, new group, save to
/// servers) — the shared [showNamePrompt].
Future<String?> _promptName(
  BuildContext context, {
  required String title,
  required String fieldLabel,
  required Key fieldKey,
  required Key saveKey,
  String initial = '',
}) => showNamePrompt(
  context,
  title: title,
  fieldLabel: fieldLabel,
  fieldKey: fieldKey,
  saveKey: saveKey,
  initial: initial,
);

/// The rename verb: a store save through the controller, so the
/// `updatedAt` stamp lands. A failed save reports and says so — the
/// record is untouched.
Future<void> _renameBookmark(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  final renamed = await _promptName(
    context,
    title: bookmark.kind == BookmarkKind.remotePath
        ? l10n.sidebarRenameServerTitle
        : l10n.sidebarRenameTitle,
    fieldLabel: l10n.sidebarRenameFieldLabel,
    fieldKey: const ValueKey('sidebar.renameField'),
    saveKey: const ValueKey('sidebar.renameSave'),
    initial: bookmark.label,
  );
  if (renamed == null || renamed == bookmark.label || !context.mounted) return;
  try {
    final saved = await view.controller.rename(bookmark.id, renamed);
    view.undoHistory?.record(
      GhostUndoableChange(
        name: bookmark.kind == BookmarkKind.remotePath
            ? l10n.sidebarRenameServerTitle
            : l10n.sidebarRenameTitle,
        undo: () => _restoreIfListed(view, bookmark, l10n),
        redo: () => _restoreIfListed(view, saved, l10n),
      ),
    );
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

/// The store-edit undo/redo restore shared by rename and move: refuses
/// while the record is gone — a delete since would resurrect it —
/// and [SidebarController.restore] then re-stamps the captured row, so
/// id, group and position land back where it stood.
Future<void> _restoreIfListed(
  SidebarView view,
  Bookmark bookmark,
  AppLocalizations l10n,
) async {
  if (await view.controller.byId(bookmark.id) == null) {
    throw GhostUndoDeclined(l10n.undoDeclineDeleted);
  }
  await view.controller.restore(bookmark);
}

/// "Move to Group ▸ New Group…": group records are member-carried, so
/// creating a group IS the move.
Future<void> _newGroupFor(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  final group = await _promptName(
    context,
    title: l10n.sidebarNewGroupTitle,
    fieldLabel: l10n.sidebarGroupFieldLabel,
    fieldKey: const ValueKey('sidebar.groupField'),
    saveKey: const ValueKey('sidebar.groupSave'),
  );
  if (group == null || !context.mounted) return;
  try {
    final moved = await view.controller.moveToGroup(bookmark.id, group);
    view.undoHistory?.record(
      GhostUndoableChange(
        name: l10n.sidebarMoveToGroup,
        undo: () => _restoreIfListed(view, bookmark, l10n),
        redo: () => _restoreIfListed(view, moved, l10n),
      ),
    );
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

/// The + menu's "New Group…": no bookmark to carry it yet, so the group
/// waits in the controller (in memory) for its first member.
Future<void> _newPendingGroup(BuildContext context, SidebarView view) async {
  final l10n = AppLocalizations.of(context);
  final group = await _promptName(
    context,
    title: l10n.sidebarNewGroupTitle,
    fieldLabel: l10n.sidebarGroupFieldLabel,
    fieldKey: const ValueKey('sidebar.groupField'),
    saveKey: const ValueKey('sidebar.groupSave'),
  );
  if (group == null || !context.mounted) return;
  view.controller.addPendingGroup(group);
}

/// The delete verb: at once now that Undo restores the row — the
/// "cannot be undone" dialog it replaced held the delete because
/// nothing could. The toast names what went and offers Undo, guarded so
/// it fires only while this deletion is still the one Undo would take
/// back; the removal cascade rides the controller's seam as before.
Future<void> _deleteBookmark(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  final controller = view.controller;
  final pinned = controller.isPinned(bookmark.id);
  // Captured before the write: the deleted row's element can be gone by
  // the time the toast goes up.
  final overlay = Overlay.of(context, rootOverlay: true);
  try {
    await controller.remove(bookmark.id);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
    return;
  }
  if (!overlay.mounted) return;
  final history = view.undoHistory;
  final change = GhostUndoableChange(
    name: bookmark.kind == BookmarkKind.remotePath
        ? l10n.sidebarDeleteServerTitle
        : l10n.sidebarDeleteTitle,
    undo: () => controller.restore(bookmark, pinned: pinned),
    // The removal cascade re-runs through the controller: pinned state
    // and live connections go with the record again.
    redo: () async {
      await controller.remove(bookmark.id);
    },
  );
  history?.record(change);
  showTopToast(
    overlay,
    message: l10n.sidebarDeletedNotice(bookmark.label),
    actionLabel: history == null ? null : l10n.editUndoLabel,
    // This deletion only, while it is still the one Undo would take back
    // — a change made since has its own notice.
    onAction: history == null
        ? null
        : () {
            if (!overlay.mounted || !history.isNextUndo(change)) return;
            unawaited(
              stepEditHistory(
                overlay,
                history,
                direction: UndoDirection.undo,
                target: EditHistoryTarget.appData,
              ),
            );
          },
  );
}

/// "Save to Favorites…" on a live Quick Connect session: the pane's
/// save-as-favorite flow, reached from the rail's row and from Server ▸
/// Save to Favorites… — a name (prefilled from the live endpoint, never
/// the raw address), then a store save through [controller].
Future<void> saveSessionToServers(
  BuildContext context,
  SidebarController controller,
  SidebarAdhocSession session,
) async {
  final l10n = AppLocalizations.of(context);
  final name = await promptSaveToServers(
    context,
    session.bookmark,
    fieldKey: const ValueKey('sidebar.saveServerField'),
    saveKey: const ValueKey('sidebar.saveServerSave'),
  );
  if (name == null || !context.mounted) return;
  try {
    await controller.saveRemoteLocation(
      live: session.bookmark,
      path: session.path,
      label: name,
    );
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

void _showSidebarError(BuildContext context, AppLocalizations l10n) =>
    _showSidebarNotice(context, l10n.sidebarActionFailed);

void _showSidebarNotice(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}
