// Settings → Backup → Recovery (CRED-05): a code the user writes down,
// an encrypted export of this device's passwords and keys, and restoring
// one here. The section shows whether or not this device has a code, and
// whether or not the backup account is enrolled. The store-level crypto
// is seance_core's VaultRecovery through the app's SecretsRecovery.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/secrets_recovery.dart';
import '../../services/settings_models.dart';
import '../../theme/app_theme.dart' show poltergeistMonoTextStyle;

/// The Recovery section's live state and actions, over [RecoverySettingsModel].
class RecoverySection extends StatefulWidget {
  const RecoverySection({super.key, required this.model});

  final RecoverySettingsModel model;

  @override
  State<RecoverySection> createState() => _RecoverySectionState();
}

class _RecoverySectionState extends State<RecoverySection> {
  String? _message;
  bool _failed = false;
  bool _busy = false;
  Object? _statusError;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_modelChanged);
    if (widget.model.configured == null) unawaited(_refreshStatus());
  }

  @override
  void didUpdateWidget(RecoverySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.model, widget.model)) return;
    oldWidget.model.removeListener(_modelChanged);
    widget.model.addListener(_modelChanged);
    _busy = false;
    _statusError = null;
    if (widget.model.configured == null) unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    widget.model.removeListener(_modelChanged);
    super.dispose();
  }

  void _modelChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshStatus() async {
    final model = widget.model;
    setState(() {
      _busy = true;
      _statusError = null;
    });
    try {
      await model.refresh();
    } on Object catch (error) {
      if (mounted && identical(model, widget.model)) {
        setState(() => _statusError = error);
      }
    } finally {
      if (mounted && identical(model, widget.model)) {
        setState(() => _busy = false);
      }
    }
  }

  void _report(String message, {required bool failed}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _failed = failed;
    });
  }

  /// Runs [action] with the buttons disabled, and reports a failure
  /// inline. The model reloads its own configured flag after each
  /// action, which notifies this section.
  Future<T?> _run<T>(Future<T> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      return await action();
    } on Object catch (error) {
      if (mounted) _report(_describeError(error), failed: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describeError(Object error) {
    final l10n = AppLocalizations.of(context);
    return switch (error) {
      SecretsExportException(:final failure) => secretsExportFailureMessage(
        failure,
        l10n,
      ),
      RecoveryStatusException() => l10n.recoveryStatusFailed,
      _ => l10n.recoveryFailed,
    };
  }

  Future<void> _setUp() async {
    if (widget.model.configured == true) {
      final l10n = AppLocalizations.of(context);
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.recoveryReplaceTitle),
          content: Text(l10n.recoveryReplaceBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.recoveryCancel),
            ),
            FilledButton(
              key: const ValueKey('recovery.replace.confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.recoveryReplaceConfirm),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    final code = await _run(widget.model.newCode);
    if (code == null || !mounted) return;
    await showRecoveryCodeDialog(
      context,
      code,
      save: () => widget.model.saveCode(code),
    );
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    final destination = await _run(widget.model.exportSecrets);
    if (destination == null) return;
    _report(l10n.recoveryExportDone(destination), failed: false);
  }

  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context);
    final request = await showDialog<(String, RestoreConflictPolicy)>(
      context: context,
      builder: (_) => const _RestoreDialog(),
    );
    if (request == null || !mounted) return;
    final (code, policy) = request;
    final summary = await _run(
      () => widget.model.restoreSecrets(code: code, policy: policy),
    );
    if (summary == null) return;
    _report(_describe(l10n, summary), failed: false);
  }

  String _describe(AppLocalizations l10n, SecretsRestoreSummary summary) {
    final parts = [
      l10n.recoveryRestoreAdded(summary.added),
      l10n.recoveryRestoreReplaced(summary.replaced),
      l10n.recoveryRestoreKept(summary.kept),
      if (summary.unreadable > 0)
        l10n.recoveryRestoreUnreadable(summary.unreadable),
    ];
    return l10n.recoveryRestoreSummary(parts.join(', '));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final configured = widget.model.configured;
    final statusError = _statusError;
    final message = _message;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.recoveryTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(l10n.recoveryDescription, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (statusError == null)
          Text(switch (configured) {
            null => l10n.recoveryChecking,
            true => l10n.recoveryConfigured,
            false => l10n.recoveryNotConfigured,
          })
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.recoveryStatusFailed,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
              TextButton(
                key: const ValueKey('recovery.status.retry'),
                onPressed: _busy ? null : _refreshStatus,
                child: Text(l10n.recoveryRetry),
              ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              key: const ValueKey('recovery.setUp'),
              onPressed: _busy || statusError != null || configured == null
                  ? null
                  : _setUp,
              child: Text(
                configured == true ? l10n.recoveryReplace : l10n.recoverySetUp,
              ),
            ),
            OutlinedButton(
              key: const ValueKey('recovery.export'),
              onPressed: _busy || statusError != null || configured != true
                  ? null
                  : _export,
              child: Text(l10n.recoveryExport),
            ),
            OutlinedButton(
              key: const ValueKey('recovery.restore'),
              onPressed: _busy ? null : _restore,
              child: Text(l10n.recoveryRestore),
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

/// Shows a new recovery code once and keeps it, through [save], only
/// after the user retypes its first group: a check they wrote it down
/// before it is gone. The first group is part of the key itself, unlike
/// the last, which is the checksum. Cancelling keeps nothing, so an
/// earlier code stays. True when the code was kept.
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
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = AppLocalizations.of(context).recoveryFailed;
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
    final l10n = AppLocalizations.of(context);
    // Only Cancel or "I saved it" close it: Esc or back would drop a
    // code the user may not have written down yet.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l10n.recoveryCodeTitle),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.recoveryCodeBody),
                const SizedBox(height: 12),
                SelectableText(
                  widget.code,
                  key: const ValueKey('recovery.code'),
                  style: poltergeistMonoTextStyle,
                ),
                TextButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(
                    _copied ? l10n.recoveryCodeCopied : l10n.recoveryCodeCopy,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('recovery.code.confirm'),
                  controller: _confirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  style: poltergeistMonoTextStyle,
                  decoration: InputDecoration(
                    labelText: l10n.recoveryCodeConfirmLabel,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_confirmed && !_saving) unawaited(_keep());
                  },
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
            child: Text(l10n.recoveryCodeCancel),
          ),
          FilledButton(
            key: const ValueKey('recovery.code.done'),
            onPressed: _confirmed && !_saving ? _keep : null,
            child: Text(l10n.recoveryCodeDone),
          ),
        ],
      ),
    );
  }
}

