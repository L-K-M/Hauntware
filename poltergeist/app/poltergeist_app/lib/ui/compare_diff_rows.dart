import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import '../theme/compare_diff_colors.dart';
import 'compare_diff_layout.dart';

/// The diff rows' text: the compare view's editor face, unhighlighted.
final _rowStyle = poltergeistMonoTextStyle.copyWith(fontSize: 14, height: 1.35);
final _rowStrut = StrutStyle.fromTextStyle(_rowStyle, forceStrutHeight: true);

/// A digit run long enough to average the face's advance.
final _measureSample = '0' * 10;

const double _activeBarWidth = 3;
const double _markerWidth = 16;
const double _markerSize = 14;
const double _gutterStartPadding = 4;
const double _gutterEndPadding = 8;
const double _textEndPadding = 8;
const double _dividerWidth = 1;

/// How far [CompareRowsController.reveal] puts a row from the top, as a
/// fraction of the viewport: the find bar's own placement for a match.
const double _revealFraction = 1 / 3;
const Duration _revealDuration = Duration(milliseconds: 150);

/// Moves a [CompareDiffRows] list: where its top is, and where to go.
final class CompareRowsController {
  final ScrollController scroll = ScrollController();
  _CompareDiffRowsState? _rows;

  /// The first row at the top of the viewport; 0 before the list lays out.
  int get topVisibleRow => _rows?._topVisibleRow() ?? 0;

  /// Scrolls [row] to a third of the way down the viewport.
  void reveal(int row) => _rows?._reveal(row);

  /// Puts [row] at the top without animating.
  void jumpToRow(int row) => _rows?._jumpToRow(row);

  void scrollByLines(int lines) => _rows?._scrollBy(lines: lines);

  void scrollByPages(double pages) => _rows?._scrollBy(pages: pages);

  void scrollToEdge({required bool end}) => _rows?._scrollToEdge(end: end);

  void dispose() => scroll.dispose();
}

/// The diff as aligned, wrapped rows (06 §6). Rows are as tall as their
/// wrapped text, computed from column counts rather than laid out, so the
/// list knows every row's extent and a jump to a far change builds only
/// the rows it lands on.
final class CompareDiffRows extends StatefulWidget {
  const CompareDiffRows({
    super.key,
    required this.result,
    required this.leftText,
    required this.rightText,
    required this.rows,
    required this.layout,
    required this.activeRegion,
    required this.controller,
  });

  final TextComparisonComputed result;
  final String leftText;
  final String rightText;
  final LineDiffRows rows;
  final LineDiffLayout layout;

  /// The region n / Shift+N last moved to, marked with a bar.
  final int? activeRegion;
  final CompareRowsController controller;

  @override
  State<CompareDiffRows> createState() => _CompareDiffRowsState();
}

/// What one width and text scale make of the rows.
final class _RowMetrics {
  const _RowMetrics({
    required this.width,
    required this.scaler,
    required this.rows,
    required this.lineHeight,
    required this.gutter,
    required this.perRow,
    required this.offsets,
  });

  final double width;
  final TextScaler scaler;
  final LineDiffRows rows;
  final double lineHeight;
  final double gutter;
  final int perRow;

  /// Each row's first visual line ([compareRowOffsets]).
  final Int32List offsets;

  bool fits(double width, TextScaler scaler, LineDiffRows rows) =>
      width == this.width &&
      scaler == this.scaler &&
      identical(rows, this.rows);

  double extentOf(int row) => (offsets[row + 1] - offsets[row]) * lineHeight;

  double offsetOf(int row) => offsets[row] * lineHeight;
}

enum _Tone { unchanged, removed, added }

class _CompareDiffRowsState extends State<CompareDiffRows> {
  _RowMetrics? _metrics;
  (TextScaler, ({double charWidth, double lineHeight}))? _measured;

  @override
  void initState() {
    super.initState();
    widget.controller._rows = this;
  }

