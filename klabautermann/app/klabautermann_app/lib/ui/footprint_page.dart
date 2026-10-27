import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/operations_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart';
import 'time_display.dart';
import 'actions/action_preview.dart' show startAction;
import 'admin_mode_chip.dart' show TurnOnAdminModeButton;
import 'edit/remote_editor.dart' show openRemoteEditor;
import 'system_panel.dart' show PanelNotice;

/// The prefix a crontab backup's source carries before its account
/// (03 §8.11).
const String _crontabSource = 'crontab:';

/// How many backups of each file "Keep last" keeps (Q11).
const int _keptBackups = 5;

/// Hex digits of a backup's hash a row shows.
const int _shortHash = 12;

/// What Klabautermann keeps on [serverId] (SAF-14, 03 §8.11; M5 plan
/// M18): each scope's manifest rows and whether they are there, and every
/// backup the indexes record, grouped by the file it backs up, with
/// whether it still has the recorded hash. Root's part reads only in
/// admin mode, which the page offers to turn on.
///
/// "Keep last 5" and removing every backup of one file plan through the
/// action preview (Q11's tiers); restoring a backup reads it and opens
/// the file's editor with it as the new text, unsaved, so the restore is
/// an ordinary reviewed edit. Opening the page asks the engine to verify
/// the footprint again.
class FootprintPage extends StatefulWidget {
  const FootprintPage({
    super.key,
    required this.operations,
    required this.serverId,
    required this.serverName,
  });

  final OperationsController operations;
  final String serverId;
  final String serverName;

  @override
  State<FootprintPage> createState() => _FootprintPageState();
}

class _FootprintPageState extends State<FootprintPage> {
  /// A restore is reading its backup: a second tap would open a second
  /// editor over the first.
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    widget.operations.verifyFootprint(widget.serverId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.footprintTitle(widget.serverName)),
        actions: [
          IconButton(
            tooltip: l10n.footprintVerify,
            icon: const Icon(Icons.refresh),
            onPressed: () => widget.operations.verifyFootprint(widget.serverId),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.operations,
          builder: (context, _) {
            final operations = widget.operations;
            final state = operations.footprintOf(widget.serverId);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: switch (state) {
                null when operations.footprintRefused(widget.serverId) => [
                  PanelNotice(
                    icon: Icons.link_off,
                    text: l10n.footprintUnavailable,
                  ),
                ],
                null => [
                  PanelNotice(
                    icon: Icons.hourglass_empty,
                    text: l10n.footprintChecking,
                  ),
                ],
                final state => _sections(context, l10n, state),
              },
            );
          },
        ),
      ),
    );
  }

  List<Widget> _sections(
    BuildContext context,
    AppLocalizations l10n,
    FootprintState state,
  ) {
    // Nothing kept is a claim only a full read makes: not while root's
    // part is unread, nor when a warning says something was not read.
    final empty =
        state.files.isEmpty &&
        state.backups.isEmpty &&
        !state.rootUnchecked &&
        state.warnings.isEmpty;
    return [
      if (state.rootUnchecked) ...[
        PanelNotice(
          icon: Icons.admin_panel_settings_outlined,
          text: l10n.footprintRootUnchecked,
        ),
        TurnOnAdminModeButton(serverId: widget.serverId),
      ],
      for (final warning in state.warnings)
        PanelNotice(
          icon: Icons.warning_amber_outlined,
          text: l10n.footprintWarning(warning),
        ),
      if (empty)
        PanelNotice(icon: Icons.check_circle_outline, text: l10n.footprintNone),
      for (final scope in FootprintScope.values)
        ..._scope(context, l10n, state, scope),
    ];
  }

  List<Widget> _scope(
    BuildContext context,
    AppLocalizations l10n,
    FootprintState state,
    FootprintScope scope,
  ) {
    final files = [
      for (final file in state.files)
        if (file.scope == scope) file,
    ];
    final backups = [
      for (final backup in state.backups)
        if (backup.scope == scope) backup,
    ];
    if (files.isEmpty && backups.isEmpty) return const [];

    final bySource = <String, List<FootprintBackup>>{};
    for (final backup in backups) {
      (bySource[backup.entry.source] ??= []).add(backup);
    }
    for (final group in bySource.values) {
      group.sort((a, b) => b.entry.savedAt.compareTo(a.entry.savedAt));
    }
    final directory = files
        .where((file) => file.row.kind == FootprintKind.backupDirectory)
        .firstOrNull
        ?.row
        .path;
    final theme = Theme.of(context);

    return [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Semantics(
          header: true,
          child: Text(
            l10n.footprintScope(scope.name),
            style: theme.textTheme.titleMedium,
          ),
        ),
      ),
      for (final file in files)
        MergeSemantics(
          child: ListTile(
            dense: true,
            leading: Icon(
              file.present ? Icons.inventory_2_outlined : Icons.help_outline,
            ),
            title: Text(file.row.path),
            subtitle: Text(
              l10n.footprintFile(file.row.kind.name, file.present.toString()),
            ),
          ),
        ),
      if (bySource.values.any((group) => group.length > _keptBackups))
        ActionEntry(
          serverId: widget.serverId,
          point: ActionEntryPoint.backupRemove,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => startAction(
                context,
                KeepLastBackups(
                  widget.serverId,
                  scope: scope,
                  count: _keptBackups,
                ),
              ),
              icon: const Icon(Icons.auto_delete_outlined),
              label: Text(l10n.footprintKeepLast(_keptBackups)),
            ),
          ),
        ),
      for (final MapEntry(key: source, value: group) in bySource.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    _sourceLabel(l10n, source),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ),
              ActionEntry(
                serverId: widget.serverId,
                point: ActionEntryPoint.backupRemove,
                child: TextButton(
                  onPressed: () => startAction(
                    context,
                    RemoveBackups(
                      widget.serverId,
                      scope: scope,
                      source: source,
                    ),
                  ),
                  child: Text(l10n.footprintRemoveAll),
                ),
              ),
            ],
          ),
        ),
        for (final backup in group)
          _BackupRow(
            backup: backup,
            restore: directory == null || !_restorable(backup)
                ? null
                : () => unawaited(_restore(scope, directory, backup.entry)),
            serverId: widget.serverId,
          ),
      ],
    ];
  }

  /// Only a backup that still has its recorded hash restores.
  bool _restorable(FootprintBackup backup) =>
      backup.status == FootprintBackupStatus.intact;

  /// Reads [entry] from [directory] and opens its file's editor with it.
  Future<void> _restore(
    FootprintScope scope,
    String directory,
    BackupEntry entry,
  ) async {
    if (_restoring) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    _restoring = true;
    final EditReadResult read;
    try {
      read = await widget.operations.readEditable(
        widget.serverId,
        FileTarget('$directory/${entry.name}'),
      );
    } finally {
      _restoring = false;
    }
    if (!mounted) return;

    switch (read) {
      case EditContent(:final text, :final sha256) when sha256 == entry.sha256:
        await openRemoteEditor(
          context,
          serverId: widget.serverId,
          target: _targetOf(scope, entry.source),
          proposedText: text,
        );
      case EditContent():
        showTopToast(overlay, message: l10n.footprintRestoreChanged);
      case EditReadFailed(:final failure):
        showTopToast(overlay, message: l10n.editReadFailed(failure.name));
    }
  }
}

