import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show RemoteFileEntry;

import '../../l10n/app_localizations.dart';
import '../../services/other_pane_transfer.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_location.dart';
import '../display_path.dart';
import 'compact_posture.dart';

/// UI-06's phone "Copy to…": a confirmation sheet that names the
/// destination host and folder before anything is queued, with Copy,
/// Change folder and Cancel. The sheet works on [plan], a snapshot
/// taken when it opened, so the target on screen is the target Copy
/// enqueues even if the other pane reconnects or its tab closes while
/// the sheet is up. Resolves true once the copy is queued.
Future<bool> showCompactCopyToSheet(
  BuildContext context, {
  required OtherPaneCopyPlan plan,
  required PaneDropDelegate delegate,
}) async {
  final queued = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _CopyToSheet(plan: plan, delegate: delegate),
  );
  return queued ?? false;
}

/// The destination host's name, from the plan rather than the live pane:
/// a rebind of the other pane under the open sheet must not turn a
/// server destination into "This device" while Copy still enqueues to
/// the server.
String _hostLabel(AppLocalizations l10n, OtherPaneCopyPlan plan) =>
    plan.serverLabel ?? l10n.sidebarThisDevice;

class _CopyToSheet extends StatefulWidget {
  const _CopyToSheet({required this.plan, required this.delegate});

  final OtherPaneCopyPlan plan;
  final PaneDropDelegate delegate;

  @override
  State<_CopyToSheet> createState() => _CopyToSheetState();
}

class _CopyToSheetState extends State<_CopyToSheet> {
  late String _folder = widget.plan.folder;

  Future<void> _changeFolder() async {
    final picked = await showCompactFolderPicker(
      context,
      plan: widget.plan,
      start: _folder,
    );
    if (picked == null || !mounted) return;
    setState(() => _folder = picked);
  }

  // Copy is enabled only while the plan allows [_folder], and
  // enqueueOtherPaneCopy refuses only what the plan disallows, so a
  // refusal here is a programming error rather than a user-facing state.
  void _copy() {
    final queued = enqueueOtherPaneCopy(widget.delegate, widget.plan, _folder);
    assert(queued);
    if (queued) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final host = _hostLabel(l10n, widget.plan);
    final allowed = widget.plan.allows(_folder);
    return SafeArea(
      key: const ValueKey(CompactKey.copyToSheet),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.compactCopyToTitle(widget.plan.rootPaths.length),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _Field(
              key: const ValueKey(CompactKey.copyToHost),
              icon: widget.plan.serverLabel != null
                  ? Icons.dns_outlined
                  : Icons.smartphone_outlined,
              caption: l10n.compactCopyToHost,
              value: host,
            ),
            const SizedBox(height: 8),
            _Field(
              key: const ValueKey(CompactKey.copyToFolder),
              icon: Icons.folder_outlined,
              caption: l10n.compactCopyToFolder,
              // Full path, wrapped rather than ellipsized: the folder is
              // what the user confirms, so every segment stays readable.
              value: isolatePathForDisplay(_folder),
            ),
            if (!allowed) ...[
              const SizedBox(height: 8),
              Text(
                l10n.compactCopyToNotAllowed,
                key: const ValueKey(CompactKey.copyToNotAllowed),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  key: const ValueKey(CompactKey.copyToCancel),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.compactCancel),
                ),
                OutlinedButton(
                  key: const ValueKey(CompactKey.copyToChangeFolder),
                  onPressed: () => unawaited(_changeFolder()),
                  child: Text(l10n.compactCopyToChangeFolder),
                ),
                Semantics(
                  label: l10n.compactCopyToConfirmSemantics(host, _folder),
                  excludeSemantics: true,
                  button: true,
                  enabled: allowed,
                  onTap: allowed ? _copy : null,
                  child: FilledButton(
                    key: const ValueKey(CompactKey.copyToConfirm),
                    onPressed: allowed ? _copy : null,
                    child: Text(l10n.compactCopyToConfirm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.icon,
    required this.caption,
    required this.value,
  });

  final IconData icon;
  final String caption;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  caption,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(value, style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Change folder's picker: browses the destination host's folders from
/// [start] (the other pane's folder) through the other pane's channel,
/// without navigating that pane. Resolves to the chosen folder, or null
/// on Cancel.
Future<String?> showCompactFolderPicker(
  BuildContext context, {
  required OtherPaneCopyPlan plan,
  required String start,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FolderPicker(plan: plan, start: start),
    ),
  );
}

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.plan, required this.start});

  final OtherPaneCopyPlan plan;
  final String start;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late String _path = widget.start;
  List<RemoteFileEntry>? _folders;
  bool _failed = false;

  /// Bumped per listing, so a slow answer for a folder the user already
  /// left never replaces the current one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_list());
  }

  Future<void> _list() async {
    final generation = ++_generation;
    setState(() {
      _folders = null;
      _failed = false;
    });
    List<RemoteFileEntry>? folders;
    var failed = false;
    try {
      folders = await widget.plan.target.listFolders(_path);
    } on Object {
      // Typed refusals and a dead channel alike: the picker offers Retry
      // or another folder, never a silent empty list.
      failed = true;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _folders = folders;
      _failed = failed;
    });
  }

  void _open(String path) {
    _path = path;
    unawaited(_list());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final parent = paneParentPath(_path);
    final canGoUp = parent != _path && parent.length < _path.length;
    final folders = _folders;
    final Widget body;
    if (_failed) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.compactFolderPickerFailed),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey(CompactKey.folderPickerRetry),
              onPressed: () => unawaited(_list()),
              child: Text(l10n.compactFolderPickerRetry),
            ),
          ],
        ),
      );
    } else if (folders == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (folders.isEmpty) {
      body = Center(child: Text(l10n.compactFolderPickerEmpty));
    } else {
      body = ListView.builder(
        itemCount: folders.length,
        itemBuilder: (context, index) {
          final folder = folders[index];
          return ListTile(
            key: ValueKey((CompactKey.folderPickerRow, folder.path)),
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(folder.path),
          );
        },
      );
    }
    return Scaffold(
      key: const ValueKey(CompactKey.folderPicker),
      appBar: AppBar(
        leading: CloseButton(
          key: const ValueKey(CompactKey.folderPickerCancel),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.compactFolderPickerTitle),
            Text(
              isolatePathForDisplay(_path),
              key: const ValueKey(CompactKey.folderPickerPath),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const ValueKey(CompactKey.folderPickerUp),
            tooltip: l10n.compactFolderPickerUp,
            onPressed: canGoUp ? () => _open(parent) : null,
            icon: const Icon(Icons.arrow_upward),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            key: const ValueKey(CompactKey.folderPickerChoose),
            // A folder that cannot be listed is still a valid pick only
            // once it has listed: choosing it blind would queue into a
            // folder the picker could not confirm exists.
            onPressed: folders == null
                ? null
                : () => Navigator.of(context).pop(_path),
            child: Text(l10n.compactFolderPickerChoose),
          ),
        ),
      ),
    );
  }
}
