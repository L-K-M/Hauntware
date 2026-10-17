import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show EditorController, PlanchetteEditor;

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../processes_panel.dart' show kRevealDuration;
import 'container_details.dart' show ContainerInspectionScope;
import 'containers_panel.dart' show DockerNotice;
import 'stacks_view.dart';

/// The largest the desktop's file dialog grows.
const Size _dialogSize = Size(960, 720);

/// Opens [project]'s files (03 §7.16 STK-04): in a dialog on the desktop,
/// whose inspector shows containers, or on a page of its own on a phone
/// (03 §10.5: details push further). Only a verified stack offers it.
void openStackFiles(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required ComposeProject project,
}) {
  final view = StackFileView(
    monitoring: monitoring,
    serverId: serverId,
    project: project,
  );
  if (ContainerInspectionScope.find(context) != null) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => _StackFileDialog(project: project, view: view),
      ),
    );
    return;
  }

  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(
              AppLocalizations.of(context).dockerStackFileTitle(project.name),
            ),
          ),
          body: SafeArea(
            child: Padding(padding: const EdgeInsets.all(16), child: view),
          ),
        ),
      ),
    ),
  );
}

/// The desktop's file dialog: the title and a close button over [view].
class _StackFileDialog extends StatelessWidget {
  const _StackFileDialog({required this.project, required this.view});

  final ComposeProject project;
  final StackFileView view;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
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
                        l10n.dockerStackFileTitle(project.name),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.dockerStackFileClose,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: view,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A verified stack's compose and environment files (03 §7.16 STK-04,
/// M11), one at a time: a picker of [project]'s files ([stackFilesOf]),
/// the one picked read through [DockerStackFileQuery] and shown in
/// Planchette's editor with editing locked, so it highlights and finds
/// but never changes. Nothing else is shown: the engine never captures
/// `compose config` output, whose interpolation holds secrets.
///
/// The engine masks every environment value, secret compose keys and URL
/// credentials (03 §8.9), and the editor shows the masks. "Reveal values"
/// shows them for [kRevealDuration]. The revealed text lives in this
/// view's state only: it is masked again when its time is up, when the
/// app turns inactive (before an app switcher's snapshot), and when the
/// view picks another file or closes, and nothing sends, stores or logs
/// it (SAF-07). A file over [kStackFileMaxBytes] says how much of it
/// shows; a file the engine did not read says why.
class StackFileView extends StatefulWidget {
  const StackFileView({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.project,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The stack as it was listed when the view opened.
  final ComposeProject project;

  @override
  State<StackFileView> createState() => _StackFileViewState();
}

class _StackFileViewState extends State<StackFileView> {
  late final List<StackFile> _files = stackFilesOf(widget.project);
  late final AppLifecycleListener _lifecycle;

  /// The file picked, by path.
  String? _path;

  /// The engine's answer for [_path]; null while it is read.
  DockerPayload? _answer;

  /// Counts reads, so an answer for a file no longer picked is dropped.
  int _reads = 0;

  /// The editor showing [_answer]'s text, masked or revealed.
  EditorController? _editor;

  /// Masks the revealed values when their time is up; null while
  /// masked.
  Timer? _reveal;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onInactive: _mask);
    if (_files.isNotEmpty) unawaited(_open(_files.first.path));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _reveal?.cancel();
    _editor?.dispose();
    super.dispose();
  }

  /// Reads [path], dropping the file shown before and anything revealed.
  Future<void> _open(String path) async {
    final read = ++_reads;
    _reveal?.cancel();
    _reveal = null;
    _showText(null);
    setState(() {
      _path = path;
      _answer = null;
    });

    final answer = await widget.monitoring.docker.readStackFile(
      widget.serverId,
      project: widget.project.name,
      path: path,
    );
    if (!mounted || read != _reads) return;

    setState(() {
      _answer = answer;
      _showText(_text(revealed: false));
    });
  }

