import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:ghost_fonts/ghost_fonts.dart' show resolveMonoFamily;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/editor_font.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import '../theme/compare_diff_colors.dart';
import 'compare_diff_layout.dart';

/// The diff rows' text at [fontSize] in [font]: the compare view's editor
/// face, unhighlighted. Spacing is pinned so an ambient text theme cannot
/// widen the columns the wrap counts.
TextStyle _rowStyleAt(double fontSize, EditorFont font) =>
    font.ligatures.applyTo(
      poltergeistMonoTextStyle.copyWith(
        fontFamily: switch (font.chosenFamily) {
          final family? => resolveMonoFamily(family),
          null => null,
        },
        fontSize: fontSize,
        height: 1.35,
        letterSpacing: 0,
        wordSpacing: 0,
      ),
    );

/// A digit run long enough to average the face's advance.
final _measureSample = '0' * 10;

/// The fewest columns a text area keeps: one wide character.
const int _minimumTextColumns = 2;

const double _activeBarWidth = 3;

/// The −/+ marker's room beside its glyph, which is as large as the text.
const double _markerPadding = 2;
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
    required this.fontSize,
    this.font = EditorFont.standard,
  });

  final TextComparisonComputed result;
  final String leftText;
  final String rightText;
  final LineDiffRows rows;
  final LineDiffLayout layout;

  /// The region n / Shift+N last moved to, marked with a bar.
  final int? activeRegion;
  final CompareRowsController controller;

  /// The rows' text size in logical pixels: the editor's text size.
  final double fontSize;

  /// The rows' font: the editor's.
  final EditorFont font;

  @override
  State<CompareDiffRows> createState() => _CompareDiffRowsState();
}

/// What one width, text scale and text style make of the rows.
final class _RowMetrics {
  const _RowMetrics({
    required this.width,
    required this.scaler,
    required this.style,
    required this.rows,
    required this.lineHeight,
    required this.gutter,
    required this.perRow,
    required this.offsets,
  });

  final double width;
  final TextScaler scaler;
  final TextStyle style;
  final LineDiffRows rows;
  final double lineHeight;
  final double gutter;
  final int perRow;

  /// Each row's first visual line ([compareRowOffsets]).
  final Int32List offsets;

  bool fits(
    double width,
    TextScaler scaler,
    TextStyle style,
    LineDiffRows rows,
  ) =>
      width == this.width &&
      scaler == this.scaler &&
      style == this.style &&
      identical(rows, this.rows);

  int get rowCount => offsets.length - 1;

  double get totalExtent => offsets.last * lineHeight;

  double extentOf(int row) => (offsets[row + 1] - offsets[row]) * lineHeight;

  double offsetOf(int row) => offsets[row] * lineHeight;

  /// The row holding [scrollOffset]; an offset on a row boundary belongs to
  /// the row it starts.
  int rowAt(double scrollOffset) =>
      compareRowAtVisualLine(offsets, _visualLine(scrollOffset).floor());

  /// The last row that starts before [scrollOffset].
  int rowBefore(double scrollOffset) => compareRowAtVisualLine(
    offsets,
    math.max(0, _visualLine(scrollOffset).ceil() - 1),
  );

  /// [scrollOffset] in visual lines, snapped to a whole line within the
  /// framework's precision so boundaries do not drift by one.
  double _visualLine(double scrollOffset) {
    final lines = scrollOffset / lineHeight;
    final whole = lines.roundToDouble();
    return (lines - whole).abs() * lineHeight < precisionErrorTolerance
        ? whole
        : lines;
  }
}

enum _Tone { unchanged, removed, added }

class _CompareDiffRowsState extends State<CompareDiffRows> {
  _RowMetrics? _metrics;
  (TextScaler, TextStyle, ({double charWidth, double lineHeight}))? _measured;
  late TextStyle _rowStyle;
  late StrutStyle _rowStrut;

  @override
  void initState() {
    super.initState();
    _styleRows();
    widget.controller._rows = this;
  }

  @override
  void didUpdateWidget(CompareDiffRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fontSize != widget.fontSize ||
        oldWidget.font != widget.font) {
      _styleRows();
    }
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

  void _styleRows() {
    _rowStyle = _rowStyleAt(widget.fontSize, widget.font);
    _rowStrut = StrutStyle.fromTextStyle(_rowStyle, forceStrutHeight: true);
  }

  double get _markerWidth => widget.fontSize + _markerPadding;

