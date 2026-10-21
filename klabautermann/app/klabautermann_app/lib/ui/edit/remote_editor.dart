import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_core/planchette_core.dart'
    show
        TextProblem,
        TextProblemSeverity,
        UnifiedDiffResult,
        UnifiedDiffStatus,
        boundedUnifiedDiff,
        lineIndexAt,
        lineStartOffsets,
        syntaxLanguageFor,
        textFormatFor,
        validateText;
import 'package:planchette_editor/planchette_editor.dart'
    show EditorController, PlanchetteEditor;

import '../../controllers/operations_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart' show klabautermannThemeStyle;
import '../actions/action_entry.dart' show OperationsScope;
import '../actions/action_preview.dart' show startAction;
import '../admin_mode_chip.dart' show TurnOnAdminModeButton;
import '../docker/containers_panel.dart' show DockerNotice;

/// Below this width the editor takes the whole screen, as on phones
/// (03 §10.5).
const double _pageBelowWidth = 600;

/// The largest the desktop's editor dialog grows.
const Size _dialogSize = Size(960, 720);

/// The path the editor highlights [target] as, and validates it by.
String editTargetPath(EditTarget target) => switch (target) {
  FileTarget(:final path) => path,
  CrontabTarget() => 'crontab',
};

/// Opens [target] on [serverId] in the editor (03 §8.5, SAF-12, X-05): a
/// dialog on wide windows, a page of its own on phones. Closing it with
/// changes not saved asks first. Completes once it is closed. With
/// [proposedText], such as a backup to restore, the editor opens with it
/// in place of the server's text, unsaved.
Future<void> openRemoteEditor(
  BuildContext context, {
  required String serverId,
  required EditTarget target,
  String? proposedText,
}) {
  final editor = RemoteEditor(
    serverId: serverId,
    target: target,
    proposedText: proposedText,
  );
  final title = _title(AppLocalizations.of(context), target);
  if (MediaQuery.sizeOf(context).width < _pageBelowWidth) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(
            child: Padding(padding: const EdgeInsets.all(16), child: editor),
          ),
        ),
      ),
    );
  }

  return showDialog<void>(
    context: context,
    // A tap outside would drop the changes without asking.
    barrierDismissible: false,
    builder: (context) => Dialog(
      child: SizedBox.fromSize(
        size: _dialogSize,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: AppLocalizations.of(context).editClose,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: editor,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _title(AppLocalizations l10n, EditTarget target) => switch (target) {
  FileTarget(:final path) => l10n.editTitleFile(path.split('/').last),
  CrontabTarget(:final user?) => l10n.editTitleCrontab(user),
  CrontabTarget() => l10n.editTitleOwnCrontab,
};

/// What the user chose when the target changed under their edit.
enum _ConflictChoice {
  /// Read the server's text and review it against theirs.
  compare,

  /// Drop their changes for the server's text.
  discard,
}

/// One file or crontab, read through the engine and edited in Planchette's
/// editor (03 §8.5, SAF-12). "Review" shows the change as a bounded unified
/// diff (`boundedUnifiedDiff`) with the quick format checks
/// (`validateText`), and saving plans an [EditFile] against the hash the
/// read returned, so the engine's preview shows the steps, the backup and
/// the host writes before anything runs.
///
/// When the target changed since the read, at planning or right before
/// the rename, the conflict sheet offers "Reload and compare", which keeps
/// the user's text and reviews it against the server's, or "Discard
/// mine". Nothing is kept on this device: the text lives in this view's
/// editor only.
class RemoteEditor extends StatefulWidget {
  const RemoteEditor({
    super.key,
    required this.serverId,
    required this.target,
    this.proposedText,
  });

  final String serverId;
  final EditTarget target;

  /// The text the editor opens with over the first read, unsaved; null
  /// opens the server's.
  final String? proposedText;

  @override
  State<RemoteEditor> createState() => _RemoteEditorState();
}

class _RemoteEditorState extends State<RemoteEditor> {
  /// The engine's latest answer; null while it is read.
  EditReadResult? _answer;

  /// The text the next save is planned against.
  EditContent? _base;

  /// The editor, unlocked, over the user's text.
  EditorController? _editor;

  /// Counts reads, so an answer a newer read replaced is dropped.
  int _reads = 0;

  bool _dirty = false;

  /// Whether [RemoteEditor.proposedText] still waits for the first read.
  late bool _proposing = widget.proposedText != null;

  /// The run of the save the user confirmed, followed to its end.
  StreamSubscription<(String, RunState)>? _run;

  String get _path => editTargetPath(widget.target);

  OperationsController? get _operations => OperationsScope.maybeOf(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_read(keepMine: false));
    });
  }

  @override
  void dispose() {
    unawaited(_run?.cancel());
    _editor?.dispose();
    super.dispose();
  }

  /// Reads the target again. The server's text replaces the editor's
  /// unless [keepMine], which only moves the base under the user's text;
  /// a read that fails then says why in a toast and leaves the user's
  /// text where it is, rather than trading it for the notice.
  Future<void> _read({required bool keepMine}) async {
    final operations = _operations;
    if (operations == null) return;

    final read = ++_reads;
    if (!keepMine) setState(() => _answer = null);
    final answer = await operations.readEditable(
      widget.serverId,
      widget.target,
    );
    if (!mounted || read != _reads) return;

    if (answer is EditReadFailed && keepMine && _editor != null) {
      showTopToast(
        Overlay.of(context, rootOverlay: true),
        message: AppLocalizations.of(context)
            .editReadFailed(answer.failure.name),
      );
      return;
    }
    setState(() {
      _answer = answer;
      if (answer is! EditContent) return;
      _base = answer;
      if (_proposing) {
        _proposing = false;
        _showText(widget.proposedText!);
      } else if (!keepMine || _editor == null) {
        _showText(answer.text);
      }
      _dirty = _editor!.text.text != answer.text;
    });
  }

  /// Shows [text] in a new editor and lets the old one go once the frame
  /// that drops it is drawn.
  void _showText(String text) {
    final before = _editor;
    _editor = EditorController(displayPath: _path, initialText: text)
      ..text.addListener(_edited);
    if (before != null) {
      before.text.removeListener(_edited);
      WidgetsBinding.instance.addPostFrameCallback((_) => before.dispose());
    }
  }

  void _edited() {
    final dirty = _editor?.text.text != _base?.text;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _review() async {
    final base = _base;
    final editor = _editor;
    if (base == null || editor == null) return;

    final text = editor.text.text;
    final save = await showEditReview(
      context,
      base: base.text,
      text: text,
      path: _path,
    );
    if (save != true || !mounted) return;

    startAction(
      context,
      EditFile(
        widget.serverId,
        target: widget.target,
        text: text,
        baseSha256: base.sha256,
      ),
      onRun: (planId, _) => _follow(planId),
      onRefused: _refused,
    );
  }

  /// Follows the save's run: a finished save reads the new base, and a
  /// target changed right before the rename opens the conflict sheet.
  /// Other ends are the result toasts' to tell.
  void _follow(String planId) {
    final operations = _operations;
    if (operations == null) return;

    unawaited(_run?.cancel());
    _run = operations.ends.where((end) => end.$1 == planId).listen((end) {
      unawaited(_run?.cancel());
      _run = null;
      if (!mounted) return;
      switch (end.$2) {
        case RunFinished(:final finished)
            when finished.outcome == ActionOutcome.succeeded:
          unawaited(_read(keepMine: true));
        case RunFinished(:final finished)
            when finished.revalidation == RevalidationFailure.contentChanged:
          unawaited(_conflict());
        case _:
      }
    });
  }

  void _refused(ActionRefusalReason reason) {
    if (!mounted) return;
    if (reason == ActionRefusalReason.targetChanged) {
      unawaited(_conflict());
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    showTopToast(
      overlay,
      message: AppLocalizations.of(context).actionRefused(reason.name),
    );
  }

  Future<void> _conflict() async {
    final choice = await _showConflict(context);
    if (!mounted || choice == null) return;

    switch (choice) {
      case _ConflictChoice.discard:
        await _read(keepMine: false);
      case _ConflictChoice.compare:
        // A read that failed leaves the base the save was refused for, and
        // a review against it would only be refused again.
        final refused = _base;
        await _read(keepMine: true);
        if (mounted && _dirty && !identical(_base, refused)) await _review();
    }
  }

  Future<void> _discardChanges() async {
    if (!await _confirmDiscard(context) || !mounted) return;
    final base = _base;
    if (base == null) return;
    setState(() {
      _showText(base.text);
      _dirty = false;
    });
  }

  Future<void> _closeAsked() async {
    if (!await _confirmDiscard(context) || !mounted) return;
    // The pop waits for the frame that lets this route go.
    setState(() => _dirty = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_closeAsked());
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: _body(context, l10n),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l10n) {
    final retry = TextButton(
      onPressed: () => unawaited(_read(keepMine: false)),
      child: Text(l10n.editRetry),
    );
    final theme = Theme.of(context);
    final pathLine = Text(
      switch (widget.target) {
        FileTarget(:final path) => path,
        final target => _title(l10n, target),
      },
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    switch (_answer) {
      case null:
        return [
          pathLine,
          DockerNotice(icon: Icons.hourglass_empty, text: l10n.editReading),
        ];
      case EditReadFailed(:final failure):
        return [
          pathLine,
          DockerNotice(
            icon: failure == EditReadFailure.adminRequired
                ? Icons.lock_outline
                : Icons.error_outline,
            text: l10n.editReadFailed(failure.name),
            // Once admin mode is on, reading again goes through sudo.
            action: switch (failure) {
              EditReadFailure.noLink ||
              EditReadFailure.adminRequired ||
              EditReadFailure.failed => retry,
              _ => null,
            },
          ),
          if (failure == EditReadFailure.adminRequired)
            TurnOnAdminModeButton(serverId: widget.serverId),
        ];
      case EditContent(:final privileged):
        final editor = _editor!;
        return [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              pathLine,
              if (privileged)
                Chip(
                  avatar: const Icon(Icons.admin_panel_settings_outlined),
                  label: Text(l10n.editRootFile),
                  visualDensity: VisualDensity.compact,
                ),
              if (_dirty)
                Text(
                  l10n.editUnsaved,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
            ],
          ),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Semantics(
                  container: true,
                  label: l10n.editEditorLabel(_path),
                  child: PlanchetteEditor(
                    // A new text is a new editor.
                    key: ObjectKey(editor),
                    controller: editor,
                    showStatus: false,
                  ),
                ),
              ),
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: _dirty ? () => unawaited(_discardChanges()) : null,
                child: Text(l10n.editDiscard),
              ),
              FilledButton.icon(
                onPressed: _dirty ? () => unawaited(_review()) : null,
                icon: const Icon(Icons.difference_outlined),
                label: Text(l10n.editReview),
              ),
            ],
          ),
        ];
    }
  }
}

