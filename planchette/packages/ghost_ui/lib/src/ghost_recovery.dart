// CRED-05's recovery UI, shared by the apps that keep a vault: the
// Settings section (a code the user writes down, an encrypted export of
// this device's passwords and keys, and restoring one), the dialog that
// shows a new code once, and the dialog that asks for a restore's code
// and conflict policy. Host-neutral: each app passes its model, its
// strings, its monospace style, its restore policy values and how it
// words a failure and a restore summary.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What [GhostRecoverySection] needs of an app's recovery settings. [P] is
/// the app's restore conflict policy, [S] its restore summary.
abstract interface class GhostRecoveryModel<P, S> implements Listenable {
  /// Whether this device has a recovery code an export can use; null
  /// until the first answer.
  bool? get configured;

  /// Refetches the status, reporting a failure rather than treating it as
  /// an absent code. The section can retry this explicitly.
  Future<void> refresh();

  /// A new recovery code, formatted, to be shown once. Nothing is stored
  /// until [saveCode].
  Future<String> newCode();

  /// Keeps [code] as this device's recovery code, replacing an earlier
  /// one; exports made with that one still open with it.
  Future<void> saveCode(String code);

  /// Builds the encrypted export and saves it where the user chooses.
  /// The saved location, or null when the user cancelled.
  Future<String?> exportSecrets();

  /// Opens the chosen export with [code] and merges its credentials into
  /// this device's vault. Null when the user cancelled the file panel.
  Future<S?> restoreSecrets({required String code, required P policy});
}

/// The new-code dialog's strings, in the app's own words and language.
final class GhostRecoveryCodeStrings {
  const GhostRecoveryCodeStrings({
    required this.title,
    required this.body,
    required this.copy,
    required this.copied,
    required this.confirmLabel,
    required this.cancel,
    required this.done,
  });

  final String title;

  /// Why to write the code down, and that nothing changes until confirmed.
  final String body;

  /// The copy button's label, before and after a copy.
  final String copy;
  final String copied;

  /// The label over the field that takes the code's first group.
  final String confirmLabel;
  final String cancel;

  /// The confirming button: "I saved it".
  final String done;
}

/// The restore dialog's strings, in the app's own words and language.
final class GhostRestoreDialogStrings {
  const GhostRestoreDialogStrings({
    required this.title,
    required this.body,
    required this.codeLabel,
    required this.conflictLabel,
    required this.keep,
    required this.replace,
    required this.cancel,
    required this.choose,
  });

  final String title;

  /// What to enter, and that the export file is chosen after.
  final String body;
  final String codeLabel;

  /// The label over the conflict choice, and its two segments.
  final String conflictLabel;
  final String keep;
  final String replace;
  final String cancel;

  /// The confirming button, which goes on to the file panel.
  final String choose;
}

/// [GhostRecoverySection]'s strings, in the app's own words and language.
final class GhostRecoveryStrings {
  const GhostRecoveryStrings({
    required this.title,
    required this.description,
    required this.checking,
    required this.configured,
    required this.notConfigured,
    required this.retry,
    required this.setUp,
    required this.replace,
    required this.export,
    required this.restore,
    required this.replaceTitle,
    required this.replaceBody,
    required this.replaceCancel,
    required this.replaceConfirm,
    required this.exportDone,
    required this.code,
    required this.restoreDialog,
  });

  /// The section heading and the line under it.
  final String title;
  final String description;

  /// The status line while the first answer is out, and after it.
  final String checking;
  final String configured;
  final String notConfigured;

  /// The button that retries a failed status read.
  final String retry;

  /// The set-up button's label without a code, and with one.
  final String setUp;
  final String replace;

  /// The export and restore buttons' labels.
  final String export;
  final String restore;

  /// The confirmation before a new code replaces the current one.
  final String replaceTitle;
  final String replaceBody;
  final String replaceCancel;
  final String replaceConfirm;

  /// The note after an export was saved at `destination`.
  final String Function(String destination) exportDone;