  /// The face's advance and line height at [scaler], measured in [style],
  /// the row style as the ambient text style completes it, rather than
  /// computed: the engine may round each strut line to whole pixels, and a
  /// row sized from the unrounded height would clip its last lines.
  ({double charWidth, double lineHeight}) _measure(
    TextScaler scaler,
    TextStyle style,
  ) {
    final cached = _measured;
    if (cached != null && cached.$1 == scaler && cached.$2 == style) {
      return cached.$3;
    }

    final painter = TextPainter(
      text: TextSpan(
        text: [_measureSample, _measureSample].join('\n'),
        style: style,
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
    _measured = (scaler, style, measured);
    return measured;
  }

  _RowMetrics _metricsFor(double width, TextScaler scaler, TextStyle style) {
    final rows = widget.rows;
    final current = _metrics;
    if (current != null && current.fits(width, scaler, style, rows)) {
      return current;
    }

    final (:charWidth, :lineHeight) = _measure(scaler, style);
    final lineCount = math.max(
      widget.result.left.lineCount,
      widget.result.right.lineCount,
    );
    final gutters = widget.layout == LineDiffLayout.unified ? 2 : 1;
    final area = switch (widget.layout) {
      LineDiffLayout.sideBySide => (width - _dividerWidth) / 2,
      LineDiffLayout.unified => width,
    };
    final chrome = _activeBarWidth + _markerWidth + _textEndPadding;
    // The gutter gives way before the text does, so a squeezed column
    // still holds a wide character and the row's fixed parts never
    // overflow it.
    final gutter = math.max(
      0.0,
      math.min(
        lineCount.toString().length * charWidth +
            _gutterStartPadding +
            _gutterEndPadding,
        (area - chrome - _minimumTextColumns * charWidth) / gutters,
      ),
    );
    final perRow = compareColumnsPerRow(
      textWidth: area - gutters * gutter - chrome,
      charWidth: charWidth,
    );
    final rewrapped =
        current == null ||
        !identical(current.rows, rows) ||
        current.perRow != perRow ||
        current.lineHeight != lineHeight;
    final next = _RowMetrics(
      width: width,
      scaler: scaler,
      style: style,
      rows: rows,
      lineHeight: lineHeight,
      gutter: gutter,
      perRow: perRow,
      offsets: rewrapped
          ? compareRowOffsets(
              rows,
              widget.result.left,
              widget.result.right,
              perRow,
            )
          : current.offsets,
    );

    // A resize, or a change of text scale or size, that rewraps the rows
    // keeps the reader at the same place in the row at the top. A layout switch brings its
    // own target from the view.
    if (current != null &&
        rewrapped &&
        identical(current.rows, rows) &&
        _scroll.hasClients) {
      final offset = _scroll.offset;
      final top = current.rowAt(offset);
      final within = current.extentOf(top) == 0
          ? 0.0
          : (offset - current.offsetOf(top)) / current.extentOf(top);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _jumpTo(next.offsetOf(top) + within * next.extentOf(top));
      });
    }
    _metrics = next;
    return next;
  }