  /// The file's text, its masked spans masked unless [revealed]; null
  /// without a file.
  String? _text({required bool revealed}) => switch (_answer) {
    DockerStackFilePayload(:final text) => [
      for (final span in text)
        revealed ? span.reveal() ?? span.display : span.display,
    ].join(),
    _ => null,
  };

  /// Shows [text] in a new locked editor, or none, and lets the old one
  /// go once the frame that drops it is drawn.
  void _showText(String? text) {
    final before = _editor;
    _editor = text == null
        ? null
        // The path picks the highlighting: YAML, or an environment file.
        : (EditorController(displayPath: _path!, initialText: text)
            ..setEditingLocked(true));
    if (before != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => before.dispose());
    }
  }

  void _toggleReveal() {
    if (_reveal != null) {
      _mask();
      return;
    }

    setState(() {
      _reveal = Timer(kRevealDuration, _mask);
      _showText(_text(revealed: true));
    });
  }

  void _mask() {
    final timer = _reveal;
    if (timer == null || !mounted) return;

    timer.cancel();
    setState(() {
      _reveal = null;
      _showText(_text(revealed: false));
    });
  }

  void _retry() {
    final path = _path;
    if (path != null) unawaited(_open(path));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final path = _path;
    if (path == null) return const SizedBox.shrink();

    final name = stackFileName(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (_files.length > 1)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final file in _files)
                ChoiceChip(
                  avatar: Icon(switch (file.role) {
                    StackFileRole.compose => Icons.description_outlined,
                    StackFileRole.environment => Icons.key_outlined,
                  }),
                  label: Text(stackFileName(file.path)),
                  tooltip: file.path,
                  selected: file.path == path,
                  onSelected: (_) {
                    if (file.path != path) unawaited(_open(file.path));
                  },
                ),
            ],
          ),
        Text(
          path,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        ..._body(context, l10n, name),
      ],
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l10n, String name) {
    final retry = TextButton(onPressed: _retry, child: Text(l10n.dockerRetry));
    switch (_answer) {
      case null:
        return [
          DockerNotice(
            icon: Icons.hourglass_empty,
            text: l10n.dockerStackFileReading(name),
          ),
        ];
      case DockerStackFileFailed(:final failure):
        return [
          DockerNotice(
            icon: failure == StackFileFailure.permissionDenied
                ? Icons.lock_outline
                : Icons.error_outline,
            text: l10n.dockerStackFileFailed(failure.name),
            action: failure == StackFileFailure.readFailed ? retry : null,
          ),
        ];
      case DockerQueryFailed(:final failure, :final detail):
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerStackFileQueryFailed(failure.name),
            detail: detail,
            action: retry,
          ),
        ];
      case DockerStackFilePayload(:final text, :final size, :final truncated):
        final masked = text.where((span) => span.isMasked).length;
        final revealed = _reveal != null;
        final editor = _editor;
        return [
          if (truncated)
            DockerNotice(
              icon: Icons.content_cut,
              text: l10n.dockerStackFileTruncated(
                ghostFormatBinarySize(size),
                ghostFormatBinarySize(kStackFileMaxBytes),
              ),
            ),
          if (masked > 0)
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10n.dockerStackFileMasked(masked, kRevealDuration.inSeconds),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                TextButton.icon(
                  onPressed: _toggleReveal,
                  icon: Icon(
                    revealed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  label: Text(
                    revealed
                        ? l10n.dockerStackFileHide
                        : l10n.dockerStackFileReveal,
                  ),
                ),
              ],
            ),
          if (editor != null)
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Semantics(
                    container: true,
                    label: l10n.dockerStackFileEditorLabel(name),
                    child: PlanchetteEditor(
                      // A new text is a new editor.
                      key: ObjectKey(editor),
                      controller: editor,
                      editingLocked: true,
                      showStatus: false,
                    ),
                  ),
                ),
              ),
            ),
        ];
      case _:
        // No other payload answers a file read; one would be a read
        // that went wrong.
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerStackFileFailed(StackFileFailure.readFailed.name),
            action: retry,
          ),
        ];
    }
  }
}
