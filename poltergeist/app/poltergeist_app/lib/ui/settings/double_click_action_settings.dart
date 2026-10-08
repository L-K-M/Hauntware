import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/double_click_action.dart';
import '../../services/settings_models.dart';
import '../top_toast.dart';

/// Settings → Editing's Opening files row (06 §8): the Double-click action
/// dropdown, 02 §2.6's four choices. Every pane's next file open follows a
/// change.
class DoubleClickActionSection extends StatefulWidget {
  const DoubleClickActionSection({super.key, required this.model});

  final DoubleClickActionModel model;

  @override
  State<DoubleClickActionSection> createState() =>
      _DoubleClickActionSectionState();
}

class _DoubleClickActionSectionState extends State<DoubleClickActionSection> {
  /// What the dropdown shows from a choice until the model shows it. In the
  /// Settings window the model trails each write by a round trip to the
  /// app, so the dropdown would otherwise flick back and forth.
  DoubleClickAction? _pending;

  /// Counts [_write] calls: only the newest may hand the dropdown back or
  /// report a failure, since each write carries every earlier one.
  int _writes = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_modelChanged);
  }

  @override
  void didUpdateWidget(DoubleClickActionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.model, widget.model)) return;
    oldWidget.model.removeListener(_modelChanged);
    widget.model.addListener(_modelChanged);
  }

  @override
  void dispose() {
    widget.model.removeListener(_modelChanged);
    super.dispose();
  }

  void _modelChanged() {
    if (_pending == null || widget.model.value != _pending) return;
    setState(() => _pending = null);
  }

  Future<void> _write(DoubleClickAction action) async {
    final write = ++_writes;
    setState(() => _pending = action);
    try {
      await widget.model.setAction(action);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!mounted || write != _writes) return;
      // Show what the panes follow: the model keeps a change it could not
      // save, and the next write carries it.
      setState(() => _pending = null);
      showTopToastIn(context, message: error.toString());
    }
  }

  String _label(AppLocalizations l10n, DoubleClickAction action) =>
      switch (action) {
        DoubleClickAction.open => l10n.doubleClickActionOpen,
        DoubleClickAction.edit => l10n.doubleClickActionEdit,
        DoubleClickAction.transfer => l10n.doubleClickActionTransfer,
        DoubleClickAction.nothing => l10n.doubleClickActionNothing,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.settingsOpeningFilesSection,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Text(l10n.doubleClickActionLabel)),
              DropdownButton<DoubleClickAction>(
                key: const ValueKey('editing.doubleClickAction'),
                value: _pending ?? widget.model.value,
                items: [
                  for (final action in DoubleClickAction.values)
                    DropdownMenuItem(
                      value: action,
                      child: Text(_label(l10n, action)),
                    ),
                ],
                onChanged: (action) {
                  if (action == null) return;
                  unawaited(_write(action));
                },
              ),
            ],
          ),
          Text(
            l10n.doubleClickActionSubtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
