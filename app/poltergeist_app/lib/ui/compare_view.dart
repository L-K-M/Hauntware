import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart' as pe;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/sync_compare_controller.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'editor_strings.dart';
import 'panes/pane_format.dart';

/// The sync plan's read-only, side-by-side text comparison (06 §6).
final class CompareView extends StatefulWidget {
  const CompareView({super.key, required this.controller, this.clock});

  /// Owned by this route so teardown cancels both side loads.
  final SyncCompareController controller;

  /// Test seam for the metadata header's relative modified-time labels.
  final DateTime Function()? clock;

  @override
  State<CompareView> createState() => _CompareViewState();
}

class _CompareViewState extends State<CompareView> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.start());
  }

  @override
  void didUpdateWidget(CompareView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    oldWidget.controller.dispose();
    unawaited(widget.controller.start());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('sync.compare.view'),
      appBar: AppBar(
        title: Text(
          l10n.syncCompareTitle(widget.controller.request.relativePath),
        ),
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final left = widget.controller.left;
          final right = widget.controller.right;
          final notices = _differenceNotices(l10n, left, right);
          final now = widget.clock?.call() ?? DateTime.now();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (notices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(spacing: 8, runSpacing: 4, children: notices),
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _CompareSide(
                        key: const ValueKey('sync.compare.left'),
                        controller: widget.controller,
                        state: left,
                        label: l10n.syncCompareSideLeft,
                        now: now,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _CompareSide(
                        key: const ValueKey('sync.compare.right'),
                        controller: widget.controller,
                        state: right,
                        label: l10n.syncCompareSideRight,
                        now: now,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _differenceNotices(
    AppLocalizations l10n,
    SyncCompareSideState left,
    SyncCompareSideState right,
  ) {
    if (left.phase != SyncComparePhase.ready ||
        right.phase != SyncComparePhase.ready) {
      return const [];
    }
    final leftDocument = left.document;
    final rightDocument = right.document;
    if (leftDocument == null || rightDocument == null) return const [];

    return [
      if (leftDocument.lineEnding != rightDocument.lineEnding)
        Chip(
          key: const ValueKey('sync.compare.line-endings'),
          label: Text(
            l10n.syncCompareLineEndingsDiffer(
              leftDocument.lineEnding.name.toUpperCase(),
              rightDocument.lineEnding.name.toUpperCase(),
            ),
          ),
        ),
      if (leftDocument.hasUtf8Bom != rightDocument.hasUtf8Bom)
        Chip(
          key: const ValueKey('sync.compare.bom'),
          label: Text(l10n.syncCompareBomDiffers),
        ),
    ];
  }
}

/// Owns one editor so each side keeps independent find and scroll state.
class _CompareSide extends StatefulWidget {
  const _CompareSide({
    super.key,
    required this.controller,
    required this.state,
    required this.label,
    required this.now,
  });

  final SyncCompareController controller;
  final SyncCompareSideState state;
  final String label;
  final DateTime now;

  @override
  State<_CompareSide> createState() => _CompareSideState();
}

class _CompareSideState extends State<_CompareSide> {
  pe.EditorController? _editor;
  BuiltInTextDocument? _editorDocument;
  String? _editorPath;

  @override
  void initState() {
    super.initState();
    _synchronizeEditor();
  }

  @override
  void didUpdateWidget(_CompareSide oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronizeEditor();
  }

  void _synchronizeEditor() {
    final state = widget.state;
    final document = state.phase == SyncComparePhase.ready
        ? state.document
        : null;
    final path = state.source.fullPath;
    if (identical(document, _editorDocument) && path == _editorPath) return;

    _editor?.dispose();
    _editor = document == null
        ? null
        : pe.EditorController(displayPath: path, initialText: document.text);
    _editorDocument = document;
    _editorPath = path;
  }

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, l10n),
        const Divider(height: 1),
        Expanded(child: _body(context, l10n)),
      ],
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n) {
    final colors = Theme.of(context).colorScheme;
    final source = widget.state.source;
    final snapshot = source.snapshot;
    final modified = snapshot.mtimeSecs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(snapshot.mtimeSecs! * 1000);
    final modifiedLabel = formatPaneModified(
      modified,
      now: widget.now,
      localeName: Localizations.localeOf(context).toString(),
      today: l10n.paneDateToday,
      yesterday: l10n.paneDateYesterday,
    );
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  source.fullPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  l10n.syncCompareMetadata(
                    formatPaneSize(
                      snapshot.size,
                      platform: Theme.of(context).platform,
                    ),
                    modifiedLabel,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.editorFindTooltip,
            onPressed: _editor?.openSearch,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    return switch (widget.state.phase) {
      SyncComparePhase.loading => _message(
        context,
        l10n.syncCompareLoading,
        progress: true,
      ),
      SyncComparePhase.confirming => _confirmation(context, l10n),
      SyncComparePhase.downloading => _progress(context, l10n),
      SyncComparePhase.gateConfirm => _gate(context, l10n),
      SyncComparePhase.ready => _ready(context, l10n),
      SyncComparePhase.refused => _message(
        context,
        _refusalMessage(l10n, widget.state.refusal),
      ),
      SyncComparePhase.cancelled => _message(
        context,
        l10n.previewDownloadCancelled,
      ),
      SyncComparePhase.failed => _failure(context, l10n),
    };
  }

  Widget _confirmation(BuildContext context, AppLocalizations l10n) {
    final state = widget.state;
    final bytes = state.totalBytes ?? state.source.snapshot.size;
    return _card(
      context,
      children: [
        Text(
          l10n.previewDownloadConfirm(
            formatPaneSize(bytes, platform: Theme.of(context).platform),
            state.source.fullPath,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: () => widget.controller.cancel(state.source.side),
              child: Text(l10n.previewCancelLabel),
            ),
            FilledButton(
              onPressed: () => widget.controller.confirm(state.source.side),
              child: Text(l10n.previewDownloadLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _progress(BuildContext context, AppLocalizations l10n) {
    final state = widget.state;
    final total = state.totalBytes;
    final platform = Theme.of(context).platform;
    final transferred = formatPaneSize(state.transferred, platform: platform);
    final progress = total == null
        ? transferred
        : l10n.previewDownloadProgress(
            transferred,
            formatPaneSize(total, platform: platform),
          );
    return _card(
      context,
      children: [
        Text(l10n.previewDownloadingLabel),
        const SizedBox(height: 8),
        Semantics(
          label: l10n.previewDownloadingLabel,
          value: progress,
          child: LinearProgressIndicator(
            value: total != null && total > 0
                ? (state.transferred / total).clamp(0.0, 1.0)
                : null,
          ),
        ),
        const SizedBox(height: 8),
        Text(progress, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => widget.controller.cancel(state.source.side),
            child: Text(l10n.previewCancelLabel),
          ),
        ),
      ],
    );
  }

  Widget _gate(BuildContext context, AppLocalizations l10n) {
    final state = widget.state;
    return _card(
      context,
      children: [
        Text(
          l10n.previewGatePrompt(
            formatPaneSize(
              state.transferred,
              platform: Theme.of(context).platform,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: () => widget.controller.cancel(state.source.side),
              child: Text(l10n.previewCancelLabel),
            ),
            FilledButton(
              onPressed: () => widget.controller.confirm(state.source.side),
              child: Text(l10n.previewKeepDownloadingLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ready(BuildContext context, AppLocalizations l10n) {
    final editor = _editor;
    if (editor == null) {
      return _message(context, l10n.syncCompareLoading, progress: true);
    }
    return pe.PlanchetteEditor(
      controller: editor,
      strings: PoltergeistEditorStrings(l10n),
      editingLocked: true,
      showStatus: false,
      textStyle: poltergeistMonoTextStyle.copyWith(fontSize: 14, height: 1.35),
    );
  }

  Widget _failure(BuildContext context, AppLocalizations l10n) {
    return _card(
      context,
      children: [
        Text(
          _failureMessage(l10n, widget.state.failure),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    );
  }

  String _failureMessage(AppLocalizations l10n, SyncCompareFailure? failure) =>
      switch (failure) {
        SyncCompareFailure.invalidUtf8 => l10n.syncCompareInvalidUtf8,
        SyncCompareFailure.binary => l10n.syncCompareBinary,
        SyncCompareFailure.changed => l10n.syncCompareChanged,
        SyncCompareFailure.missing => l10n.syncCompareMissing,
        SyncCompareFailure.other || null => l10n.syncCompareFailed,
      };

  String _refusalMessage(AppLocalizations l10n, SyncCompareRefusal? refusal) =>
      switch (refusal) {
        SyncCompareRefusal.editorLimit => l10n.syncCompareEditorLimit,
        SyncCompareRefusal.cacheLimit => l10n.previewRefusalOverCacheCap,
        SyncCompareRefusal.cacheUnavailable ||
        SyncCompareRefusal.producerUnavailable ||
        null => l10n.syncCompareRemoteUnavailable,
      };

  Widget _message(
    BuildContext context,
    String message, {
    bool progress = false,
  }) => _card(
    context,
    children: [
      if (progress) ...[
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 12),
      ],
      Text(message, textAlign: TextAlign.center),
    ],
  );

  Widget _card(BuildContext context, {required List<Widget> children}) =>
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      );
}
