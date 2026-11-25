import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/log_display.dart';
import '../../l10n/app_localizations.dart';
import '../time_display.dart' show TimeDisplayScope;
import 'log_level.dart';
import 'log_row_counts.dart';
import 'log_rows_sliver.dart';
import 'log_search.dart';
import 'log_tail_scroll.dart';
import 'log_text.dart';
import 'log_text_layout.dart';
import 'log_view_controller.dart';

export '../../controllers/log_display.dart' show LogWrap;

/// The device's log display (A11Y-12) for the log views under it; the
/// composition root puts it above every route, and a test may leave it
/// out, which draws logs at [kLogTextSizeDefault] without wrapping.
class LogDisplayScope extends InheritedNotifier<LogDisplaySettings> {
  const LogDisplayScope({
    super.key,
    required LogDisplaySettings display,
    required super.child,
  }) : super(notifier: display);

  /// The display for [context], which rebuilds when it changes, or null
  /// when none is provided.
  static LogDisplay? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LogDisplayScope>()
      ?.notifier
      ?.value;
}

/// The space left and right of every row.
const double _rowPadding = 8;

/// Single precision's unit roundoff: the engine adds a line's glyph
/// advances in it, so n advances can sum to n times one advance plus up
/// to n of these of the total.
const double _singlePrecisionRoundoff = 1 / (1 << 24);

/// The rows kept above a search match the view scrolls to.
const int _revealContext = 2;

/// How far past the row's width a match's glyphs may end and still count
/// as shown, for the engine's rounding, in logical pixels.
const double _shownTolerance = 0.01;

/// Line and paragraph separators, which would break a field's row.
final _rowBreaks = RegExp('[\u2028\u2029]');

/// The log viewer of 03 §10.8 over a [LogViewController]: a lazily built
/// list of rows a whole number of lines each, measured when [wrap] is on,
/// follow with pause on scroll (LOG-02), level colours with a gutter icon,
/// and keyboard operation with a visible focus ring (03 §10.6, MVP).
///
/// Following keeps the newest line in sight. Scrolling away from it pauses
/// following, and the view then stays on the lines it shows while new
/// lines arrive and old ones leave the buffer. When rows change, as when
/// the width, the level gutter, the text scale or [wrap] changes, the line
/// at the top stays there with its share above the edge kept to within a
/// row, so a line that starts at the edge still does; when the content
/// below no longer fills the view, the view ends at the newest line
/// instead, still paused. Scrolling back to the newest line, End, or the
/// Follow button resumes following. Keys: Up and Down move a line, Page
/// Up and Page Down a page, Home goes to the oldest line, End follows.
///
/// A journal line's row (LOG-01) starts with its unit and PID, and a tap,
/// or Enter on the focused row, pauses following and shows its other
/// fields beneath it, one row each without wrap. Fields that open or close
/// above the top edge move no line in sight, and a row in sight keeps its
/// place while its fields open. With a [search], its matches are
/// highlighted, and each step to a match pauses following and scrolls the
/// match's row into sight (LOG-05). Without wrap, a current match the row
/// would not show, past its ellipsis or on a later line of a journal
/// MESSAGE, shows in a window of the row that starts with an ellipsis
/// ([logMatchWindowStart]); the row stays one line high, so stepping
/// moves no row, and other matches past the ellipsis stay out of sight.
///
/// A journal line's row starts with its time when the entry has one, and
/// a container line's row (CTX-01) with its time and its stream, `stdout`
/// or `stderr` ([LogViewController.containerOf]), the latter in the error
/// colour; a screen reader hears the stream's name. Times show in the zone
/// the time display chooses for [LogViewController.serverId] (A11Y-07).
class LogView extends StatefulWidget {
  const LogView({
    super.key,
    required this.controller,
    this.wrap,
    this.levelOf,
    this.fieldsOf,
    this.search,
  });

  final LogViewController controller;

  /// Whether long lines wrap; null follows the device's log display
  /// ([LogDisplayScope]), off without one.
  final LogWrap? wrap;