Future<bool> _confirmDiscard(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.editDiscardTitle),
      content: Text(l10n.editDiscardBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.editKeepEditing),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.editDiscard),
        ),
      ],
    ),
  );
  return discard ?? false;
}

Future<_ConflictChoice?> _showConflict(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showDialog<_ConflictChoice>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.sync_problem_outlined),
      title: Text(l10n.editConflictTitle),
      content: Text(l10n.editConflictBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.editKeepEditing),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ConflictChoice.discard),
          child: Text(l10n.editConflictDiscard),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ConflictChoice.compare),
          child: Text(l10n.editConflictCompare),
        ),
      ],
    ),
  );
}

/// Shows the change from [base] to [text], the file at [path], with its
/// format problems, and returns whether the user chose to save it: a
/// dialog on wide windows and a bottom sheet on narrow ones.
Future<bool?> showEditReview(
  BuildContext context, {
  required String base,
  required String text,
  required String path,
}) {
  final l10n = AppLocalizations.of(context);
  final review = _EditReview(
    diff: boundedUnifiedDiff(
      base,
      text,
      oldLabel: l10n.editDiffServerLabel(path),
      newLabel: l10n.editDiffYourLabel(path),
    ),
    text: text,
    problems: validateText(text, textFormatFor(path, syntaxLanguageFor(path))),
  );
  if (MediaQuery.sizeOf(context).width < _pageBelowWidth) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.85,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: review,
          ),
        ),
      ),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox.fromSize(
        size: _dialogSize,
        child: Padding(padding: const EdgeInsets.all(24), child: review),
      ),
    ),
  );
}

