import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_batch_rename.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_location.dart' show paneLastSegment;
import '../../services/pane_rename.dart' show RenameNameError;
import '../compact/compact_pane_messages.dart' show compactRenameErrorText;
import '../compact/compact_posture.dart' show compactPostureApplies;

/// The widget keys Rename Items exposes to tests. Enum-valued like
/// `CompactKey`: plumbing, never copy. Preview rows pair the value with
/// their index: `ValueKey((BatchRenameKey.row, index))`.
enum BatchRenameKey {
  dialog,
  mode,
  find,
  replace,
  matchCase,
  includeExtension,
  addText,
  addPlacement,
  formatName,
  formatPlacement,
  startAt,
  summary,
  preview,
  row,
  progress,
  confirm,
  cancel,
  stop,
  done,
}

/// Opens Rename Items (02 §2.6) on [pane]'s selection: the rule editor
/// and live preview, then the run's progress and, unless every item
/// renamed, its outcome. Does nothing when the pane refuses to start a
/// session. The dialog never strands a session: leaving it closes the
/// session, and a run cut off by a route removal stops and closes once
/// it settles.
Future<void> showBatchRenameDialog(
  BuildContext context, {
  required PaneController pane,
}) async {
  if (!pane.startBatchRename()) return;
  final session = pane.batchRename!;
  final fullscreen = compactPostureApplies(
    width: MediaQuery.sizeOf(context).width,
    platform: Theme.of(context).platform,
  );
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BatchRenameDialog(
        pane: pane,
        session: session,
        fullscreen: fullscreen,
      ),
    );
  } finally {
    if (identical(pane.batchRename, session)) {
      if (session.stage == BatchRenameStage.running) {
        pane.stopBatchRename();
        void closeWhenSettled() {
          if (session.stage == BatchRenameStage.running) return;
          session.removeListener(closeWhenSettled);
          if (identical(pane.batchRename, session)) pane.closeBatchRename();
        }

        session.addListener(closeWhenSettled);
      } else {
        pane.closeBatchRename();
      }
    }
  }
}

/// The Rename Items surface. Public for widget tests; open it through
/// [showBatchRenameDialog].
class BatchRenameDialog extends StatefulWidget {
  const BatchRenameDialog({
    super.key,
    required this.pane,
    required this.session,
    this.fullscreen = false,
  });

  final PaneController pane;
  final BatchRenameSession session;

  /// The compact (phone) posture: a full-screen page instead of a card.
  final bool fullscreen;

