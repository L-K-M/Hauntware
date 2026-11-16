import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/file_clipboard.dart';
import '../../services/file_operations.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_drop.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';
import '../top_toast.dart';

/// P4-21's clipboard verbs: Edit ▸ Cut (⌘X / Ctrl+X), Copy (⌘C / Ctrl+C)
/// and Paste (⌘V / Ctrl+V). A focused text field keeps these chords:
/// the chord scope's field-first suspension and the macOS menu's
/// Edit-verb retargeting hand them to the field.
const kEditCutFilesCommandId = 'edit.cut';
const kEditCopyFilesCommandId = 'edit.copy';
const kEditPasteFilesCommandId = 'edit.paste';

List<ShortcutActivator> Function(TargetPlatform) _perPlatform(
  LogicalKeyboardKey key,
) =>
    (platform) => platform == TargetPlatform.macOS
    ? [SingleActivator(key, meta: true)]
    : [SingleActivator(key, control: true)];

/// The registry rows for the file clipboard over [workspace]'s active
/// tab. [operations] performs Paste and records Undo.
List<RegisteredCommand> buildFileClipboardCommands({
  required WorkspaceController workspace,
  required FileClipboard clipboard,
  required FileOperations operations,
  required void Function(Object error) reportFailure,
}) {
  /// The active tab while it lists a folder and no Rename Items dialog
  /// owns its rows.
  PaneController? livePane() {
    final pane = workspace.activeTabController;
    if (pane == null || !pane.verbsEnabled || pane.batchRenameActive) {
      return null;
    }
    return pane.location == null ? null : pane;
  }

  // Selected rows only, never a bare cursor row: the verbs that act on
  // a selection without a dialog (Delete, Duplicate) follow the same
  // rule, so Cut never picks up a row the user just deselected.
  bool hasSelection() => livePane()?.selectedRoots.isNotEmpty ?? false;

  void put(FileClipboardMode mode) {
    final pane = livePane();
    final location = pane?.location;
    if (pane == null || location == null) return;
    clipboard.put(
      source: fsLocationForLocation(location),
      rootPaths: [for (final entry in pane.selectedRoots) entry.path],
      mode: mode,
    );
  }

  bool canPaste() {
    final content = clipboard.content;
    final location = livePane()?.location;
    if (content == null || location == null) return false;
    return filePasteKind(
          content,
          destination: fsLocationForLocation(location),
          destinationDir: location.path,
        ) !=
        null;
  }

  return [
    RegisteredCommand(
      id: kEditCutFilesCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.editCutFilesLabel,
      icon: Icons.content_cut,
      activators: _perPlatform(LogicalKeyboardKey.keyX),
      enabled: hasSelection,
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (_) async => put(FileClipboardMode.cut),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 30,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kEditCopyFilesCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.editCopyFilesLabel,
      icon: Icons.content_copy_outlined,
      activators: _perPlatform(LogicalKeyboardKey.keyC),
      enabled: hasSelection,
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (_) async => put(FileClipboardMode.copy),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 32,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kEditPasteFilesCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.editPasteFilesLabel,
      icon: Icons.content_paste,
      activators: _perPlatform(LogicalKeyboardKey.keyV),
      enabled: canPaste,
      disabledReason: (l10n) => clipboard.content == null
          ? l10n.commandDisabledClipboardEmpty
          : l10n.commandDisabledPasteHere,
      run: (context) async {
        final location = livePane()?.location;
        if (location == null) return;
        final l10n = AppLocalizations.of(context);
        final FilePasteResult result;
        try {
          result = await operations.paste(
            destination: fsLocationForLocation(location),
            destinationDir: location.path,
          );
        } on Object catch (error) {
          reportFailure(error);
          return;
        }
        final message = switch (result.outcome) {
          FilePasteOutcome.queued || FilePasteOutcome.renamed => null,
          FilePasteOutcome.refused => l10n.commandDisabledPasteHere,
          FilePasteOutcome.unavailable => l10n.filePasteUnavailable,
          FilePasteOutcome.partial => l10n.filePastePartial(
            result.failures.length,
            result.failures.first.error.toString(),
          ),
        };
        if (message != null && context.mounted) {
          showTopToastIn(context, message: message);
        }
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 34,
        group: 2,
      ),
    ),
  ];
}

/// Undo Copy's confirmation (decision Q5): the copied items are deleted
/// only once the user agrees. Cancel is the default.
Future<bool> confirmFileCopyUndo(
  BuildContext context, {
  required String host,
  required int count,
}) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('fileUndoCopy.dialog'),
      title: Text(l10n.fileUndoCopyTitle),
      content: Text(l10n.fileUndoCopyMessage(count, host)),
      actions: [
        TextButton(
          key: const ValueKey('fileUndoCopy.cancel'),
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.fileUndoCopyCancel),
        ),
        TextButton(
          key: const ValueKey('fileUndoCopy.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.fileUndoCopyConfirm),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Makes the window's [FileClipboard] available to the listing rows, so
/// a cut row renders dimmed and the rows repaint when the clipboard
/// changes.
class FileClipboardScope extends InheritedNotifier<FileClipboard> {
  const FileClipboardScope({
    super.key,
    required FileClipboard clipboard,
    required super.child,
  }) : super(notifier: clipboard);

  static FileClipboard? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FileClipboardScope>()
      ?.notifier;
}

/// The opacity of a row that was cut and not yet pasted.
const kCutRowOpacity = 0.45;