  final GhostRecoveryCodeStrings code;
  final GhostRestoreDialogStrings restoreDialog;
}

/// Settings' Recovery section (CRED-05) over [model]: whether this device
/// has a code, with a retry when that could not be read, and the set-up,
/// export and restore actions, each reporting its result inline.
class GhostRecoverySection<P, S> extends StatefulWidget {
  const GhostRecoverySection({
    super.key,
    required this.model,
    required this.strings,
    required this.codeStyle,
    required this.keepExisting,
    required this.replaceExisting,
    required this.describeError,
    required this.describeStatusError,
    required this.describeSaveError,
    required this.describeRestore,
  });

  final GhostRecoveryModel<P, S> model;
  final GhostRecoveryStrings strings;

  /// The app's monospace style, for the code and the fields that take it.
  final TextStyle codeStyle;

  /// The app's restore policy values for the restore dialog's choice.
  final P keepExisting;
  final P replaceExisting;

  /// The inline sentence for an action that failed with `error`.
  final String Function(Object error) describeError;

  /// The status line for a status read that failed with `error`.
  final String Function(Object error) describeStatusError;

  /// The new-code dialog's line for a save that failed with `error`.
  final String Function(Object error) describeSaveError;

  /// The inline note after a restore.
  final String Function(S summary) describeRestore;

  @override
  State<GhostRecoverySection<P, S>> createState() =>
      _GhostRecoverySectionState<P, S>();
}

