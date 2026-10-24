import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../controllers/stack_folders.dart';
import '../../l10n/app_localizations.dart';

/// [files]' stacks that [projects] do not list, as folders with their
/// compose files, sorted: a file in a listed project's working directory,
/// or one a listed project names, belongs to that project.
List<({String folder, List<String> files})> unlistedStacks(
  List<String> files,
  List<ComposeProject> projects,
) {
  final listedFolders = {
    for (final project in projects)
      if (project.workingDir case final dir?) _withoutSlash(dir),
  };
  final listedFiles = {for (final project in projects) ...project.configFiles};
  final byFolder = <String, List<String>>{};
  for (final file in files) {
    if (listedFiles.contains(file)) continue;
    final folder = file.substring(0, file.lastIndexOf('/'));
    if (listedFolders.contains(folder)) continue;
    (byFolder[folder] ??= []).add(file);
  }
  return [
    for (final folder in byFolder.keys.toList()..sort())
      (folder: folder, files: byFolder[folder]!..sort()),
  ];
}

String _withoutSlash(String path) => path.length > 1 && path.endsWith('/')
    ? path.substring(0, path.length - 1)
    : path;

/// STK-08's stacks without containers on [serverId]: the compose files in
/// the folders the user named on this device that no listed stack
/// (`projects`) accounts for, scanned as the section shows and again on
/// request or when the folders change.
class UnlistedStacks extends StatefulWidget {
  const UnlistedStacks({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.projects,
  });

  final MonitoringController monitoring;
  final String serverId;
  final List<ComposeProject> projects;

  @override
  State<UnlistedStacks> createState() => _UnlistedStacksState();
}

class _UnlistedStacksState extends State<UnlistedStacks> {
  Future<DockerPayload>? _scan;

  StackFolders get _folders => widget.monitoring.stackFolders;

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  @override
  void didUpdateWidget(UnlistedStacks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId != widget.serverId) _rescan();
  }

  void _rescan() {
    final folders = _folders.foldersFor(widget.serverId);
    _scan = folders.isEmpty
        ? null
        : widget.monitoring.docker.scanStacks(widget.serverId, folders);
  }

  Future<void> _choose() async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    final folders = await showDialog<List<String>>(
      context: context,
      builder: (context) =>
          _FoldersDialog(initial: _folders.foldersFor(widget.serverId)),
    );
    if (folders == null || !mounted) return;
    try {
      await _folders.setFolders(widget.serverId, folders);
    } on Object {
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.dockerStackFoldersNotSaved);
      }
    }
    if (mounted) setState(_rescan);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final folders = _folders.foldersFor(widget.serverId);
    final scan = _scan;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.dockerStacksUnlisted,
              style: theme.textTheme.titleSmall,
            ),
          ),
          Text(
            folders.isEmpty
                ? l10n.dockerStackFoldersNone
                : l10n.dockerStackFoldersList(folders.join(', ')),
            style: muted,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => unawaited(_choose()),
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(l10n.dockerStackFoldersChoose),
              ),
              if (scan != null)
                TextButton(
                  onPressed: () => setState(_rescan),
                  child: Text(l10n.dockerStackFoldersScanAgain),
                ),
            ],
          ),
          if (scan != null)
            FutureBuilder(
              future: scan,
              builder: (context, snapshot) => switch (snapshot.data) {
                null => Text(l10n.dockerStackFoldersScanning, style: muted),
                DockerStackScanPayload(:final files, :final incomplete) =>
                  _found(context, files, incomplete: incomplete),
                _ => Text(l10n.dockerStackFoldersScanFailed, style: muted),
              },
            ),
        ],
      ),
    );
  }

  Widget _found(
    BuildContext context,
    List<String> files, {
    required bool incomplete,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final stacks = unlistedStacks(files, widget.projects);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (stacks.isEmpty)
          Text(l10n.dockerStackFoldersNoneFound, style: muted),
        for (final stack in stacks)
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stack.folder.substring(stack.folder.lastIndexOf('/') + 1),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                for (final file in stack.files) Text(file, style: muted),
              ],
            ),
          ),
        if (incomplete) Text(l10n.dockerStackFoldersIncomplete, style: muted),
      ],
    );
  }
}

/// Asks for the folders to scan, one per line.
class _FoldersDialog extends StatefulWidget {
  const _FoldersDialog({required this.initial});

  final List<String> initial;

  @override
  State<_FoldersDialog> createState() => _FoldersDialogState();
}

class _FoldersDialogState extends State<_FoldersDialog> {
  late final _text = TextEditingController(text: widget.initial.join('\n'));
  StackFoldersProblem? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final (:folders, :problem) = parseStackFolders(_text.text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop(context, folders);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.dockerStackFoldersTitle),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _text,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            helperText: l10n.dockerStackFoldersHelper(kStackScanDirectoriesMax),
            helperMaxLines: 3,
            errorText: switch (_problem) {
              null => null,
              final problem => l10n.dockerStackFoldersProblem(
                problem.name,
                kStackScanDirectoriesMax,
              ),
            },
            errorMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.dockerStackFoldersCancel),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(l10n.dockerStackFoldersSave),
        ),
      ],
    );
  }
}