  int _topVisibleRow() {
    final metrics = _metrics;
    if (metrics == null || !_scroll.hasClients) return 0;
    return metrics.rowAt(_scroll.offset);
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
    final style = DefaultTextStyle.of(context).style.merge(_rowStyle);
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _metricsFor(constraints.maxWidth, scaler, style);
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: Scrollbar(
              controller: _scroll,
              interactive: true,
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  _CompareRowsSliver(
                    metrics: metrics,
                    delegate: SliverChildBuilderDelegate(
                      (context, row) => _row(context, metrics, row),
                      childCount: widget.rows.length,
                      addAutomaticKeepAlives: false,
                    ),
                  ),
                ],
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
    final left = _line(metrics, isLeft: true, rows.leftLineAt(row));
    final right = _line(metrics, isLeft: false, rows.rightLineAt(row));
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

  /// One side's line of a row, wrapped once for both drawing and speech;
  /// null for a gap.
  _RowLine? _line(_RowMetrics metrics, int line, {required bool isLeft}) {
    if (line < 0) return null;
    final source = isLeft ? widget.leftText : widget.rightText;
    final measured = isLeft ? widget.result.left : widget.result.right;
    final start = measured.lineStart(line);
    final end = measured.lineEnd(line);
    return (
      line: line,
      source: source,
      start: start,
      end: end,
      wrapped: wrapCompareLine(
        source,
        start,
        end,
        metrics.perRow,
        fallbackGlyphs: measured.mayUseFallbackGlyphs(line),
      ),
    );
  }

  Widget _sideBySideRow(
    BuildContext context,
    _RowMetrics metrics,
    LineDiffRowKind kind,
    _RowLine? left,
    _RowLine? right,
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
        label: l10n.syncCompareRowBoth(left!.line + 1, right!.line + 1),
        value: _spoken(l10n, left),
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

  /// One side's half of a side-by-side row: a gap when [line] is null.
  Widget _half(
    BuildContext context,
    _RowMetrics metrics,
    _Tone tone,
    _RowLine? line,
    bool active,
  ) {
    final colors = CompareDiffColors.of(context);
    if (line == null) {
      return ExcludeSemantics(child: ColoredBox(color: colors.gapFill));
    }

    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _gutter(context, metrics, line.line),
        _activeBar(colors, active),
        Expanded(child: _text(context, metrics, tone, line.wrapped)),
      ],
    );
    if (tone == _Tone.unchanged) return content;

    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: tone == _Tone.removed
          ? l10n.syncCompareRowLeftOnly(line.line + 1)
          : l10n.syncCompareRowRightOnly(line.line + 1),
      value: _spoken(l10n, line),
      excludeSemantics: true,
      child: content,
    );
  }

  Widget _unifiedRow(
    BuildContext context,
    _RowMetrics metrics,
    LineDiffRowKind kind,
    _RowLine? left,
    _RowLine? right,
    bool active,
  ) {
    final l10n = AppLocalizations.of(context);
    final colors = CompareDiffColors.of(context);
    final tone = switch (kind) {
      LineDiffRowKind.leftOnly => _Tone.removed,
      LineDiffRowKind.rightOnly => _Tone.added,
      LineDiffRowKind.unchanged || LineDiffRowKind.changed => _Tone.unchanged,
    };
    final shown = (left ?? right)!;
    return Semantics(
      container: true,
      label: switch (tone) {
        _Tone.unchanged => l10n.syncCompareRowBoth(
          left!.line + 1,
          right!.line + 1,
        ),
        _Tone.removed => l10n.syncCompareRowLeftOnly(left!.line + 1),
        _Tone.added => l10n.syncCompareRowRightOnly(right!.line + 1),
      },
      value: _spoken(l10n, shown),
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _gutter(context, metrics, left?.line ?? -1),
          _gutter(context, metrics, right?.line ?? -1),
          _activeBar(colors, active),
          Expanded(child: _text(context, metrics, tone, shown.wrapped)),
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
    CompareWrappedLine wrapped,
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
                  // On a wash only the row's text colour is held to 4.5:1;
                  // the muted caption colour falls to 2.4:1 on some presets.
                  style: style.copyWith(
                    fontStyle: FontStyle.italic,
                    color: fill == null ? scheme.onSurfaceVariant : color,
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
              : Icon(icon, size: widget.fontSize, color: marker),
        ),
        Expanded(child: body),
      ],
    );
    return fill == null ? row : ColoredBox(color: fill, child: row);
  }

  /// A line's text as a screen reader hears it: what the row draws, and how
  /// much it leaves out.
  String _spoken(AppLocalizations l10n, _RowLine line) {
    if (line.start == line.end) return l10n.syncCompareRowBlank;
    final wrapped = line.wrapped;
    final shown = line.source.substring(line.start, wrapped.shownEnd);
    if (wrapped.hiddenCharacters == 0) return shown;
    return [
      shown,
      l10n.syncCompareRowTruncated(wrapped.hiddenCharacters),
    ].join(' ');
  }
}

/// One side's line in a row: where it sits in its text, and how it wraps.
typedef _RowLine = ({
  int line,
  String source,
  int start,
  int end,
  CompareWrappedLine wrapped,
});

/// A fixed-extent sliver that answers every offset question from the rows'
/// prefix sums. Flutter's builder-backed list walks every earlier row for
/// each child it lays out and estimates the scroll extent from the rows it
/// has built, so far jumps landed short and frames slowed with depth; here
/// each lookup is an index or a binary search and the extent is exact.
class _CompareRowsSliver extends SliverMultiBoxAdaptorWidget {
  const _CompareRowsSliver({required super.delegate, required this.metrics});

  final _RowMetrics metrics;

  @override
  _RenderCompareRows createRenderObject(BuildContext context) =>
      _RenderCompareRows(
        childManager: context as SliverMultiBoxAdaptorElement,
        metrics: metrics,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCompareRows renderObject,
  ) {
    renderObject.metrics = metrics;
  }
}

class _RenderCompareRows extends RenderSliverFixedExtentBoxAdaptor {
  _RenderCompareRows({required super.childManager, required this._metrics});

  _RowMetrics _metrics;

  set metrics(_RowMetrics value) {
    if (identical(value, _metrics)) return;
    _metrics = value;
    markNeedsLayout();
  }

  @override
  double? get itemExtent => null;

  @override
  ItemExtentBuilder get itemExtentBuilder => _extentOf;

  double? _extentOf(int row, SliverLayoutDimensions dimensions) =>
      row < _metrics.rowCount ? _metrics.extentOf(row) : null;

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _metrics.offsetOf(math.min(index, _metrics.rowCount));

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _metrics.rowAt(scrollOffset);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _metrics.rowBefore(scrollOffset);

  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _metrics.totalExtent;

  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _metrics.totalExtent;
}
