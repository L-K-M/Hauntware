import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/document_workspace.dart';

/// Tells the user that another program changed or removed a document's file,
/// with the choices that resolve it. It sits above the document, which keeps
/// the user's text, and goes away once the file and the tab agree again.
///
/// The notice never takes focus: it appears when the window comes back to
/// the front, often while the user is typing. Its buttons follow the tab
/// strip in keyboard order, and a screen reader announces it as it appears.
class DiskNotice extends StatelessWidget {
  const DiskNotice({
    super.key,
    required this.state,
    required this.name,
    required this.enabled,
    required this.onReload,
    required this.onKeepMine,
    required this.onSave,
  }) : assert(state != DiskState.current);

  final DiskState state;
  final String name;

  /// False while the tab or the window is busy, when every choice waits.
  final bool enabled;
  final VoidCallback onReload;

  /// Null hides Keep Mine: without edits there is nothing of the user's to
  /// keep.
  final VoidCallback? onKeepMine;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final keepMine = onKeepMine;
    final (icon, message, actions) = switch (state) {
      DiskState.changed => (
        Icons.sync_problem_outlined,
        keepMine == null
            ? l10n.diskChanged(name)
            : l10n.diskChangedWithEdits(name),
        [
          if (keepMine != null)
            TextButton(
              onPressed: enabled ? keepMine : null,
              child: Text(l10n.diskKeepMine),
            ),
          FilledButton.tonal(
            onPressed: enabled ? onReload : null,
            child: Text(l10n.diskReload),
          ),
        ],
      ),
      DiskState.missing => (
        Icons.report_outlined,
        l10n.diskMissing(name),
        [
          FilledButton.tonal(
            onPressed: enabled ? onSave : null,
            child: Text(l10n.actionSave),
          ),
        ],
      ),
      DiskState.current => throw StateError('Nothing to tell about $name.'),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        color: scheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onTertiaryContainer),
                ),
              ),
              for (final action in actions) ...[
                const SizedBox(width: 8),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