/// The editor target a backup of [source] restores into: the login
/// user's own crontab from its own scope, another account's from root's.
EditTarget _targetOf(FootprintScope scope, String source) {
  if (!source.startsWith(_crontabSource)) return FileTarget(source);
  return switch (scope) {
    FootprintScope.user => const CrontabTarget(),
    FootprintScope.root => CrontabTarget(
      user: source.substring(_crontabSource.length),
    ),
  };
}

String _sourceLabel(AppLocalizations l10n, String source) =>
    source.startsWith(_crontabSource)
    ? l10n.footprintCrontabSource(source.substring(_crontabSource.length))
    : source;

/// One backup: when it was made, its hash, whether it still has it, and
/// Restore.
class _BackupRow extends StatelessWidget {
  const _BackupRow({
    required this.backup,
    required this.restore,
    required this.serverId,
  });

  final FootprintBackup backup;
  final VoidCallback? restore;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final localizations = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final local = displayTime(context, serverId, backup.entry.savedAt);
    final status = backup.status;
    final restore = this.restore;
    return MergeSemantics(
      child: ListTile(
        dense: true,
        leading: Icon(
          switch (status) {
            FootprintBackupStatus.intact => Icons.check_circle_outline,
            FootprintBackupStatus.modified => Icons.report_outlined,
            FootprintBackupStatus.missing => Icons.help_outline,
          },
          color: status == FootprintBackupStatus.intact
              ? null
              : theme.colorScheme.error,
        ),
        title: Text(
          l10n.activityTime(
            localizations.formatShortDate(local),
            localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local)),
          ),
        ),
        subtitle: Text(
          l10n.footprintBackup(
            backup.entry.sha256.substring(0, _shortHash),
            status.name,
          ),
        ),
        trailing: restore == null
            ? null
            : ActionEntry(
                serverId: serverId,
                point: ActionEntryPoint.fileEdit,
                child: TextButton(
                  onPressed: restore,
                  child: Text(l10n.footprintRestore),
                ),
              ),
      ),
    );
  }
}
