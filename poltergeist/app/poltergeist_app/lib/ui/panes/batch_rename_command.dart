import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_controller.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';

const kFileBatchRenameCommandId = 'file.batchRename';

/// File ▸ Rename Items… (02 §2.6): renames two or more selected rows
/// through one rule. Return and F2 stay inline on the cursor row; this
/// opens only from menus, the row context menu and the palette, so a
/// multi-item rename never starts from muscle memory. The shell owns the
/// dialog, so the verb arrives as [open]; [available] carries the
/// shell's own gates.
RegisteredCommand buildBatchRenameCommand({
  required WorkspaceController workspace,
  required bool Function() available,
  required FutureOr<void> Function(BuildContext context, PaneController pane)
  open,
}) {
  BatchRenameAvailability? availability() =>
      workspace.activeTabController?.batchRenameAvailability;

  String disabledReason(AppLocalizations l10n) => switch (availability()) {
    null || BatchRenameAvailability.noListing => l10n.commandDisabledNoListing,
    BatchRenameAvailability.busy => l10n.commandDisabledRenameBusy,
    BatchRenameAvailability.needsTwo => l10n.commandDisabledSelectTwoOrMore,
    BatchRenameAvailability.nested => l10n.commandDisabledBatchRenameNested,
    BatchRenameAvailability.allFlagged =>
      l10n.commandDisabledBatchRenameAllFlagged,
    // The selection is fine; the shell's gate (another dialog's
    // session) is what holds the command.
    BatchRenameAvailability.available => l10n.commandDisabledBusy,
  };

  return RegisteredCommand(
    id: kFileBatchRenameCommandId,
    scope: CommandScope.selection,
    label: (l10n) => l10n.fileBatchRenameLabel,
    icon: Icons.drive_file_rename_outline,
    enabled: () =>
        available() && availability() == BatchRenameAvailability.available,
    disabledReason: disabledReason,
    run: (context) async {
      // Resolved at run time: the active tab may have changed since the
      // menu last checked enablement.
      final pane = workspace.activeTabController;
      if (pane == null) return;
      await open(context, pane);
    },
    // Between Rename (70) and Duplicate (72).
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.file,
      order: 71,
      group: 2,
    ),
  );
}