/// Asks for the recovery code and what to do with credentials this
/// device already has; the export file is chosen after, in the app's
/// isolate where the file panel lives.
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

  void _choose() {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    Navigator.pop(context, (code, _policy));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final code = _code.text.trim();
    return AlertDialog(
      title: Text(l10n.recoveryRestoreTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.recoveryRestoreBody),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('recovery.restore.code'),
              controller: _code,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              style: poltergeistMonoTextStyle,
              decoration: InputDecoration(
                labelText: l10n.recoveryRestoreCodeLabel,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _choose(),
            ),
            const SizedBox(height: 12),
            Text(l10n.recoveryRestoreConflictLabel),
            const SizedBox(height: 4),
            SegmentedButton<RestoreConflictPolicy>(
              segments: [
                ButtonSegment(
                  value: RestoreConflictPolicy.keepExisting,
                  label: Text(l10n.recoveryRestoreKeep),
                ),
                ButtonSegment(
                  value: RestoreConflictPolicy.replaceExisting,
                  label: Text(l10n.recoveryRestoreReplace),
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
          child: Text(l10n.recoveryCancel),
        ),
        FilledButton(
          key: const ValueKey('recovery.restore.choose'),
          onPressed: code.isEmpty ? null : _choose,
          child: Text(l10n.recoveryRestoreChoose),
        ),
      ],
    );
  }
}
