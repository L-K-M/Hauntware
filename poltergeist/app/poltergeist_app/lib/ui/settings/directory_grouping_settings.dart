import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show DirectoryGrouping;

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/settings_models.dart';
import '../top_toast.dart';

/// Settings → General's file-list row: whether folders stay on top or sort
/// in among files. Every open pane re-sorts as it changes.
class DirectoryGroupingSection extends StatefulWidget {
  const DirectoryGroupingSection({super.key, required this.model});

  final DirectoryGroupingModel model;

  @override
  State<DirectoryGroupingSection> createState() =>
      _DirectoryGroupingSectionState();
}

class _DirectoryGroupingSectionState extends State<DirectoryGroupingSection> {
  /// What the switch shows from a flip until the model shows it. In the
  /// Settings window the model trails each write by a round trip to the
  /// app, so the switch would otherwise flick back and forth.
  DirectoryGrouping? _pending;

  /// Counts [_write] calls: only the newest may hand the switch back or
  /// report a failure, since each write carries every earlier one.
  int _writes = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_modelChanged);
  }

  @override
  void didUpdateWidget(DirectoryGroupingSection oldWidget) {
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

  Future<void> _write(DirectoryGrouping grouping) async {
    final write = ++_writes;
    setState(() => _pending = grouping);
    try {
      await widget.model.setGrouping(grouping);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!mounted || write != _writes) return;
      // Show what the panes sort by: the model keeps a change it could not
      // save, and the next write carries it.
      setState(() => _pending = null);
      showTopToastIn(context, message: error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final grouping = _pending ?? widget.model.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsFileListsSection,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SwitchListTile(
              key: const ValueKey('view.foldersOnTop'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.foldersOnTopLabel),
              subtitle: Text(l10n.foldersOnTopSubtitle),
              value: grouping == DirectoryGrouping.first,
              onChanged: (onTop) => unawaited(
                _write(
                  onTop ? DirectoryGrouping.first : DirectoryGrouping.mixed,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
