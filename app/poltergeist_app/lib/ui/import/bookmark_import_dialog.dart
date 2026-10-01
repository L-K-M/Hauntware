import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';

typedef BookmarkImportText = String Function(AppLocalizations l10n);
typedef BookmarkImportFailureText =
    String Function(AppLocalizations l10n, Object error);

enum BookmarkImportTextStyle { plain, monospace }

enum BookmarkImportFailureAction { retry, reselect }

enum BookmarkImportDialogExit { imported, cancelled, reselect }

/// The user's explicit exit from the shared import preview.
class BookmarkImportDialogResult {
  const BookmarkImportDialogResult._(this.exit, this.bookmarks);

  const BookmarkImportDialogResult.imported(List<Bookmark> bookmarks)
    : this._(BookmarkImportDialogExit.imported, bookmarks);

  const BookmarkImportDialogResult.cancelled()
    : this._(BookmarkImportDialogExit.cancelled, const []);

  const BookmarkImportDialogResult.reselect()
    : this._(BookmarkImportDialogExit.reselect, const []);

  final BookmarkImportDialogExit exit;
  final List<Bookmark> bookmarks;
}

/// One source-neutral row rendered by the shared D22 preview.
class BookmarkImportDialogRow {
  const BookmarkImportDialogRow({
    required this.id,
    required this.label,
    required this.endpoint,
    required this.username,
    required this.authentication,
    this.authenticationStyle = BookmarkImportTextStyle.plain,
    this.details = const [],
    required this.notes,
    required this.importable,
    required this.importByDefault,
    required this.toBookmark,
  });

  final String id;
  final String label;
  final String endpoint;
  final String username;
  final BookmarkImportText authentication;
  final BookmarkImportTextStyle authenticationStyle;
  final List<BookmarkImportText> details;
  final List<BookmarkImportText> notes;
  final bool importable;
  final bool importByDefault;
  final Bookmark Function(DateTime now) toBookmark;
}

/// A loaded preview. Notices sit below the row list.
class BookmarkImportDialogPreview {
  const BookmarkImportDialogPreview({
    required this.rows,
    this.notices = const [],
  });

  final List<BookmarkImportDialogRow> rows;
  final List<BookmarkImportText> notices;
}

/// Copy and loading behavior that vary by import source.
class BookmarkImportDialogSpec {
  const BookmarkImportDialogSpec({
    required this.title,
    required this.sourceLabel,
    required this.emptyMessage,
    required this.failureMessage,
    required this.load,
    this.failureAction = BookmarkImportFailureAction.retry,
    this.failureActionLabel,
    this.noticeHeading,
    this.cancelLoad,
  }) : assert(
         failureAction != BookmarkImportFailureAction.reselect ||
             failureActionLabel != null,
       );

  final BookmarkImportText title;
  final BookmarkImportText sourceLabel;
  final BookmarkImportText emptyMessage;
  final BookmarkImportFailureText failureMessage;
  final BookmarkImportFailureAction failureAction;
  final BookmarkImportText? failureActionLabel;
  final BookmarkImportText? noticeHeading;
  final Future<BookmarkImportDialogPreview> Function() load;
  final VoidCallback? cancelLoad;
}

/// Shows the common preview, selection, retry, and commit flow used by every
/// D22 importer. Persistence remains with the invoking command.
Future<BookmarkImportDialogResult> showBookmarkImportDialog(
  BuildContext context, {
  required BookmarkImportDialogSpec spec,
  DateTime Function() clock = DateTime.now,
}) async {
  final result = await showDialog<BookmarkImportDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BookmarkImportDialog(spec: spec, clock: clock),
  );

  return result ?? const BookmarkImportDialogResult.cancelled();
}

class _BookmarkImportDialog extends StatefulWidget {
  const _BookmarkImportDialog({required this.spec, required this.clock});

  final BookmarkImportDialogSpec spec;
  final DateTime Function() clock;

  @override
  State<_BookmarkImportDialog> createState() => _BookmarkImportDialogState();
}

enum _LoadPhase { loading, ready, failed }

const _compactWidth = 720.0;
const _desktopDialogWidth = 800.0;
const _loadingDialogWidth = 420.0;
const _maximumListHeight = 360.0;
const _minimumListHeight = 72.0;
const _viewportListHeightFactor = 0.38;
const _desktopRowHeightEstimate = 120.0;
const _compactRowHeightEstimate = 150.0;
const _importColumnWidth = 64.0;
const _hostColumnWidth = 130.0;
const _userColumnWidth = 90.0;
const _cellHorizontalPadding = 8.0;
const _compactCheckboxGap = 4.0;
const _compactContentInset = _importColumnWidth + _compactCheckboxGap;
const _bookmarkMaterializationBatchSize = 128;

