import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/pane_comparison.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';
import '../../theme/family_hues.dart';

const kFileCompareFilesCommandId = 'file.compareFiles';

/// File ▸ Compare Files: 06 §6's side-by-side view for two files the
/// panes' selections name ([resolvePaneComparison] holds the rules). The
/// shell owns the view's seams (the preview cache and producer), so the
/// verb arrives as [open]; [available] carries the shell's own gates.
RegisteredCommand buildCompareFilesCommand({
  required WorkspaceController workspace,
  required bool Function() available,
  required FutureOr<void> Function(
    BuildContext context,
    PaneComparison comparison,
  )
  open,
}) => RegisteredCommand(
  id: kFileCompareFilesCommandId,
  scope: CommandScope.selection,
  label: (l10n) => l10n.fileCompareFilesLabel,
  icon: Icons.compare_arrows,
  hue: FamilyHue.indigo,
  enabled: () => available() && resolvePaneComparison(workspace) != null,
  disabledReason: (l10n) => l10n.commandDisabledNoComparableFiles,
  run: (context) async {
    // Resolved again at run time: the selection may have moved since the
    // menu last checked enablement.
    final comparison = resolvePaneComparison(workspace);
    if (comparison == null) return;
    await open(context, comparison);
  },
  // Beside Preview and Reveal: like them, it only shows files.
  menuPlacement: const CommandMenuPlacement(
    menu: AppMenuId.file,
    order: 69,
    group: 1,
  ),
);