class _GhostRecoverySectionState<P, S>
    extends State<GhostRecoverySection<P, S>> {
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
  void didUpdateWidget(GhostRecoverySection<P, S> oldWidget) {
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
      if (mounted) _report(widget.describeError(error), failed: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setUp() async {
    final strings = widget.strings;
    if (widget.model.configured == true) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.replaceTitle),
          content: Text(strings.replaceBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(strings.replaceCancel),
            ),
            FilledButton(
              key: const ValueKey('recovery.replace.confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(strings.replaceConfirm),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    final code = await _run(widget.model.newCode);
    if (code == null || !mounted) return;
    await showGhostRecoveryCodeDialog(
      context,
      code,
      save: () => widget.model.saveCode(code),
      strings: strings.code,
      codeStyle: widget.codeStyle,
      describeSaveError: widget.describeSaveError,
    );
  }

  Future<void> _export() async {
    final destination = await _run(widget.model.exportSecrets);
    if (destination == null) return;
    _report(widget.strings.exportDone(destination), failed: false);
  }

  Future<void> _restore() async {
    final request = await showGhostRestoreDialog<P>(
      context,
      strings: widget.strings.restoreDialog,
      codeStyle: widget.codeStyle,
      keepExisting: widget.keepExisting,
      replaceExisting: widget.replaceExisting,
    );
    if (request == null || !mounted) return;
    final (code, policy) = request;
    final summary = await _run(
      () => widget.model.restoreSecrets(code: code, policy: policy),
    );
    if (summary == null) return;
    _report(widget.describeRestore(summary), failed: false);
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    final configured = widget.model.configured;
    final statusError = _statusError;
    final message = _message;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(strings.title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(strings.description, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (statusError == null)
          Text(switch (configured) {
            null => strings.checking,
            true => strings.configured,
            false => strings.notConfigured,
          })
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.describeStatusError(statusError),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
              TextButton(
                key: const ValueKey('recovery.status.retry'),
                onPressed: _busy ? null : _refreshStatus,
                child: Text(strings.retry),
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
              child: Text(configured == true ? strings.replace : strings.setUp),
            ),
            OutlinedButton(
              key: const ValueKey('recovery.export'),
              onPressed: _busy || statusError != null || configured != true
                  ? null
                  : _export,
              child: Text(strings.export),
            ),
            OutlinedButton(
              key: const ValueKey('recovery.restore'),
              onPressed: _busy ? null : _restore,
              child: Text(strings.restore),
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
/// earlier code stays. True when the code was kept. A save that fails
/// shows [describeSaveError]'s line and keeps the dialog open.
Future<bool> showGhostRecoveryCodeDialog(
  BuildContext context,
  String code, {
  required Future<void> Function() save,
  required GhostRecoveryCodeStrings strings,
  required TextStyle codeStyle,
  required String Function(Object error) describeSaveError,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecoveryCodeDialog(
        code: code,
        save: save,
        strings: strings,
        codeStyle: codeStyle,
        describeSaveError: describeSaveError,
      ),
    ) ??
    false;

class _RecoveryCodeDialog extends StatefulWidget {
  const _RecoveryCodeDialog({
    required this.code,
    required this.save,
    required this.strings,
    required this.codeStyle,
    required this.describeSaveError,
  });

  final String code;
  final Future<void> Function() save;
  final GhostRecoveryCodeStrings strings;
  final TextStyle codeStyle;
  final String Function(Object error) describeSaveError;

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
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = widget.describeSaveError(error);
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
    final strings = widget.strings;
    final error = _error;
    // Only Cancel or "I saved it" close it: Esc or back would drop a
    // code the user may not have written down yet.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(strings.title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.body),
                const SizedBox(height: 12),
                SelectableText(
                  widget.code,
                  key: const ValueKey('recovery.code'),
                  style: widget.codeStyle,
                ),
                TextButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(_copied ? strings.copied : strings.copy),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('recovery.code.confirm'),
                  controller: _confirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  style: widget.codeStyle,
                  decoration: InputDecoration(labelText: strings.confirmLabel),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_confirmed && !_saving) unawaited(_keep());
                  },
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
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
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('recovery.code.done'),
            onPressed: _confirmed && !_saving ? _keep : null,
            child: Text(strings.done),
          ),
        ],
      ),
    );
  }
}

/// Asks for the recovery code and what to do with credentials this
/// device already has, one of [keepExisting] and [replaceExisting]
/// (the first preselected); the export file is chosen after, by the
/// caller. Null when cancelled.
Future<(String, P)?> showGhostRestoreDialog<P>(
  BuildContext context, {
  required GhostRestoreDialogStrings strings,
  required TextStyle codeStyle,
  required P keepExisting,
  required P replaceExisting,
}) => showDialog<(String, P)>(
  context: context,
  builder: (_) => _RestoreDialog<P>(
    strings: strings,
    codeStyle: codeStyle,
    keepExisting: keepExisting,
    replaceExisting: replaceExisting,
  ),
);

class _RestoreDialog<P> extends StatefulWidget {
  const _RestoreDialog({
    required this.strings,
    required this.codeStyle,
    required this.keepExisting,
    required this.replaceExisting,
  });

  final GhostRestoreDialogStrings strings;
  final TextStyle codeStyle;
  final P keepExisting;
  final P replaceExisting;

  @override
  State<_RestoreDialog<P>> createState() => _RestoreDialogState<P>();
}

class _RestoreDialogState<P> extends State<_RestoreDialog<P>> {
  final _code = TextEditingController();
  late P _policy = widget.keepExisting;

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
    final strings = widget.strings;
    final code = _code.text.trim();
    return AlertDialog(
      title: Text(strings.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.body),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('recovery.restore.code'),
              controller: _code,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              style: widget.codeStyle,
              decoration: InputDecoration(labelText: strings.codeLabel),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _choose(),
            ),
            const SizedBox(height: 12),
            Text(strings.conflictLabel),
            const SizedBox(height: 4),
            SegmentedButton<P>(
              segments: [
                ButtonSegment(
                  value: widget.keepExisting,
                  label: Text(strings.keep),
                ),
                ButtonSegment(
                  value: widget.replaceExisting,
                  label: Text(strings.replace),
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
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('recovery.restore.choose'),
          onPressed: code.isEmpty ? null : _choose,
          child: Text(strings.choose),
        ),
      ],
    );
  }
}