/// The review's body: the format problems, then the diff, then Cancel and
/// Save. Save stays off until the diff shows a change; problems warn but
/// do not block, since the host's own check runs at planning.
class _EditReview extends StatelessWidget {
  const _EditReview({
    required this.diff,
    required this.text,
    required this.problems,
  });

  final Future<UnifiedDiffResult> diff;
  final String text;
  final List<TextProblem> problems;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lineStarts = problems.isEmpty
        ? const <int>[]
        : lineStartOffsets(text);
    return FutureBuilder<UnifiedDiffResult>(
      future: diff,
      builder: (context, snapshot) {
        final result = snapshot.data;
        final changed = switch (result?.status) {
          UnifiedDiffStatus.differs ||
          UnifiedDiffStatus.tooLarge ||
          UnifiedDiffStatus.timedOut => true,
          _ => false,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Semantics(
              header: true,
              child: Text(l10n.editReview, style: theme.textTheme.titleMedium),
            ),
            if (problems.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final problem in problems)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          problem.severity == TextProblemSeverity.error
                              ? Icons.error_outline
                              : Icons.warning_amber_outlined,
                          color: problem.severity == TextProblemSeverity.error
                              ? theme.colorScheme.error
                              : theme.colorScheme.tertiary,
                        ),
                        title: Text(
                          l10n.editProblem(
                            lineIndexAt(lineStarts, problem.start) + 1,
                            problem.kind.name,
                            problem.subject ?? problem.detail ?? '',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(child: _DiffBody(result: result)),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l10n.editKeepEditing),
                ),
                FilledButton(
                  onPressed: changed
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: Text(
                    problems.isEmpty ? l10n.editSave : l10n.editSaveAnyway,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The unified diff, one line per row in the monospace stack, added lines
/// and removed ones tinted; or why it does not show.
class _DiffBody extends StatelessWidget {
  const _DiffBody({required this.result});

  final UnifiedDiffResult? result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = this.result;
    if (result == null) {
      return DockerNotice(icon: Icons.hourglass_empty, text: l10n.editDiffing);
    }
    if (result.status != UnifiedDiffStatus.differs) {
      return Align(
        alignment: AlignmentDirectional.topStart,
        child: DockerNotice(
          icon: result.status == UnifiedDiffStatus.identical
              ? Icons.check
              : Icons.info_outline,
          text: l10n.editDiffStatus(result.status.name),
          detail: result.detail.isEmpty ? null : result.detail,
        ),
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
      fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies
          .skip(1)
          .toList(),
    );
    final lines = result.text.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Semantics(
        label: l10n.editDiffLabel,
        container: true,
        child: SelectionArea(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              // Only the two label lines; an added '++x' line is content.
              final header =
                  index < 2 &&
                  (line.startsWith('+++') || line.startsWith('---'));
              final tint = header
                  ? null
                  : line.startsWith('+')
                  ? scheme.primaryContainer
                  : line.startsWith('-')
                  ? scheme.errorContainer
                  : null;
              return ColoredBox(
                color: tint ?? Colors.transparent,
                child: Text(
                  line,
                  style: line.startsWith('@@') || header
                      ? mono?.copyWith(color: scheme.onSurfaceVariant)
                      : mono,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
