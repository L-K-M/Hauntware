import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show
        GhostRecoveryCodeStrings,
        GhostRestoreDialogStrings,
        showGhostRecoveryCodeDialog,
        showGhostRestoreDialog;

import '../services/secrets_recovery.dart';
import '../services/settings_backend.dart';
import '../theme.dart' show SeanceTheme;
import 'settings_layout.dart';

/// The code in Séance's monospace stack; a bare 'monospace' resolves on
/// Android only.
final _mono = TextStyle(
  fontFamily: SeanceTheme.monoFallback.first,
  fontFamilyFallback: SeanceTheme.monoFallback,
);

/// Settings > Sync > Recovery (CRED-05): a code the user writes down, an
/// encrypted export of this device's passwords and keys, and restoring one
/// here. See docs/design/cred-05-recovery.md.
class RecoverySettings extends StatefulWidget {
  const RecoverySettings({super.key, required this.backend});

  final SettingsBackend backend;

  @override
  State<RecoverySettings> createState() => _RecoverySettingsState();
}

class _RecoverySettingsState extends State<RecoverySettings> {
  /// Null until the first answer.
  bool? _configured;
  String? _message;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final configured = await widget.backend.recoveryConfigured();
      if (mounted) setState(() => _configured = configured);
    } catch (e) {
      _report('$e', failed: true);
    }
  }

  void _report(String message, {required bool failed}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _failed = failed;
    });
  }

  /// Runs [action] with the buttons disabled, and reports a failure inline.
  Future<T?> _run<T>(Future<T> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      return await action();
    } catch (e) {
      _report('$e', failed: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _setUp() async {
    if (_configured == true) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace the recovery code?'),
          content: const Text(
            'Exports made with the current code still open with it. New '
            'exports open only with the new one.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('recovery.replace.confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    final code = await _run(widget.backend.newRecoveryCode);
    if (code == null || !mounted) return;
    await showRecoveryCodeDialog(
      context,
      code,
      save: () => widget.backend.saveRecoveryCode(code),
    );
    await _reload();
  }

  Future<void> _export() async {
    final destination = await _run(widget.backend.exportSecrets);
    if (destination == null) return;
    _report(
      'Exported to $destination. It opens only with this device\'s recovery '
      'code.',
      failed: false,
    );
  }

  Future<void> _restore() async {
    final request = await showGhostRestoreDialog<RestoreConflictPolicy>(
      context,
      strings: _restoreStrings,
      codeStyle: _mono,
      keepExisting: RestoreConflictPolicy.keepExisting,
      replaceExisting: RestoreConflictPolicy.replaceExisting,
    );
    if (request == null || !mounted) return;
    final (code, policy) = request;
    final summary = await _run(
      () => widget.backend.restoreSecrets(code: code, policy: policy),
    );
    if (summary == null) return;
    _report(_describe(summary), failed: false);
  }

  static String _describe(SecretsRestoreSummary summary) {
    final parts = [
      '${summary.added} added',
      '${summary.replaced} replaced',
      '${summary.kept} kept',
      if (summary.unreadable > 0) '${summary.unreadable} could not be read',
    ];
    return 'Restored: ${parts.join(', ')}. A newer copy synced from another '
        'device still replaces a restored one.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = _configured;
    final message = _message;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(
          'Recovery',
          helpTitle: 'Recovery code',
          help:
              'A recovery code opens an encrypted export of this device\'s '
              'saved passwords and keys, on this device or another one. '
              'Séance shows the code once and cannot show it again. Without '
              'it, an export cannot be opened, by you or anyone else.',
        ),
        Text(switch (configured) {
          null => 'Checking…',
          true => 'This device has a recovery code.',
          false => 'This device has no recovery code yet.',
        }),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              key: const ValueKey('recovery.setUp'),
              onPressed: _busy || configured == null ? null : _setUp,
              child: Text(
                configured == true
                    ? 'Replace recovery code…'
                    : 'Set up recovery…',
              ),
            ),
            OutlinedButton(
              key: const ValueKey('recovery.export'),
              onPressed: _busy || configured != true ? null : _export,
              child: const Text('Export secrets…'),
            ),
            OutlinedButton(
              key: const ValueKey('recovery.restore'),
              onPressed: _busy ? null : _restore,
              child: const Text('Restore secrets…'),
            ),
          ],
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                key: const ValueKey('recovery.message'),
                style: _failed
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// Séance's words for ghost_ui's new-code dialog.
const _codeStrings = GhostRecoveryCodeStrings(
  title: 'Your recovery code',
  body:
      'Write this code down and keep it somewhere safe, away from '
      'this device. It is shown only now. With it, an export of '
      'this device\'s secrets opens anywhere; without it, nowhere. '
      'Nothing changes until you confirm.',
  copy: 'Copy code',
  copied: 'Copied',
  confirmLabel: 'Type the code\'s first four characters',
  cancel: 'Cancel',
  done: 'I saved it',
);

/// Séance's words for ghost_ui's restore dialog.
const _restoreStrings = GhostRestoreDialogStrings(
  title: 'Restore secrets',
  body:
      'Enter the recovery code of the device the export came from, '
      'then choose the export file.',
  codeLabel: 'Recovery code',
  conflictLabel: 'Credentials this device already has:',
  keep: 'Keep this device\'s',
  replace: 'Use the export\'s',
  cancel: 'Cancel',
  choose: 'Choose export…',
);

/// Shows a new recovery code once and keeps it, through [save], only after
/// the user retypes its first group (ghost_ui's
/// [showGhostRecoveryCodeDialog]); a failed save shows its error. True
/// when the code was kept.
Future<bool> showRecoveryCodeDialog(
  BuildContext context,
  String code, {
  required Future<void> Function() save,
}) => showGhostRecoveryCodeDialog(
  context,
  code,
  save: save,
  strings: _codeStrings,
  codeStyle: _mono,
  describeSaveError: (error) => '$error',
);
