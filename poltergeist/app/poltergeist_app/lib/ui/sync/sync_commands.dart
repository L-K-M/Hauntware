// The sync commands (05 §7/§9, D32 §7): `sync.synchronizePanes` —
// ⌥⌘Y / Ctrl+Alt+Y (02 §8.3) — builds an ad-hoc pair from the two
// panes' current locations (the focused pane is the source) and shows
// it in the Sync sheet; `sync.newSavedSync` opens the same sheet in its
// new-favorite mode, which persists a savedSync bookmark;
// `sync.copyRsyncCommand` copies the active plan's rsync export (05
// §2.1); `sync.purgeTrash` empties live sync-trash roots after the rail-5
// confirmation; `sync.adjustDocrootTrash` opens rail 5's safer-path field;
// `sync.compareSelected` opens 06 §6's paired-file view.
// All live in the Server menu.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';
import '../../theme/family_hues.dart';

const kSyncSynchronizePanesCommandId = 'sync.synchronizePanes';
const kSyncNewSavedSyncCommandId = 'sync.newSavedSync';
const kSyncCopyRsyncCommandId = 'sync.copyRsyncCommand';
const kSyncPurgeTrashCommandId = 'sync.purgeTrash';
const kSyncAdjustDocrootTrashCommandId = 'sync.adjustDocrootTrash';
const kSyncCompareSelectedCommandId = 'sync.compareSelected';

/// The sync command registrations. The verbs themselves are shell
/// operations (pair construction reads both pane strips; the sheet's
/// verbs write the bookmark store and open a plan tab), so they arrive
/// as delegates — the shell owns the seams, this file owns the
/// registration surface.
List<RegisteredCommand> buildSyncCommands({
  required WorkspaceController workspace,
  required bool Function() synchronizeEnabled,
  required bool Function() savedSyncEnabled,
  required bool Function() copyRsyncEnabled,
  required bool Function() purgeTrashEnabled,
  required bool Function() adjustDocrootTrashEnabled,
  required bool Function() compareEnabled,
  required FutureOr<void> Function(BuildContext context) synchronizePanes,
  required FutureOr<void> Function(BuildContext context) newSavedSync,
  required FutureOr<void> Function(BuildContext context) copyRsync,
  required FutureOr<void> Function(BuildContext context) purgeTrash,
  required FutureOr<void> Function(BuildContext context) adjustDocrootTrash,
  required FutureOr<void> Function(BuildContext context) compareSelected,
}) {
  return [
    RegisteredCommand(
      id: kSyncSynchronizePanesCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncSynchronizePanes,
      icon: Icons.sync_alt,
      hue: FamilyHue.indigo,
      // ⌥⌘Y on macOS, Ctrl+Alt+Y elsewhere (02 §8.3's table).
      activators: (platform) => platform == TargetPlatform.macOS
          ? const [
              SingleActivator(LogicalKeyboardKey.keyY, meta: true, alt: true),
            ]
          : const [
              SingleActivator(
                LogicalKeyboardKey.keyY,
                control: true,
                alt: true,
              ),
            ],
      enabled: synchronizeEnabled,
      disabledReason: (l10n) => l10n.commandDisabledSyncAnchors,
      run: (context) async => synchronizePanes(context),
      // 02 §9's Commands table: "Synchronize…" holds the third slot —
      // between the transfer/move block and Calculate Folder Sizes.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 30,
        group: 1,
      ),
      // D32 §4: Sync is a labelled primary header action.
      shortLabel: (l10n) => l10n.syncShortLabel,
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.primary,
        order: 10,
        labelled: true,
      ),
    ),
    RegisteredCommand(
      id: kSyncNewSavedSyncCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncNewSavedSync,
      icon: Icons.sync,
      hue: FamilyHue.indigo,
      // No chord in 02 §8.3 — menu/palette reachable.
      enabled: savedSyncEnabled,
      disabledReason: (l10n) => l10n.commandDisabledNoBookmarks,
      run: (context) async => newSavedSync(context),
      // Directly under Synchronize…; the §9 table names no saved-sync
      // slot, so it sits in the gap before Calculate Folder Sizes (40).
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 35,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kSyncCopyRsyncCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncCopyRsyncCommand,
      icon: Icons.terminal,
      hue: FamilyHue.orange,
      // No chord in 02 §8.3 — menu/palette reachable; the plan view's
      // action bar renders the same command.
      enabled: copyRsyncEnabled,
      disabledReason: (l10n) => l10n.commandDisabledNoPlan,
      run: (context) async => copyRsync(context),
      // The sync block's third row — enabled only while an exportable
      // plan tab is focused (05 §2.1: the exporter is reachable only
      // from the plan view).
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 37,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kSyncPurgeTrashCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncPurgeTrash,
      icon: Icons.delete_sweep,
      hue: FamilyHue.red,
      enabled: purgeTrashEnabled,
      disabledReason: (l10n) => l10n.commandDisabledNoSyncTrash,
      run: (context) async => purgeTrash(context),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 38,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kSyncAdjustDocrootTrashCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncAdjustDocrootTrash,
      icon: Icons.public_off_outlined,
      hue: FamilyHue.red,
      enabled: adjustDocrootTrashEnabled,
      disabledReason: (l10n) => l10n.commandDisabledNoDocrootTrash,
      run: (context) async => adjustDocrootTrash(context),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 39,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kSyncCompareSelectedCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.syncCompareSelected,
      icon: Icons.compare_arrows,
      hue: FamilyHue.indigo,
      enabled: compareEnabled,
      disabledReason: (l10n) => l10n.commandDisabledNoComparableItem,
      run: (context) async => compareSelected(context),
      // The plan-row context menu and double-click render this same
      // command. Its menu slot satisfies 02 §8.1 on every platform.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 40,
        group: 1,
      ),
    ),
  ];
}