  /// The level of a line, for its colour and gutter icon. Without it no
  /// line has a level and the view has no gutter.
  final LogLevel? Function(LogLine line)? levelOf;

  /// The fields a tap on a line shows beneath it, or null for a line
  /// without: a journal entry's by default, a container's JSON line's
  /// keys (CTX-05) where the caller says so.
  final List<(String, String?)>? Function(LogLine line)? fieldsOf;

  /// The search whose matches the view highlights, over [controller].
  final LogSearch? search;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  late final _vertical = TailScrollController(
    () => widget.controller.following.value,
  );
  final _focusNode = FocusNode(debugLabel: 'LogView');
  bool _focusHighlight = false;

  /// Whether long lines wrap now: [LogView.wrap], else the device's.
  var _wrap = LogWrap.off;

  late AppLocalizations _l10n;
  TextLayout? _text;

  /// The row count of each held entry without wrap, one a line plus its
  /// fields' rows, and with it, wrapped rows, both kept in step with the
  /// controller and the fields shown, so a wrap toggle keeps the counts
  /// measured before it.
  late RowCounts _lineRows;
  late RowCounts _wrappedRows;

  /// The counts [LogView.wrap] lays out with, and the other mode's.
  RowCounts get _rows => _wrap == LogWrap.on ? _wrappedRows : _lineRows;
  RowCounts get _otherRows => _wrap == LogWrap.on ? _lineRows : _wrappedRows;

  /// The fields of each journal row that shows them, by seq.
  final _expanded = <int, List<(String, String?)>>{};