  @override
  void didUpdateWidget(CompareDiffRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    if (identical(oldWidget.controller._rows, this)) {
      oldWidget.controller._rows = null;
    }
    widget.controller._rows = this;
  }

  @override
  void dispose() {
    if (identical(widget.controller._rows, this)) {
      widget.controller._rows = null;
    }
    super.dispose();
  }

  ScrollController get _scroll => widget.controller.scroll;

  /// The face's advance and line height at [scaler], measured rather than
  /// computed: the engine may round each strut line to whole pixels, and a
  /// row sized from the unrounded height would clip its last lines.
  ({double charWidth, double lineHeight}) _measure(TextScaler scaler) {
    final cached = _measured;
    if (cached != null && cached.$1 == scaler) return cached.$2;

    final painter = TextPainter(
      text: TextSpan(
        text: [_measureSample, _measureSample].join('\n'),
        style: _rowStyle,
      ),
      strutStyle: _rowStrut,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final measured = (
      charWidth: painter.width / _measureSample.length,
      lineHeight: painter.height / 2,
    );
    painter.dispose();
    _measured = (scaler, measured);
    return measured;
  }

  _RowMetrics _metricsFor(double width, TextScaler scaler) {
    final rows = widget.rows;
    final current = _metrics;
    if (current != null && current.fits(width, scaler, rows)) return current;

    final (:charWidth, :lineHeight) = _measure(scaler);
    final lineCount = math.max(
      widget.result.left.lineCount,
      widget.result.right.lineCount,
    );
    final gutter =
        lineCount.toString().length * charWidth +
        _gutterStartPadding +
        _gutterEndPadding;
    final chrome = _activeBarWidth + _markerWidth + _textEndPadding;
    final textWidth = switch (widget.layout) {
      LineDiffLayout.sideBySide =>
        (width - _dividerWidth) / 2 - gutter - chrome,
      LineDiffLayout.unified => width - 2 * gutter - chrome,
    };
    final perRow = compareColumnsPerRow(
      textWidth: textWidth,
      charWidth: charWidth,
    );
    final next = _RowMetrics(
      width: width,
      scaler: scaler,
      rows: rows,
      lineHeight: lineHeight,
      gutter: gutter,
      perRow: perRow,
      offsets: compareRowOffsets(
        rows,
        widget.result.left,
        widget.result.right,
        perRow,
      ),
    );

    // Keep the row at the top in view when a resize, a text-scale change
    // or a layout switch rewraps everything above it. A layout switch
    // brings its own target, so only same-rows changes re-anchor here.
    if (current != null &&
        identical(current.rows, rows) &&
        _scroll.hasClients) {
      final top = compareRowAtVisualLine(
        current.offsets,
        (_scroll.offset / current.lineHeight).floor(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _jumpTo(next.offsetOf(top));
      });
    }
    _metrics = next;
    return next;
  }

  int _topVisibleRow() {
    final metrics = _metrics;
    if (metrics == null || !_scroll.hasClients) return 0;
    return compareRowAtVisualLine(
      metrics.offsets,
      (_scroll.offset / metrics.lineHeight).floor(),
    );
  }

  void _jumpTo(double offset) {
    final position = _scroll.position;
    _scroll.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  void _reveal(int row) {
    final metrics = _metrics;
    if (metrics == null || !_scroll.hasClients) return;

    final position = _scroll.position;
    final target =
        (metrics.offsetOf(row) - position.viewportDimension * _revealFraction)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: _revealDuration,
      curve: Curves.easeOutCubic,
    );
  }

  void _jumpToRow(int row) {
    final metrics = _metrics;
    if (metrics == null || !_scroll.hasClients) return;
    _jumpTo(metrics.offsetOf(row));
  }

  void _scrollBy({int lines = 0, double pages = 0}) {
    final metrics = _metrics;
    if (metrics == null || !_scroll.hasClients) return;
    final position = _scroll.position;
    _jumpTo(
      position.pixels +
          lines * metrics.lineHeight +
          pages * position.viewportDimension,
    );
  }

  void _scrollToEdge({required bool end}) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _scroll.jumpTo(end ? position.maxScrollExtent : position.minScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _metricsFor(constraints.maxWidth, scaler);
        final uniform = metrics.offsets.last == widget.rows.length;
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: Scrollbar(
              controller: _scroll,
              interactive: true,
              child: ListView.builder(
                controller: _scroll,
                itemCount: widget.rows.length,
                addAutomaticKeepAlives: false,
                itemExtent: uniform ? metrics.lineHeight : null,
                itemExtentBuilder: uniform
                    ? null
                    : (index, _) => index < widget.rows.length
                          ? metrics.extentOf(index)
                          : null,
                itemBuilder: (context, row) => _row(context, metrics, row),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, _RowMetrics metrics, int row) {
    final rows = widget.rows;
    final region = rows.regionAt(row);
    final active = region >= 0 && region == widget.activeRegion;
    final left = rows.leftLineAt(row);
    final right = rows.rightLineAt(row);
    final kind = rows.kindAt(row);
    return switch (widget.layout) {
      LineDiffLayout.sideBySide => _sideBySideRow(
        context,
        metrics,
        kind,
        left,
        right,
        active,
      ),
      LineDiffLayout.unified => _unifiedRow(
        context,
        metrics,
        kind,
        left,
        right,
        active,
      ),
    };
  }

  Widget _sideBySideRow(
    BuildContext context,
    _RowMetrics metrics,
    LineDiffRowKind kind,
    int left,
    int right,
    bool active,
  ) {
    final l10n = AppLocalizations.of(context);
    final divider = ColoredBox(
      color: Theme.of(context).dividerColor,
      child: const SizedBox(width: _dividerWidth),
    );
    if (kind == LineDiffRowKind.unchanged) {
      return Semantics(
        container: true,
        label: l10n.syncCompareRowBoth(left + 1, right + 1),
        value: _spoken(l10n, widget.leftText, widget.result.left, left),
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _half(context, metrics, _Tone.unchanged, left, active),
            ),
            divider,
            Expanded(
              child: _half(context, metrics, _Tone.unchanged, right, active),
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _half(context, metrics, _Tone.removed, left, active)),
        divider,
        Expanded(child: _half(context, metrics, _Tone.added, right, active)),
      ],
    );
  }

  /// One side's half of a side-by-side row: a gap when [line] is -1.
  Widget _half(
    BuildContext context,
    _RowMetrics metrics,
    _Tone tone,
    int line,
    bool active,
  ) {
    final colors = CompareDiffColors.of(context);
    if (line < 0) {
      return ExcludeSemantics(child: ColoredBox(color: colors.gapFill));
    }

    final isLeft = tone != _Tone.added;
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _gutter(context, metrics, line),
        _activeBar(colors, active),
        Expanded(
          child: _text(
            context,
            metrics,
            tone,
            isLeft ? widget.leftText : widget.rightText,
            isLeft ? widget.result.left : widget.result.right,
            line,
          ),
        ),
      ],
    );
    if (tone == _Tone.unchanged) return content;

    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: isLeft
          ? l10n.syncCompareRowLeftOnly(line + 1)
          : l10n.syncCompareRowRightOnly(line + 1),
      value: _spoken(
        l10n,
        isLeft ? widget.leftText : widget.rightText,
        isLeft ? widget.result.left : widget.result.right,
        line,
      ),
      excludeSemantics: true,
      child: content,
    );
  }

  Widget _unifiedRow(
    BuildContext context,
    _RowMetrics metrics,
    LineDiffRowKind kind,
    int left,
    int right,
    bool active,
  ) {
    final l10n = AppLocalizations.of(context);
    final colors = CompareDiffColors.of(context);
    final tone = switch (kind) {
      LineDiffRowKind.leftOnly => _Tone.removed,
      LineDiffRowKind.rightOnly => _Tone.added,
      LineDiffRowKind.unchanged || LineDiffRowKind.changed => _Tone.unchanged,
    };
    final fromLeft = left >= 0;
    final text = fromLeft ? widget.leftText : widget.rightText;
    final measured = fromLeft ? widget.result.left : widget.result.right;
    final line = fromLeft ? left : right;
    return Semantics(
      container: true,
      label: switch (tone) {
        _Tone.unchanged => l10n.syncCompareRowBoth(left + 1, right + 1),
        _Tone.removed => l10n.syncCompareRowLeftOnly(left + 1),
        _Tone.added => l10n.syncCompareRowRightOnly(right + 1),
      },
      value: _spoken(l10n, text, measured, line),
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _gutter(context, metrics, left),
          _gutter(context, metrics, right),
          _activeBar(colors, active),
          Expanded(child: _text(context, metrics, tone, text, measured, line)),
        ],
      ),
    );
  }

  /// A line number, or an empty gutter for -1.
  Widget _gutter(BuildContext context, _RowMetrics metrics, int line) {
    return SizedBox(
      width: metrics.gutter,
      child: line < 0
          ? null
          : Padding(
              padding: const EdgeInsetsDirectional.only(
                start: _gutterStartPadding,
                end: _gutterEndPadding,
              ),
              child: Text(
                (line + 1).toString(),
                textAlign: TextAlign.end,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                strutStyle: _rowStrut,
                style: _rowStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
    );
  }

  Widget _activeBar(CompareDiffColors colors, bool active) => ColoredBox(
    color: active ? colors.activeRegion : Colors.transparent,
    child: const SizedBox(width: _activeBarWidth),
  );

  Widget _text(
    BuildContext context,
    _RowMetrics metrics,
    _Tone tone,
    String source,
    ComparedText measured,
    int line,
  ) {
    final colors = CompareDiffColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (fill, color, marker, icon) = switch (tone) {
      _Tone.unchanged => (null, scheme.onSurface, null, null),
      _Tone.removed => (
        colors.removedFill,
        colors.removedText,
        colors.removedMarker,
        Icons.remove,
      ),
      _Tone.added => (
        colors.addedFill,
        colors.addedText,
        colors.addedMarker,
        Icons.add,
      ),
    };
    final wrapped = wrapCompareLine(
      source,
      measured.lineStart(line),
      measured.lineEnd(line),
      metrics.perRow,
      nonLatin: measured.isNonLatin(line),
    );
    final style = _rowStyle.copyWith(color: color);
    // The row's extent already holds every wrapped line; the overflow box
    // only keeps a sub-pixel rounding difference from reading as an
    // overflow, and the clip holds a fallback glyph wider than counted.
    final body = ClipRect(
      child: OverflowBox(
        alignment: AlignmentDirectional.topStart,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(end: _textEndPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                wrapped.text,
                softWrap: false,
                overflow: TextOverflow.clip,
                strutStyle: _rowStrut,
                style: style,
              ),
              if (wrapped.hiddenCharacters > 0)
                Text(
                  AppLocalizations.of(
                    context,
                  ).syncCompareRowTruncated(wrapped.hiddenCharacters),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: _rowStrut,
                  style: style.copyWith(
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _markerWidth,
          height: metrics.lineHeight,
          child: icon == null
              ? null
              : Icon(icon, size: _markerSize, color: marker),
        ),
        Expanded(child: body),
      ],
    );
    return fill == null ? row : ColoredBox(color: fill, child: row);
  }

  /// A line's text as a screen reader hears it, cut where the row is.
  String? _spoken(
    AppLocalizations l10n,
    String source,
    ComparedText measured,
    int line,
  ) {
    if (line < 0) return null;
    final start = measured.lineStart(line);
    final end = math.min(
      measured.lineEnd(line),
      start + compareMaximumDisplayColumns,
    );
    if (start == end) return l10n.syncCompareRowBlank;
    return source.substring(start, end);
  }
}
