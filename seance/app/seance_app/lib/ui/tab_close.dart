import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/mac_commands.dart';
import 'session_label.dart';

/// Close [tabId] behind the guards its close button has always had: an
/// editor with unsaved changes asks first; a session asks for each of its
/// editors (they close with it) and before deleting the managed local copies
/// its close takes with it. Declining any of them leaves every tab open.
///
/// The tab strip's close button and the close-tab shortcut both come here,
/// so no way of closing a tab can skip a guard another one has (SEA-009).
/// [context] hosts the dialogs; it must be under the app's navigator.
Future<void> confirmAndCloseTab(
  BuildContext context,
  AppState state,
  String tabId,
) async {
  final tab = state.tabById(tabId);
  if (tab == null) return;
  if (tab is EditorTab) {
    if (await _editorMayClose(context, tab)) await state.closeTab(tabId);
    return;
  }
  if (tab is! TerminalSession) return;
  // Its editor tabs die with the session (the checkouts they write to are
  // deleted): a declined unsaved-buffer confirm aborts the whole close.
  final session = tab;
  for (final editor in state.editorTabsOwnedBy(session)) {
    if (!context.mounted) return;
    if (!await _editorMayClose(context, editor)) return;
  }
  if (!context.mounted) return;
  if (!await _runningCommandMayEnd(context, session)) return;
  final localCopyCount =
      (session.files?.localCopies.length ?? 0) +
      session.retainedLocalCopies.length;
  if (localCopyCount > 0) {
    // The guard lives here rather than above: a session with no local
    // copies needs no dialog and no context, so it still closes.
    if (!context.mounted) return;
    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close session and local edits?'),
        content: Text(
          '$localCopyCount downloaded ${localCopyCount == 1 ? 'file has' : 'files have'} '
          'a managed local copy. Closing this tab deletes '
          '${localCopyCount == 1 ? 'it' : 'them'}, including changes that '
          'have not been uploaded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close and Delete'),
          ),
        ],
      ),
    );
    if (close != true) return;
  }
  await state.closeTab(tabId);
}

/// Whether an editor tab's buffer may be dropped. A clean buffer needs no
/// ask; a dirty one is asked through the editor's own confirm dialog when
/// its state is mounted, or — when the widget is somehow unreachable —
/// through a plain dialog on the caller's context, so a close never
/// silently does nothing while unsaved text is at stake.
Future<bool> _editorMayClose(BuildContext context, EditorTab tab) async {
  if (!tab.dirty.value) return true;
  if (Theme.of(context).platform == TargetPlatform.macOS) {
    return _macEditorMayClose(tab);
  }
  final confirmed = await tab.editorKey.currentState?.confirmDiscard();
  if (confirmed != null) return confirmed;
  if (!context.mounted) return false;
  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Discard unsaved changes?'),
      content: Text(
        '${sanitizeRemoteLabel(tab.remotePath)} has unsaved changes.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return discard ?? false;
}

/// The Mac's document question for a dirty editor tab: Save (the default),
/// Cancel, or Don't Save, as TextEdit asks. Save writes the buffer the way
/// File ▸ Save does, uploading when the file can be, and closes only once
/// nothing is left unsaved.
Future<bool> _macEditorMayClose(EditorTab tab) async {
  const save = 0;
  const dontSave = 2;
  final editor = tab.editorKey.currentState;
  final answer = await showMacAlert(
    message:
        'Do you want to save the changes you made to '
        '“${editorTabLabel(tab.remotePath)}”?',
    informative: 'Your changes will be lost if you don’t save them.',
    // Without a mounted editor there is nothing to save through.
    buttons: [if (editor != null) 'Save', 'Cancel', 'Don’t Save'],
    destructive: editor != null ? dontSave : 1,
  );
  final button = answer?.button;
  if (editor == null) return button == 1;
  if (button == dontSave) return true;
  if (button != save) return false;
  await editor.save(upload: editor.canUpload);
  return !tab.dirty.value;
}

/// Terminal's question before a close ends a command still running in the
/// tab (macOS; the shell's own prompt needs no asking). Elsewhere, and at
/// a prompt, the tab closes as it always has.
Future<bool> _runningCommandMayEnd(
  BuildContext context,
  TerminalSession session,
) async {
  if (Theme.of(context).platform != TargetPlatform.macOS) return true;
  final command = session.metadata.value.runningCommand;
  if (command == null || !session.isConnected) return true;
  const terminate = 0;
  final answer = await showMacAlert(
    message: 'Do you want to terminate the running process in this tab?',
    informative: 'Closing this tab ends “$command”.',
    buttons: const ['Terminate', 'Cancel'],
  );
  return answer?.button == terminate;
}