class _BookmarkImportDialogState extends State<_BookmarkImportDialog> {
  _LoadPhase _phase = _LoadPhase.loading;
  BookmarkImportDialogPreview? _preview;
  Object? _failure;
  final Set<String> _selectedRowIds = {};
  bool _loadInFlight = false;
  bool _committing = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancelPendingLoad();
    super.dispose();
  }

  Future<void> _load() async {
    // Retry taps share one load so a late result cannot replace a newer
    // selection (09 §3.1's post-await discipline).
    if (_loadInFlight) return;

    final generation = ++_loadGeneration;
    _loadInFlight = true;
    setState(() {
      _failure = null;
      _phase = _LoadPhase.loading;
    });

    final BookmarkImportDialogPreview preview;
    try {
      preview = await widget.spec.load();
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;

      setState(() {
        _failure = error;
        _loadInFlight = false;
        _phase = _LoadPhase.failed;
      });
      return;
    }

    if (!mounted || generation != _loadGeneration) return;

    setState(() {
      _loadInFlight = false;
      _preview = preview;
      _phase = _LoadPhase.ready;
      _selectedRowIds
        ..clear()
        ..addAll(
          preview.rows.where((row) => row.importByDefault).map((row) => row.id),
        );
    });
  }

  void _cancelPendingLoad() {
    if (!_loadInFlight) return;

    _loadGeneration++;
    _loadInFlight = false;
    widget.spec.cancelLoad?.call();
  }

  void _toggle(BookmarkImportDialogRow row, bool? value) {
    if (_committing || value == null) return;

    setState(() {
      value ? _selectedRowIds.add(row.id) : _selectedRowIds.remove(row.id);
    });
  }

  Future<void> _import() async {
    final preview = _preview;
    if (_committing || preview == null || _selectedRowIds.isEmpty) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;

    setState(() => _committing = true);

    final now = widget.clock();
    final selectedRowIds = Set<String>.of(_selectedRowIds);
    final bookmarks = <Bookmark>[];
    for (var index = 0; index < preview.rows.length; index++) {
      final row = preview.rows[index];
      // Never trust checkbox state as the validity boundary.
      if (row.importable && selectedRowIds.contains(row.id)) {
        bookmarks.add(row.toBookmark(now));
      }

      final processedRows = index + 1;
      final hasMoreRows = processedRows < preview.rows.length;
      if (!hasMoreRows ||
          processedRows % _bookmarkMaterializationBatchSize != 0) {
        continue;
      }

      // Give painting and input handling a turn at the maximum 10k-row bound.
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
    }

    if (ModalRoute.of(context)?.isCurrent != true) {
      setState(() => _committing = false);
      return;
    }

    Navigator.pop(
      context,
      BookmarkImportDialogResult.imported(List.unmodifiable(bookmarks)),
    );
  }

  void _cancel() {
    if (_committing) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;

    _cancelPendingLoad();
    Navigator.pop(context, const BookmarkImportDialogResult.cancelled());
  }

  void _reselect() {
    if (_committing) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;

    Navigator.pop(context, const BookmarkImportDialogResult.reselect());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      scrollable: true,
      title: Text(widget.spec.title(l10n)),
      content: switch (_phase) {
        _LoadPhase.loading => _buildLoading(l10n),
        _LoadPhase.failed => _buildFailed(l10n, _failure!),
        _LoadPhase.ready => _buildPreview(context, l10n, _preview!),
      },
      actions: [
        TextButton(
          onPressed: _committing ? null : _cancel,
          child: Text(l10n.sshImportCancel),
        ),
        if (_phase == _LoadPhase.ready)
          FilledButton(
            onPressed: _committing || _selectedRowIds.isEmpty ? null : _import,
            child: Text(
              _selectedRowIds.isEmpty
                  ? l10n.sshImportAction
                  : l10n.sshImportActionCount(_selectedRowIds.length),
            ),
          ),
      ],
    );
  }

  Widget _buildLoading(AppLocalizations l10n) => SizedBox(
    width: _loadingDialogWidth,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sourceLabel(l10n),
        const SizedBox(height: 16),
        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ],
    ),
  );

  Widget _buildFailed(AppLocalizations l10n, Object error) => SizedBox(
    width: _loadingDialogWidth,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sourceLabel(l10n),
        const SizedBox(height: 12),
        Text(widget.spec.failureMessage(l10n, error)),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed:
              widget.spec.failureAction == BookmarkImportFailureAction.retry
              ? _load
              : _reselect,
          child: Text(
            widget.spec.failureActionLabel?.call(l10n) ?? l10n.sshImportRetry,
          ),
        ),
      ],
    ),
  );

  Widget _buildPreview(
    BuildContext context,
    AppLocalizations l10n,
    BookmarkImportDialogPreview preview,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final mediaSize = MediaQuery.sizeOf(context);
    final compact = mediaSize.width <= _compactWidth;
    final maximumListHeight = math.min(
      _maximumListHeight,
      math.max(
        _minimumListHeight,
        mediaSize.height * _viewportListHeightFactor,
      ),
    );
    final rowHeightEstimate = compact
        ? _compactRowHeightEstimate
        : _desktopRowHeightEstimate;
    final listHeight = math.min(
      maximumListHeight,
      math.max(_minimumListHeight, preview.rows.length * rowHeightEstimate),
    );

    return SizedBox(
      width: compact ? double.infinity : _desktopDialogWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sourceLabel(l10n),
          const SizedBox(height: 12),
          if (preview.rows.isEmpty)
            Text(widget.spec.emptyMessage(l10n))
          else ...[
            if (!compact) _header(l10n),
            SizedBox(
              height: listHeight,
              child: ListView.separated(
                primary: false,
                itemCount: preview.rows.length,
                itemBuilder: (context, index) {
                  final row = preview.rows[index];
                  return compact
                      ? _compactRow(l10n, row)
                      : _desktopRow(l10n, row);
                },
                separatorBuilder: (_, _) => const Divider(height: 1),
              ),
            ),
          ],
          if (preview.notices.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (widget.spec.noticeHeading case final heading?)
              Text(
                heading(l10n),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            for (final notice in preview.notices)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  notice(l10n),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _sourceLabel(AppLocalizations l10n) => SelectableText(
    widget.spec.sourceLabel(l10n),
    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
  );

  Widget _header(AppLocalizations l10n) => Row(
    children: [
      SizedBox(
        width: _importColumnWidth,
        child: _headerCell(l10n.sshImportColumnImport),
      ),
      SizedBox(
        width: _hostColumnWidth,
        child: _headerCell(l10n.sshImportColumnHost),
      ),
      Expanded(flex: 6, child: _headerCell(l10n.sshImportColumnEndpoint)),
      SizedBox(
        width: _userColumnWidth,
        child: _headerCell(l10n.sshImportColumnUser),
      ),
      Expanded(flex: 4, child: _headerCell(l10n.sshImportColumnAuth)),
      Expanded(flex: 4, child: _headerCell(l10n.sshImportColumnNotes)),
    ],
  );

  Widget _headerCell(String text) => Padding(
    padding: const EdgeInsets.only(
      left: _cellHorizontalPadding,
      right: _cellHorizontalPadding,
      bottom: 4,
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      maxLines: 1,
      overflow: TextOverflow.fade,
    ),
  );

  Widget _desktopRow(AppLocalizations l10n, BookmarkImportDialogRow row) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: _importColumnWidth, child: _checkbox(l10n, row)),
        SizedBox(
          width: _hostColumnWidth,
          child: _cell(
            Text(row.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        Expanded(flex: 6, child: _cell(_endpointAndDetails(l10n, row))),
        SizedBox(
          width: _userColumnWidth,
          child: _cell(
            Text(row.username, maxLines: 1, overflow: TextOverflow.fade),
          ),
        ),
        Expanded(flex: 4, child: _cell(_authentication(l10n, row))),
        Expanded(flex: 4, child: _cell(_buildNotes(l10n, row.notes))),
      ],
    );
  }

  Widget _compactRow(AppLocalizations l10n, BookmarkImportDialogRow row) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _checkbox(l10n, row),
              const SizedBox(width: _compactCheckboxGap),
              Expanded(
                child: Text(
                  row.label,
                  style: textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: _compactContentInset,
              right: _compactCheckboxGap,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _endpointAndDetails(l10n, row),
                const SizedBox(height: 4),
                Text(row.username, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                _authentication(l10n, row),
                if (row.notes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _buildNotes(l10n, row.notes),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _checkbox(AppLocalizations l10n, BookmarkImportDialogRow row) {
    return MergeSemantics(
      child: Semantics(
        label: l10n.sshImportRowSemantics(row.label),
        child: Checkbox(
          value: _selectedRowIds.contains(row.id),
          onChanged: !_committing && row.importable
              ? (value) => _toggle(row, value)
              : null,
        ),
      ),
    );
  }

  Widget _endpointAndDetails(
    AppLocalizations l10n,
    BookmarkImportDialogRow row,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          row.endpoint,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        for (final detail in row.details)
          Text(
            detail(l10n),
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Widget _authentication(AppLocalizations l10n, BookmarkImportDialogRow row) {
    return Text(
      row.authentication(l10n),
      style: row.authenticationStyle == BookmarkImportTextStyle.monospace
          ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
          : null,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _cell(Widget child) => Padding(
    padding: const EdgeInsets.only(
      left: _cellHorizontalPadding,
      right: _cellHorizontalPadding,
      top: 4,
      bottom: 4,
    ),
    child: Align(alignment: Alignment.centerLeft, child: child),
  );

  Widget _buildNotes(AppLocalizations l10n, List<BookmarkImportText> notes) {
    if (notes.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: [for (final note in notes) _noteChip(note(l10n))],
    );
  }

  Widget _noteChip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(4),
      color: Theme.of(context).colorScheme.secondaryContainer,
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    ),
  );
}