  @override
  State<BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<BatchRenameDialog> {
  BatchRenameMode _mode = BatchRenameMode.replaceText;
  final _find = TextEditingController();
  final _replace = TextEditingController();
  final _addText = TextEditingController();
  final _formatName = TextEditingController();
  final _startAt = TextEditingController(text: '1');
  bool _matchCase = true;
  bool _includeExtension = false;
  BatchRenamePlacement _addPlacement = BatchRenamePlacement.afterName;
  BatchRenamePlacement _formatPlacement = BatchRenamePlacement.afterName;
  final _preview = ScrollController();

  /// The first field of the current mode, focused after a mode change.
  final _firstField = FocusNode();

  /// Stop while running, Done once finished: focused on each stage change
  /// so Esc, Return and Space act on the dialog, not on the mode picker
  /// (whose closed menu would swallow Esc).
  final _actionFocus = FocusNode();
  BatchRenameStage? _focusedStage;

  /// This dialog's route has popped (or is popping); nothing pops twice.
  bool _popped = false;
  bool _popScheduled = false;

  BatchRenameSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    for (final field in [_find, _replace, _addText, _formatName, _startAt]) {
      field.addListener(_onField);
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    for (final field in [_find, _replace, _addText, _formatName, _startAt]) {
      field.dispose();
    }
    _preview.dispose();
    _firstField.dispose();
    _actionFocus.dispose();
    super.dispose();
  }

  void _onField() => setState(() {});

  void _onSession() {
    final session = _session;
    if (session.stage == BatchRenameStage.finished && _allRenamed(session)) {
      // Full success needs no result view: the reselected rows are the
      // outcome, as with inline rename.
      widget.pane.closeBatchRename();
      return;
    }
    if (session.stage == BatchRenameStage.ended) {
      _schedulePop();
      return;
    }
    if (!mounted) return;
    setState(() {});
    final stage = session.stage;
    if (stage != BatchRenameStage.editing && stage != _focusedStage) {
      _focusedStage = stage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _actionFocus.requestFocus();
      });
    }
  }

  static bool _allRenamed(BatchRenameSession session) {
    final plan = session.runPlan;
    return session.stop == BatchRenameStop.completed &&
        plan != null &&
        session.renamedCount == plan.renameCount;
  }

  /// Pops this dialog after the current frame, once the session ended.
  /// The session can end from inside another widget's teardown (a closing
  /// tab), where navigating at once would rebuild mid-frame. While another
  /// route covers the dialog (the macOS menu bar stays live under it), the
  /// pop waits: build depends on the route's status and re-arms it when
  /// the dialog is on top again, so it never closes the wrong route and
  /// never strands an ended dialog.
  void _schedulePop() {
    if (_popped || _popScheduled) return;
    _popScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _popScheduled = false;
      if (!mounted || _popped) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      _popped = true;
      Navigator.of(context).pop();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// The rule the fields describe; null while "Start numbers at" is not
  /// a whole number in range.
  BatchRenameRule? get _rule => switch (_mode) {
    BatchRenameMode.replaceText => ReplaceTextRule(
      find: _find.text,
      replacement: _replace.text,
      matchCase: _matchCase,
      includeExtension: _includeExtension,
    ),
    BatchRenameMode.addText => AddTextRule(
      text: _addText.text,
      placement: _addPlacement,
    ),
    BatchRenameMode.format => switch (_startAtValue) {
      null => null,
      final startAt => FormatRule(
        name: _formatName.text,
        placement: _formatPlacement,
        startAt: startAt,
      ),
    },
  };

  int? get _startAtValue {
    final text = _startAt.text;
    if (text.isEmpty || text.length > 6) return null;
    final value = int.tryParse(text);
    if (value == null || value < 0 || value > batchRenameMaxStartAt) {
      return null;
    }
    return value;
  }

  BatchRenamePlan? _editingPlan() {
    final rule = _rule;
    return rule == null ? null : planBatchRename(_session.snapshot, rule);
  }

  Future<void> _submit() async {
    final rule = _rule;
    if (rule == null || _session.stage != BatchRenameStage.editing) return;
    if (!planBatchRename(_session.snapshot, rule).runnable) return;
    await widget.pane.runBatchRename(rule);
  }

  /// Cancel, Stop, Done, Esc and the compact close button: stops a run,
  /// closes the session otherwise, and pops a dialog whose session
  /// already ended.
  void _cancel() {
    switch (_session.stage) {
      case BatchRenameStage.running:
        widget.pane.stopBatchRename();
      case BatchRenameStage.editing:
      case BatchRenameStage.finished:
        widget.pane.closeBatchRename();
      case BatchRenameStage.ended:
        _schedulePop();
    }
  }

  void _jumpToFirstProblem(BatchRenamePlan plan) {
    final index = plan.firstBlockedRow;
    if (index == null || !_preview.hasClients) return;
    _preview.animateTo(
      (index * _rowExtent(context)).clamp(0, _preview.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// One preview row: two text lines and padding, grown with the text
  /// scale so a problem line never clips (D20).
  double _rowExtent(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final padding = widget.fullscreen ? 20.0 : 12.0;
    return padding + scaler.scale(20) + scaler.scale(16);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stage = _session.stage;
    // Depends on the route's status, so the dialog rebuilds (and an
    // ended session's pop re-arms) when it is on top again.
    ModalRoute.of(context);
    if (stage == BatchRenameStage.ended) _schedulePop();
    final editing = stage == BatchRenameStage.editing;
    final plan = editing ? _editingPlan() : _session.runPlan;
    final title = l10n.batchRenameTitle(_session.snapshot.targets.length);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modePicker(l10n, enabled: editing),
        const SizedBox(height: 12),
        ..._fields(l10n, enabled: editing),
        const SizedBox(height: 12),
        _summary(context, l10n, plan),
        const SizedBox(height: 8),
        Expanded(child: _previewList(context, l10n, plan)),
      ],
    );

    final actions = _actions(l10n, plan);
    final content = PopScope(
      // Esc and Back stop a running batch; they never close mid-run.
      canPop: stage != BatchRenameStage.running,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _popped = true;
        } else {
          widget.pane.stopBatchRename();
        }
      },
      // Esc arrives as the app's DismissIntent. The modal route ignores
      // it because the barrier is not dismissible, so the dialog answers
      // it: cancel while editing, stop a run, close a result.
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _cancel();
              return null;
            },
          ),
        },
        // Esc as a key, too: a focused descendant that maps Esc to its
        // own disabled action (the mode picker's closed menu) lets the key
        // through unhandled, and it reaches this handler. Disabling the
        // fields mid-run moves focus out of them; the scope keeps it
        // inside the dialog rather than on the route's scope.
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent ||
                event.logicalKey != LogicalKeyboardKey.escape) {
              return KeyEventResult.ignored;
            }
            _cancel();
            return KeyEventResult.handled;
          },
          child: FocusScope(
            child: widget.fullscreen
                ? _fullscreen(context, title, body, actions)
                : _card(context, title, body, actions),
          ),
        ),
      ),
    );
    return KeyedSubtree(
      key: const ValueKey(BatchRenameKey.dialog),
      child: content,
    );
  }

  Widget _card(
    BuildContext context,
    String title,
    Widget body,
    List<Widget> actions,
  ) {
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Flexible(child: body),
              const SizedBox(height: 16),
              _actionBar(actions),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fullscreen(
    BuildContext context,
    String title,
    Widget body,
    List<Widget> actions,
  ) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: _session.stage == BatchRenameStage.finished
              ? null
              : CloseButton(onPressed: _cancel),
          automaticallyImplyLeading: false,
          title: Text(title),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: body),
                const SizedBox(height: 8),
                _actionBar(actions),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The dialog's buttons, end-aligned; they stack rather than overflow
  /// when a narrow window or a long translation cannot fit them in a row.
  Widget _actionBar(List<Widget> actions) => OverflowBar(
    alignment: MainAxisAlignment.end,
    overflowAlignment: OverflowBarAlignment.end,
    spacing: 8,
    overflowSpacing: 8,
    children: actions,
  );

  Widget _modePicker(AppLocalizations l10n, {required bool enabled}) {
    return DropdownMenu<BatchRenameMode>(
      key: const ValueKey(BatchRenameKey.mode),
      enabled: enabled,
      initialSelection: _mode,
      label: Text(l10n.batchRenameModeLabel),
      expandedInsets: EdgeInsets.zero,
      requestFocusOnTap: false,
      onSelected: (mode) {
        if (mode == null) return;
        setState(() => _mode = mode);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _firstField.requestFocus();
        });
      },
      dropdownMenuEntries: [
        DropdownMenuEntry(
          value: BatchRenameMode.replaceText,
          label: l10n.batchRenameModeReplaceText,
        ),
        DropdownMenuEntry(
          value: BatchRenameMode.addText,
          label: l10n.batchRenameModeAddText,
        ),
        DropdownMenuEntry(
          value: BatchRenameMode.format,
          label: l10n.batchRenameModeFormat,
        ),
      ],
    );
  }

  List<Widget> _fields(AppLocalizations l10n, {required bool enabled}) {
    TextField field(
      BatchRenameKey key,
      TextEditingController controller,
      String label, {
      String? hint,
      String? error,
      bool autofocus = false,
      List<TextInputFormatter>? formatters,
      TextInputType? keyboardType,
    }) => TextField(
      key: ValueKey(key),
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      focusNode: autofocus ? _firstField : null,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      // Return submits but keeps focus in the field: the default would
      // park focus on the route's scope.
      onEditingComplete: () {},
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: error,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );

    Widget placement(
      BatchRenameKey key,
      BatchRenamePlacement value,
      ValueChanged<BatchRenamePlacement> onChanged,
    ) => DropdownMenu<BatchRenamePlacement>(
      key: ValueKey(key),
      enabled: enabled,
      initialSelection: value,
      label: Text(l10n.batchRenamePlacementLabel),
      expandedInsets: EdgeInsets.zero,
      requestFocusOnTap: false,
      onSelected: (placement) {
        if (placement != null) setState(() => onChanged(placement));
      },
      dropdownMenuEntries: [
        DropdownMenuEntry(
          value: BatchRenamePlacement.afterName,
          label: l10n.batchRenamePlacementAfterName,
        ),
        DropdownMenuEntry(
          value: BatchRenamePlacement.beforeName,
          label: l10n.batchRenamePlacementBeforeName,
        ),
      ],
    );

    Widget check(
      BatchRenameKey key,
      String label,
      bool value,
      ValueChanged<bool> onChanged,
    ) => CheckboxListTile(
      key: ValueKey(key),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label),
      value: value,
      onChanged: enabled
          ? (checked) => setState(() => onChanged(checked ?? false))
          : null,
    );

    const gap = SizedBox(height: 8);
    return switch (_mode) {
      BatchRenameMode.replaceText => [
        field(
          BatchRenameKey.find,
          _find,
          l10n.batchRenameFindLabel,
          autofocus: true,
        ),
        gap,
        field(
          BatchRenameKey.replace,
          _replace,
          l10n.batchRenameReplaceWithLabel,
        ),
        check(
          BatchRenameKey.matchCase,
          l10n.batchRenameMatchCase,
          _matchCase,
          (value) => _matchCase = value,
        ),
        check(
          BatchRenameKey.includeExtension,
          l10n.batchRenameIncludeExtension,
          _includeExtension,
          (value) => _includeExtension = value,
        ),
      ],
      BatchRenameMode.addText => [
        field(
          BatchRenameKey.addText,
          _addText,
          l10n.batchRenameAddTextLabel,
          autofocus: true,
        ),
        gap,
        placement(
          BatchRenameKey.addPlacement,
          _addPlacement,
          (value) => _addPlacement = value,
        ),
      ],
      BatchRenameMode.format => [
        field(
          BatchRenameKey.formatName,
          _formatName,
          l10n.batchRenameFormatNameLabel,
          hint: l10n.batchRenameFormatNameHint,
          autofocus: true,
        ),
        gap,
        placement(
          BatchRenameKey.formatPlacement,
          _formatPlacement,
          (value) => _formatPlacement = value,
        ),
        gap,
        field(
          BatchRenameKey.startAt,
          _startAt,
          l10n.batchRenameStartAtLabel,
          keyboardType: TextInputType.number,
          formatters: [FilteringTextInputFormatter.digitsOnly],
          error: _startAtValue == null ? l10n.batchRenameStartAtInvalid : null,
        ),
      ],
    };
  }

  Widget _summary(
    BuildContext context,
    AppLocalizations l10n,
    BatchRenamePlan? plan,
  ) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final session = _session;

    if (session.stage != BatchRenameStage.editing && plan != null) {
      final total = plan.renameCount;
      final renamed = session.renamedCount;
      final text = switch (session.stage) {
        BatchRenameStage.running when session.stopRequested =>
          l10n.batchRenameStopping,
        BatchRenameStage.running => l10n.batchRenameProgress(
          session.settledCount,
          total,
        ),
        _ => switch (session.stop) {
          BatchRenameStop.stopped => l10n.batchRenameResultStopped(
            renamed,
            total,
          ),
          BatchRenameStop.connectionLost =>
            l10n.batchRenameResultConnectionLost(renamed, total),
          BatchRenameStop.paneChanged => l10n.batchRenameResultPaneChanged(
            renamed,
            total,
          ),
          BatchRenameStop.fault => l10n.batchRenameResultFault(renamed, total),
          BatchRenameStop.completed ||
          null => l10n.batchRenameResultSome(renamed, total),
        },
      };
      return Semantics(
        key: const ValueKey(BatchRenameKey.summary),
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(text),
            if (session.stage == BatchRenameStage.running) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                key: const ValueKey(BatchRenameKey.progress),
                value: total == 0 ? null : session.settledCount / total,
              ),
            ],
          ],
        ),
      );
    }

    final lines = <Widget>[];
    if (session.refusedUnavailable) {
      lines.add(
        Text(
          l10n.batchRenameUnavailable,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (session.refusedChanged) {
      lines.add(
        Text(
          l10n.batchRenameChanged,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (plan != null) {
      if (plan.blockedCount > 0) {
        lines.add(
          InkWell(
            onTap: () => _jumpToFirstProblem(plan),
            child: Text(
              l10n.batchRenameSummaryBlocked(plan.blockedCount),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        );
      } else {
        lines.add(
          Text(
            plan.renameCount > 0
                ? l10n.batchRenameSummaryReady(plan.renameCount)
                : l10n.batchRenameSummaryNothing,
          ),
        );
      }
      final details = [
        if (plan.unchangedCount > 0 && plan.renameCount > 0)
          l10n.batchRenameSummaryUnchanged(plan.unchangedCount),
        if (plan.leftOutCount > 0)
          l10n.batchRenameSummaryLeftOut(plan.leftOutCount),
      ];
      for (final detail in details) {
        lines.add(Text(detail, style: muted));
      }
    }
    return Semantics(
      key: const ValueKey(BatchRenameKey.summary),
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }

  Widget _previewList(
    BuildContext context,
    AppLocalizations l10n,
    BatchRenamePlan? plan,
  ) {
    final rows = plan?.rows ?? const <BatchRenameRow>[];
    final folders = {for (final row in rows) row.target.folder};
    final showFolder = folders.length > 1;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListView.builder(
        key: const ValueKey(BatchRenameKey.preview),
        controller: _preview,
        itemExtent: _rowExtent(context),
        itemCount: rows.length,
        itemBuilder: (context, index) => _previewRow(
          context,
          l10n,
          index,
          rows[index],
          showFolder: showFolder,
        ),
      ),
    );
  }

  Widget _previewRow(
    BuildContext context,
    AppLocalizations l10n,
    int index,
    BatchRenameRow row, {
    required bool showFolder,
  }) {
    final theme = Theme.of(context);
    final (status, blocking) = _rowStatus(l10n, index, row);
    final muted = theme.colorScheme.onSurfaceVariant;
    final statusStyle = theme.textTheme.bodySmall?.copyWith(
      color: blocking ? theme.colorScheme.error : muted,
    );
    final caption = showFolder
        ? l10n.batchRenameFolderCaption(paneLastSegment(row.target.folder))
        : null;
    return Semantics(
      key: ValueKey((BatchRenameKey.row, index)),
      container: true,
      label: l10n.batchRenameRowSemantics(row.target.name, row.newName),
      value: status,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    row.target.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward, size: 14),
                ),
                Flexible(
                  child: Text(
                    row.newName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (status != null)
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: statusStyle,
              )
            else if (caption != null)
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
          ],
        ),
      ),
    );
  }

  /// The row's status line and whether it is a problem the user must
  /// fix. While running or finished, the run's outcome replaces the
  /// planned status of a rename row.
  (String?, bool) _rowStatus(
    AppLocalizations l10n,
    int index,
    BatchRenameRow row,
  ) {
    final session = _session;
    if (session.stage != BatchRenameStage.editing &&
        row.status == BatchRenameStatus.rename) {
      final outcomes = session.outcomes;
      final outcome = index < outcomes.length ? outcomes[index] : null;
      return switch (outcome) {
        BatchRenameRenamed() => (l10n.batchRenameRowRenamed, false),
        BatchRenameFailed(:final error) => (
          compactRenameErrorText(l10n, error),
          true,
        ),
        BatchRenameSkippedBlocked(:final blocker) => (
          l10n.batchRenameRowSkippedBlocked(
            session.runPlan!.rows[blocker].target.name,
          ),
          true,
        ),
        BatchRenameUnknown() => (l10n.batchRenameRowUnknown, true),
        null when session.stage == BatchRenameStage.finished => (
          l10n.batchRenameRowNotAttempted,
          false,
        ),
        null => (null, false),
      };
    }
    return switch (row.status) {
      BatchRenameStatus.rename => (null, false),
      BatchRenameStatus.unchanged => (l10n.batchRenameRowUnchanged, false),
      BatchRenameStatus.leftOut => (l10n.batchRenameRowLeftOut, false),
      BatchRenameStatus.gone => (l10n.paneFaultRenameTargetGone, true),
      BatchRenameStatus.invalidName => (
        switch (row.nameError) {
          RenameNameError.separator => l10n.paneFaultRenameNameSeparator,
          RenameNameError.invalid => l10n.paneFaultRenameNameInvalid,
          RenameNameError.empty || null => l10n.batchRenameRowNameEmpty,
        },
        true,
      ),
      BatchRenameStatus.becomesHidden => (l10n.batchRenameRowHidden, true),
      BatchRenameStatus.duplicate => (l10n.batchRenameRowDuplicate, true),
      BatchRenameStatus.exists => (
        l10n.batchRenameRowExists(row.conflictName!),
        true,
      ),
      BatchRenameStatus.cycle => (l10n.batchRenameRowCycle, true),
    };
  }

  List<Widget> _actions(AppLocalizations l10n, BatchRenamePlan? plan) {
    final session = _session;
    switch (session.stage) {
      case BatchRenameStage.editing:
        final runnable = plan?.runnable ?? false;
        return [
          TextButton(
            key: const ValueKey(BatchRenameKey.cancel),
            onPressed: _cancel,
            child: Text(l10n.batchRenameCancel),
          ),
          FilledButton(
            key: const ValueKey(BatchRenameKey.confirm),
            onPressed: runnable ? _submit : null,
            child: Text(l10n.batchRenameConfirm(plan?.renameCount ?? 0)),
          ),
        ];
      case BatchRenameStage.running:
        return [
          TextButton(
            key: const ValueKey(BatchRenameKey.stop),
            focusNode: _actionFocus,
            // Stays enabled after a press (Stop is idempotent): a disabled
            // button would drop focus back onto the mode picker.
            onPressed: _cancel,
            child: Text(l10n.batchRenameStop),
          ),
        ];
      case BatchRenameStage.finished:
      case BatchRenameStage.ended:
        return [
          FilledButton(
            key: const ValueKey(BatchRenameKey.done),
            focusNode: _actionFocus,
            onPressed: _cancel,
            child: Text(l10n.batchRenameDone),
          ),
        ];
    }
  }
}
