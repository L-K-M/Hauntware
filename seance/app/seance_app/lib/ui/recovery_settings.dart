import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/secrets_recovery.dart';
import '../services/settings_backend.dart';
import 'settings_layout.dart';

const _mono = TextStyle(fontFamily: 'monospace');

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
    final request = await showDialog<(String, RestoreConflictPolicy)>(
      context: context,
      builder: (_) => const _RestoreDialog(),
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

/// Shows a new recovery code once and keeps it, through [save], only after
/// the user retypes its first group: a check they wrote it down before it is
/// gone. The first group is part of the key itself, unlike the last, which
/// is the checksum. Cancelling keeps nothing, so an earlier code stays.
/// True when the code was kept.
Future<bool> showRecoveryCodeDialog(
  BuildContext context,
  String code, {
  required Future<void> Function() save,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecoveryCodeDialog(code: code, save: save),
    ) ??
    false;

class _RecoveryCodeDialog extends StatefulWidget {
  const _RecoveryCodeDialog({required this.code, required this.save});

  final String code;
  final Future<void> Function() save;

  @override
  State<_RecoveryCodeDialog> createState() => _RecoveryCodeDialogState();
}

class _RecoveryCodeDialogState extends State<_RecoveryCodeDialog> {
  final _confirmation = TextEditingController();
  bool _copied = false;
  bool _saving = false;
  String? _error;

  String get _firstGroup => widget.code.split('-').first;

  bool get _confirmed =>
      _confirmation.text.trim().toUpperCase() == _firstGroup.toUpperCase();

  Future<void> _keep() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Your recovery code'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Write this code down and keep it somewhere safe, away from '
                'this device. It is shown only now. With it, an export of '
                'this device\'s secrets opens anywhere; without it, nowhere. '
                'Nothing changes until you confirm.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                widget.code,
                key: const ValueKey('recovery.code'),
                style: _mono,
              ),
              TextButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy, size: 16),
                label: Text(_copied ? 'Copied' : 'Copy code'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('recovery.code.confirm'),
                controller: _confirmation,
                autocorrect: false,
                enableSuggestions: false,
                style: _mono,
                decoration: const InputDecoration(
                  labelText: 'Type the code\'s first four characters',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('recovery.code.cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('recovery.code.done'),
          onPressed: _confirmed && !_saving ? _keep : null,
          child: const Text('I saved it'),
        ),
      ],
    );
  }
}

/// Asks for the recovery code and what to do with credentials this device
/// already has; the export file is chosen after.
class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog();

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _code = TextEditingController();
  RestoreConflictPolicy _policy = RestoreConflictPolicy.keepExisting;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final code = _code.text.trim();
    return AlertDialog(
      title: const Text('Restore secrets'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the recovery code of the device the export came from, '
              'then choose the export file.',
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('recovery.restore.code'),
              controller: _code,
              autocorrect: false,
              enableSuggestions: false,
              style: _mono,
              decoration: const InputDecoration(labelText: 'Recovery code'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            const Text('Credentials this device already has:'),
            const SizedBox(height: 4),
            SegmentedButton<RestoreConflictPolicy>(
              segments: const [
                ButtonSegment(
                  value: RestoreConflictPolicy.keepExisting,
                  label: Text('Keep this device\'s'),
                ),
                ButtonSegment(
                  value: RestoreConflictPolicy.replaceExisting,
                  label: Text('Use the export\'s'),
                ),
              ],
              selected: {_policy},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  setState(() => _policy = selection.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('recovery.restore.choose'),
          onPressed: code.isEmpty
              ? null
              : () => Navigator.pop(context, (code, _policy)),
          child: const Text('Choose export…'),
        ),
      ],
    );
  }
}