  /// The search's [LogSearch.steps] last brought into sight.
  int _steps = 0;

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
    _listenSearch(widget.search);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _l10n = AppLocalizations.of(context);
    final previous = _text;
    _text = TextLayout.of(
      context,
      previous,
      LogDisplayScope.maybeOf(context)?.textSize,
    );
    if (previous == null) {
      _wrap = _wrapFor(widget);
      _resetRows();
      return;
    }
    if (!identical(previous, _text)) {
      _invalidateRows();
      // The offset counts lines or rows of the old height.
      final scale = _text!.lineHeight / previous.lineHeight;
      if (scale != 1) _holdLines((pixels) => pixels * scale);
    }
    _applyWrap(_wrapFor(widget));
  }

  /// Whether [view] wraps: its own choice, else the device's.
  LogWrap _wrapFor(LogView view) =>
      view.wrap ?? LogDisplayScope.maybeOf(context)?.wrap ?? LogWrap.off;

  void _applyWrap(LogWrap wrap) {
    if (wrap == _wrap) return;
    _wrap = wrap;
    // The offset counts the old mode's rows, now the other counts.
    final previous = _otherRows;
    _holdLines((pixels) => _offsetIn(previous, pixels));
  }

  @override
  void didUpdateWidget(LogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.search != widget.search) {
      oldWidget.search?.removeListener(_onSearch);
      _listenSearch(widget.search);
    }
    if (oldWidget.controller != widget.controller) {
      _unlisten(oldWidget.controller);
      _listen(widget.controller);
      _expanded.clear();
      _wrap = _wrapFor(widget);
      _resetRows();
      return;
    }

    _applyWrap(_wrapFor(widget));
    if ((oldWidget.levelOf == null) != (widget.levelOf == null)) {
      // The gutter came or went, and with it some of every row's width.
      _invalidateRows();
    }
  }

  @override
  void dispose() {
    _unlisten(widget.controller);
    widget.search?.removeListener(_onSearch);
    _vertical.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _listen(LogViewController controller) {
    controller.addListener(_onLines);
    controller.following.addListener(_onFollowing);
  }

  void _unlisten(LogViewController controller) {
    controller.removeListener(_onLines);
    controller.following.removeListener(_onFollowing);
  }

  void _listenSearch(LogSearch? search) {
    search?.addListener(_onSearch);
    _steps = search?.steps ?? 0;
  }

  void _resetRows() {
    RowCounts counts(LogWrap wrap) => RowCounts(
      (index, crossAxisExtent) => _measureRows(wrap, index, crossAxisExtent),
      (index, crossAxisExtent) => _estimateRows(wrap, index, crossAxisExtent),
    )..sync(widget.controller);
    _lineRows = counts(LogWrap.off);
    _wrappedRows = counts(LogWrap.on);
  }

  void _invalidateRows() {
    _lineRows.invalidate();
    _wrappedRows.invalidate();
  }

  void _onLines() {
    final removed = _rows.sync(widget.controller);
    _otherRows.sync(widget.controller);
    _expanded.removeWhere((seq, _) => seq < widget.controller.firstSeq);
    // While paused, keep the lines in sight where they are: the entries
    // that left the buffer took their extent from above them. When the
    // lines in sight left too, the offset stops at the oldest line left,
    // but an animation's path still moves by all of it, so it ends on the
    // line it was aimed at.
    if (removed.entries > 0 && !widget.controller.following.value) {
      final position = _vertical.hasClients ? _vertical.position : null;
      if (position is TailScrollPosition && position.hasPixels) {
        final extent = removed.rows * _text!.lineHeight;
        position.shiftBy(-math.min(extent, position.pixels), path: -extent);
      }
    }
    setState(() {});
  }

  void _onSearch() {
    final search = widget.search!;
    final match = search.current;
    if (search.steps != _steps && match != null) {
      _steps = search.steps;
      widget.controller.pause();
      _reveal(match.seq - widget.controller.firstSeq);
    }
    setState(() {});
  }

  /// Scrolls entry [index] into sight, with a few rows above it, unless
  /// all of it is in sight already.
  void _reveal(int index) {
    if (!_vertical.hasClients) return;
    final position = _vertical.position;
    if (!position.hasContentDimensions) return;

    final line = _text!.lineHeight;
    final top = _rows.rowsBefore(index) * line;
    final bottom = top + _rows.rowsOf(index) * line;
    final viewEnd = position.pixels + position.viewportDimension;
    if (top >= position.pixels && bottom <= viewEnd) return;

    _jump(position, top - _revealContext * line - position.pixels);
  }

  /// Shows or hides [line]'s fields. Showing them pauses following, so
  /// the row holds still while they open beneath it, and in a paused view
  /// fields above the top edge move no line in sight ([_fieldsMoved]). A
  /// tap that lands after [line] left the buffer, before its row is
  /// rebuilt, does nothing.
  void _toggleFields(LogLine line) {
    if (line.seq < widget.controller.firstSeq) return;

    setState(() {
      if (_expanded.remove(line.seq) == null) {
        _expanded[line.seq] = _fieldsOf(line)!;
        widget.controller.pause();
      }
    });
    final index = line.seq - widget.controller.firstSeq;
    final start = _rows.rowsBefore(index);
    final rows = _rows.rowsOf(index);
    final change = _rows.remeasure(index);
    // The other mode's count follows, for a wrap toggle to map through.
    _otherRows.remeasure(index);
    final height = _text!.lineHeight;
    _holdLines(
      (pixels) => _fieldsMoved(pixels / height, start, rows, change) * height,
    );
  }

  /// Moves a paused view's offset to [convert] of it when what the offset
  /// counts changes, or rows above it come or go, so the same lines stay
  /// in sight; a following view moves to the newest line anyway.
  void _holdLines(double Function(double pixels) convert) {
    if (widget.controller.following.value || !_vertical.hasClients) return;

    final position = _vertical.position;
    if (position is! TailScrollPosition || !position.hasPixels) return;
    position.shiftBy(convert(position.pixels) - position.pixels);
  }

  /// The offset [pixels] into the rows of [previous] as an offset into
  /// [_rows] on the same entry and as far into its rows, for when what the
  /// rows count changes: lines and fields without wrap, wrapped rows with
  /// it.
  double _offsetIn(RowCounts previous, double pixels) {
    if (previous.length == 0 || _rows.length == 0) return pixels;

    final line = _text!.lineHeight;
    final at = math.max(0.0, pixels / line);
    final index = previous.indexAtRow((at + rowTolerance).floor());
    final into = (at - previous.rowsBefore(index)) / previous.rowsOf(index);
    return (_rows.rowsBefore(index) +
            into.clamp(0.0, 1.0) * _rows.rowsOf(index)) *
        line;
  }

  /// Where an offset [at] rows down goes when the entry from row [start]
  /// changes by [change] rows from [rows] as its fields open or close
  /// beneath its line. Past the entry it moves by as much, so the lines in
  /// sight hold still. In the rows the entry keeps it stays, so a row in
  /// sight keeps its place: keeping its share, as [_offsetIn] does, would
  /// push the line of a row partly above the edge out of sight. In fields
  /// that closed it moves to the entry's last row, keeping its place in
  /// its row.
  static double _fieldsMoved(double at, int start, int rows, int change) {
    final end = start + rows;
    if (at + rowTolerance >= end) return at + change;

    final kept = end + change;
    if (at + rowTolerance < kept) return at;
    return kept - 1 + math.max(0.0, at - (at + rowTolerance).floor());
  }

  void _onFollowing() {
    setState(() {});
    if (!widget.controller.following.value || !_vertical.hasClients) return;

    final position = _vertical.position;
    if (!position.hasContentDimensions) return;
    if (position.pixels < position.maxScrollExtent - endTolerance) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  /// Pauses when the user scrolls away from the newest line and follows
  /// again when they return to it. Following itself never sends an update:
  /// the scroll position corrects itself during layout.
  bool _onScrollUpdate(ScrollUpdateNotification notification) {
    if (notification.depth != 0) return false;

    final atEnd = notification.metrics.extentAfter < endTolerance;
    if (atEnd != widget.controller.following.value) {
      atEnd ? widget.controller.follow() : widget.controller.pause();
    }
    return false;
  }

  /// A cut line's note, or the note for a journal MESSAGE not sent.
  String? _note(LogLine line) {
    if (line.journal?.messageNotSent ?? false) return _l10n.logJournalNotSent;

    final length = line.originalLength;
    return length == null ? null : _l10n.logLineCut(length);
  }

  /// The rows of a journal row's fields: `NAME=value` each, on one row
  /// without wrap, and a note for the fields the buffer left out.
  List<String> _fieldLines(LogLine line, List<(String, String?)> fields) => [
    for (final (name, value) in fields)
      value == null
          ? _l10n.logJournalFieldNotSent(name)
          : parseSgr(
              '$name=$value'.replaceAll('\n', ' '),
            ).text.replaceAll(_rowBreaks, ' '),
    if (line.journal?.fieldsLeftOut case final left? when left > 0)
      _l10n.logJournalFieldsLeftOut(left),
  ];

  List<(String, String?)>? _fieldsOf(LogLine line) =>
      widget.fieldsOf?.call(line) ?? line.journal?.fields;

  bool get _hasGutter => widget.levelOf != null;

  double _textWidth(double rowWidth, TextLayout text) =>
      rowWidth - 2 * _rowPadding - (_hasGutter ? text.gutter : 0);

  /// The rows entry [index] takes in [wrap] mode in a row [crossAxisExtent]
  /// wide: one a line and one a field shown without wrap. With wrap, each
  /// wraps to one row when it is all Latin-1 and an upper bound of its
  /// width, the engine's rounding included, fits ([logTextCells]), and is
  /// laid out otherwise; a line with a note is laid out for it. A
  /// dropped-lines record keeps to one row.
  int _measureRows(LogWrap wrap, int index, double crossAxisExtent) {
    final entry = widget.controller[index];
    if (entry is! LogLine) return 1;

    final fields = switch (_expanded[entry.seq]) {
      final kept? => _fieldLines(entry, kept),
      null => const <String>[],
    };
    if (wrap == LogWrap.off) return 1 + fields.length;

    final text = _text!;
    final width = _textWidth(crossAxisExtent, text);
    bool fits(String plain, double width) {
      final cells = logTextCells(plain);
      if (cells == null) return false;
      // One roundoff more than the cells, for the width's own rounding.
      final bound =
          cells * text.advance * (1 + (cells + 1) * _singlePrecisionRoundoff);
      return bound <= width;
    }

    var rows =
        _note(entry) == null && fits(widget.controller.rowText(entry), width)
        ? 1
        : _layoutRows(_lineSpan(entry, text), width, text);
    final fieldWidth = width - text.fieldIndent;
    for (final field in fields) {
      rows += fits(field, fieldWidth)
          ? 1
          : _layoutRows(
              TextSpan(text: field, style: text.base),
              fieldWidth,
              text,
            );
    }
    return rows;
  }

  /// The rows [span] wraps to at [width].
  int _layoutRows(TextSpan span, double width, TextLayout text) {
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      strutStyle: text.strut,
      textScaler: text.scaler,
    )..layout(maxWidth: math.max(0, width));
    final rows = math.max(1, (painter.height / text.lineHeight).round());
    painter.dispose();
    return rows;
  }

  /// A guess at the rows of entry [index] in [wrap] mode until a layout
  /// measures it, plus one a field it shows: one without wrap; with it,
  /// its code units, escapes included, at the [crossAxisExtent] last
  /// measured at, and never more rows than code units.
  int _estimateRows(LogWrap wrap, int index, double? crossAxisExtent) {
    final entry = widget.controller[index];
    if (entry is! LogLine) return 1;

    final fields = switch (_expanded[entry.seq]) {
      final kept? => _fieldLines(entry, kept).length,
      null => 0,
    };
    if (wrap == LogWrap.off || crossAxisExtent == null) return 1 + fields;

    final text = _text!;
    final width = _textWidth(crossAxisExtent, text);
    final container = widget.controller.containerOf(entry);
    final units =
        entry.text.length +
        (entry.journal?.source?.length ?? 0) +
        logJournalTimeLength(entry) +
        (container == null ? 0 : logContainerSourceLength(container));
    if (width <= 0 || units == 0) return 1 + fields;
    return (units * text.advance / width).ceil().clamp(1, units) + fields;
  }

  TextSpan _lineSpan(LogLine line, TextLayout text, {int windowStart = 0}) {
    final search = widget.search;
    final container = widget.controller.containerOf(line);
    return logLineSpan(
      line,
      palette: text.palette,
      base: text.base,
      level: widget.levelOf?.call(line),
      note: _note(line),
      container: container,
      streamLabel: container == null
          ? null
          : _l10n.logContainerStream(container.stream.name),
      matches: search?.matchesIn(line) ?? const [],
      currentMatch: search?.currentIndexIn(line),
      zoneOffset: widget.controller.zoneOffset,
      windowStart: windowStart,
    );
  }

  /// Where [line]'s row starts without wrap in a row [width] wide, so that
  /// it shows its current match: 0 when the row shows the match from its
  /// start, as it does when the match's glyphs lie on its first line and
  /// end before the row's width, less the ellipsis when the line is wider.
  /// Laid out as drawn, so any glyph's width counts.
  int _windowStart(LogLine line, TextLayout text, double width) {
    final search = widget.search!;
    final matches = search.matchesIn(line);
    final index = search.currentIndexIn(line);
    if (index == null || index >= matches.length) return 0;

    final match = matches[index];
    final painter = TextPainter(
      text: _lineSpan(line, text),
      textDirection: TextDirection.ltr,
      strutStyle: text.strut,
      textScaler: text.scaler,
    )..layout();
    final firstLine = painter.computeLineMetrics().first.width;
    final limit =
        (firstLine <= width + _shownTolerance ? width : width - text.ellipsis) +
        _shownTolerance;
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: match.start, extentOffset: match.end),
    );
    painter.dispose();
    final shown =
        boxes.isNotEmpty &&
        boxes.every(
          (box) => box.top < text.lineHeight / 2 && box.right <= limit,
        );
    if (shown) return 0;

    return logMatchWindowStart(
      widget.controller.rowText(line),
      match,
      cells: (width / text.advance).floor(),
    );
  }

  /// Hands the controller the zone offset the time display chooses for its
  /// server, after this frame: the controller notifies a search over it,
  /// whose field may not rebuild during this build. Until then the rows
  /// keep the offset they were searched at, so what the view draws and
  /// what the search matched never differ.
  void _syncZone() {
    final controller = widget.controller;
    final serverId = controller.serverId;
    final offset = serverId == null
        ? null
        : TimeDisplayScope.serverOffsetOf(context, serverId);
    if (offset == controller.zoneOffset) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller == controller) {
        controller.setZoneOffset(offset);
      }
    });
  }

  void _scroll(_LogScroll scroll) {
    if (scroll == _LogScroll.end) {
      widget.controller.follow();
      _onFollowing();
      return;
    }

    if (!_vertical.hasClients) return;
    final position = _vertical.position;
    final line = _text!.lineHeight;
    final page = math.max(line, position.viewportDimension - line);
    _jump(position, switch (scroll) {
      _LogScroll.lineUp => -line,
      _LogScroll.lineDown => line,
      _LogScroll.pageUp => -page,
      _LogScroll.pageDown => page,
      _LogScroll.top => double.negativeInfinity,
      // Unreachable: End follows above. Kept for exhaustiveness.
      _LogScroll.end => double.infinity,
    });
  }

  static void _jump(ScrollPosition position, double delta) {
    if (!position.hasContentDimensions) return;
    position.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncZone();
    final text = _text!;
    final following = widget.controller.following.value;
    final colors = Theme.of(context).colorScheme;

    final rows = SliverChildBuilderDelegate(
      (context, index) => _row(index, text),
      childCount: widget.controller.length,
      // Rows are keyed by seq, so a row keeps its element, and with it
      // focus, while entries leave the buffer and every index shifts.
      findChildIndexCallback: (key) {
        final index = (key as ValueKey<int>).value - widget.controller.firstSeq;
        return index >= 0 && index < widget.controller.length ? index : null;
      },
    );
    final list = NotificationListener<ScrollUpdateNotification>(
      onNotification: _onScrollUpdate,
      child: CustomScrollView(
        controller: _vertical,
        semanticChildCount: widget.controller.length,
        // One sliver in both modes: a row whose fields open or close keeps
        // its element, and with it keyboard and accessibility focus.
        slivers: [
          LogRows(
            rows: _rows,
            revision: _rows.revision,
            lineHeight: text.lineHeight,
            delegate: rows,
          ),
        ],
      ),
    );

    return FocusableActionDetector(
      focusNode: _focusNode,
      shortcuts: _shortcuts,
      actions: {
        _LogScrollIntent: CallbackAction<_LogScrollIntent>(
          onInvoke: (intent) => _scroll(intent.scroll),
        ),
      },
      onShowFocusHighlight: (value) => setState(() => _focusHighlight = value),
      child: Semantics(
        container: true,
        label: _l10n.logViewLabel,
        child: Listener(
          onPointerDown: (_) => _focusNode.requestFocus(),
          child: ColoredBox(
            color: text.palette.background,
            child: Stack(
              children: [
                // Journal rows' ink and focus draw over the background.
                Positioned.fill(
                  child: Material(type: MaterialType.transparency, child: list),
                ),
                if (!following)
                  PositionedDirectional(
                    end: 16,
                    bottom: 16,
                    child: FilledButton.tonalIcon(
                      onPressed: () => _scroll(_LogScroll.end),
                      icon: const Icon(Icons.arrow_downward),
                      label: Text(_l10n.logFollow),
                    ),
                  ),
                if (_focusHighlight)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: colors.primary, width: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // RichText, not Text: Text would merge the ambient DefaultTextStyle in,
  // which the measured extents do not see.
  Widget _richText(TextSpan span, TextLayout text) => RichText(
    text: span,
    textDirection: TextDirection.ltr,
    strutStyle: text.strut,
    textScaler: text.scaler,
    softWrap: _wrap == LogWrap.on,
    maxLines: _wrap == LogWrap.off ? 1 : null,
    overflow: _wrap == LogWrap.off ? TextOverflow.ellipsis : TextOverflow.clip,
  );

  Widget _row(int index, TextLayout text) {
    final entry = widget.controller[index];
    final level = entry is LogLine ? widget.levelOf?.call(entry) : null;
    final fields = _expanded[entry.seq];
    final Widget body = switch (entry) {
      LogLine() when fields != null => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _line(entry, text),
          for (final field in _fieldLines(entry, fields))
            Padding(
              padding: EdgeInsetsDirectional.only(start: text.fieldIndent),
              child: _richText(
                TextSpan(
                  text: field,
                  style: text.base.merge(text.palette.sourceStyle),
                ),
                text,
              ),
            ),
        ],
      ),
      LogLine() => _line(entry, text),
      LogDroppedLines(:final count) => Row(
        children: [
          Icon(
            Icons.more_horiz,
            size: text.iconSize,
            color: text.palette.markerStyle.color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _l10n.logDroppedLines(count),
              style: text.base.merge(text.palette.markerStyle),
              strutStyle: text.strut,
              textScaler: text.scaler,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    };

    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _rowPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_hasGutter)
            SizedBox(
              width: text.gutter,
              height: text.lineHeight,
              child: _levelIcon(level, text),
            ),
          Expanded(child: body),
        ],
      ),
    );
    final key = ValueKey(entry.seq);
    if (entry is! LogLine || _fieldsOf(entry) == null) {
      return MergeSemantics(key: key, child: row);
    }

    return MergeSemantics(
      key: key,
      child: Semantics(
        expanded: fields != null,
        onTapHint: fields == null
            ? _l10n.logJournalShowFields
            : _l10n.logJournalHideFields,
        child: InkWell(onTap: () => _toggleFields(entry), child: row),
      ),
    );
  }

  /// [line]'s own row, without its fields. Without wrap, the row of the
  /// current match lays out for its width, to window the row around the
  /// match when it would not show ([_windowStart]); it stays one line.
  Widget _line(LogLine line, TextLayout text) {
    if (_wrap == LogWrap.on || widget.search?.currentIndexIn(line) == null) {
      return _richText(_lineSpan(line, text), text);
    }

    return LayoutBuilder(
      builder: (context, constraints) => _richText(
        _lineSpan(
          line,
          text,
          windowStart: _windowStart(line, text, constraints.maxWidth),
        ),
        text,
      ),
    );
  }

  Widget? _levelIcon(LogLevel? level, TextLayout text) {
    final (icon, label) = switch (level) {
      LogLevel.error => (Icons.error_outline, _l10n.logLevelError),
      LogLevel.warning => (Icons.warning_amber, _l10n.logLevelWarning),
      LogLevel.debug => (Icons.bug_report_outlined, _l10n.logLevelDebug),
      LogLevel.info || null => (null, null),
    };
    if (icon == null) return null;

    return Icon(
      icon,
      size: text.iconSize,
      color: text.palette.levelColor(level),
      semanticLabel: label,
    );
  }
}

/// The view's keys and what each does.
enum _LogScroll {
  lineUp(LogicalKeyboardKey.arrowUp),
  lineDown(LogicalKeyboardKey.arrowDown),
  pageUp(LogicalKeyboardKey.pageUp),
  pageDown(LogicalKeyboardKey.pageDown),
  top(LogicalKeyboardKey.home),
  end(LogicalKeyboardKey.end);

  const _LogScroll(this.key);

  final LogicalKeyboardKey key;
}

final class _LogScrollIntent extends Intent {
  const _LogScrollIntent(this.scroll);

  final _LogScroll scroll;
}

final _shortcuts = <ShortcutActivator, Intent>{
  for (final scroll in _LogScroll.values)
    SingleActivator(scroll.key): _LogScrollIntent(scroll),
};
