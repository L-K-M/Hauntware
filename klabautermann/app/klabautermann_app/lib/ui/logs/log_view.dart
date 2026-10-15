import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show nearEqual;
import 'package:flutter/rendering.dart'
    show
        ItemExtentBuilder,
        RenderSliverFixedExtentBoxAdaptor,
        SliverConstraints,
        SliverGeometry,
        SliverLayoutDimensions;
import 'package:flutter/services.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'log_level.dart';
import 'log_text.dart';
import 'log_view_controller.dart';

/// Whether a [LogView] wraps long lines.
enum LogWrap {
  /// One row a line, every row the same extent; a long line is cut at the
  /// view's edge with an ellipsis.
  off,

  /// Long lines wrap; a line is measured once per width when a layout
  /// shows it, and keeps an earlier count or an estimate until then.
  on,
}

/// The log text size; A11Y-12 (v1) makes it a setting from 10 to 18 px.
const double _fontSize = 13;

/// Line height as a multiple of the font size.
const double _lineHeightFactor = 1.35;

/// The space left and right of every row.
const double _rowPadding = 8;

/// How far from the newest line still counts as at it, in logical pixels.
const double _endTolerance = 1;

/// Single precision's unit roundoff: the engine adds a line's glyph
/// advances in it, so n advances can sum to n times one advance plus up
/// to n of these of the total.
const double _singlePrecisionRoundoff = 1 / (1 << 24);

/// The log viewer of 03 §10.8 over a [LogViewController]: a lazily built
/// list with a fixed line extent when [wrap] is off and measured row
/// counts when it is on, follow with pause on scroll (LOG-02), level
/// colours with a gutter icon, and keyboard operation with a visible
/// focus ring (03 §10.6, MVP).
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
class LogView extends StatefulWidget {
  const LogView({
    super.key,
    required this.controller,
    this.wrap = LogWrap.off,
    this.levelOf,
  });

  final LogViewController controller;
  final LogWrap wrap;

  /// The level of a line, for its colour and gutter icon. Without it no
  /// line has a level and the view has no gutter.
  final LogLevel? Function(LogLine line)? levelOf;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  late final _vertical = _TailScrollController(
    () => widget.controller.following.value,
  );
  final _focusNode = FocusNode(debugLabel: 'LogView');
  bool _focusHighlight = false;

  late AppLocalizations _l10n;
  _TextLayout? _text;

  /// The wrapped row count of each held entry, kept in step with the
  /// controller whether or not [LogView.wrap] is on.
  late _RowCounts _rows;

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _l10n = AppLocalizations.of(context);
    final previous = _text;
    _text = _TextLayout.of(context, previous);
    if (previous == null) {
      _resetRows();
    } else if (!identical(previous, _text)) {
      _rows.invalidate();
      // The offset counts lines or rows of the old height.
      final scale = _text!.lineHeight / previous.lineHeight;
      if (scale != 1) _holdLines((pixels) => pixels * scale);
    }
  }

  @override
  void didUpdateWidget(LogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unlisten(oldWidget.controller);
      _listen(widget.controller);
      _resetRows();
      return;
    }

    if (oldWidget.wrap != widget.wrap) {
      _holdLines((pixels) => _offsetIn(widget.wrap, pixels));
    }
    if ((oldWidget.levelOf == null) != (widget.levelOf == null)) {
      // The gutter came or went, and with it some of every row's width.
      _rows.invalidate();
    }
  }

  @override
  void dispose() {
    _unlisten(widget.controller);
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

  void _resetRows() {
    _rows = _RowCounts(_measureRows);
    _rows.sync(widget.controller, _estimateRows);
  }

  void _onLines() {
    final removed = _rows.sync(widget.controller, _estimateRows);
    // While paused, keep the lines in sight where they are: the entries
    // that left the buffer took their extent from above them. When the
    // lines in sight left too, the offset stops at the oldest line left,
    // but an animation's path still moves by all of it, so it ends on the
    // line it was aimed at.
    if (removed.entries > 0 && !widget.controller.following.value) {
      final position = _vertical.hasClients ? _vertical.position : null;
      if (position is _TailScrollPosition && position.hasPixels) {
        final rows = widget.wrap == LogWrap.on ? removed.rows : removed.entries;
        final extent = rows * _text!.lineHeight;
        position.shiftBy(-math.min(extent, position.pixels), path: -extent);
      }
    }
    setState(() {});
  }

  /// Moves a paused view's offset to [convert] of it when what the offset
  /// counts changes, so the same lines stay in sight; a following view
  /// moves to the newest line anyway.
  void _holdLines(double Function(double pixels) convert) {
    if (widget.controller.following.value || !_vertical.hasClients) return;

    final position = _vertical.position;
    if (position is! _TailScrollPosition || !position.hasPixels) return;
    position.shiftBy(convert(position.pixels) - position.pixels);
  }

  /// The offset [pixels], counted in the other mode, as an offset counted
  /// in [wrap] mode on the same entry and as far into it: without wrap an
  /// offset counts lines, with wrap the rows of [_rows].
  double _offsetIn(LogWrap wrap, double pixels) {
    if (_rows.length == 0) return pixels;

    final line = _text!.lineHeight;
    final at = math.max(0.0, pixels / line);
    if (wrap == LogWrap.on) {
      final index = math.min(at.floor(), _rows.length - 1);
      final into = (at - index).clamp(0.0, 1.0) * _rows.rowsOf(index);
      return (_rows.rowsBefore(index) + into) * line;
    }
    final index = _rows.indexAtRow((at + _rowTolerance).floor());
    final into = (at - _rows.rowsBefore(index)) / _rows.rowsOf(index);
    return (index + into.clamp(0.0, 1.0)) * line;
  }

  void _onFollowing() {
    setState(() {});
    if (!widget.controller.following.value || !_vertical.hasClients) return;

    final position = _vertical.position;
    if (!position.hasContentDimensions) return;
    if (position.pixels < position.maxScrollExtent - _endTolerance) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  /// Pauses when the user scrolls away from the newest line and follows
  /// again when they return to it. Following itself never sends an update:
  /// the scroll position corrects itself during layout.
  bool _onScrollUpdate(ScrollUpdateNotification notification) {
    if (notification.depth != 0) return false;

    final atEnd = notification.metrics.extentAfter < _endTolerance;
    if (atEnd != widget.controller.following.value) {
      atEnd ? widget.controller.follow() : widget.controller.pause();
    }
    return false;
  }

  String? _cutNote(LogLine line) {
    final length = line.originalLength;
    return length == null ? null : _l10n.logLineCut(length);
  }

  bool get _hasGutter => widget.levelOf != null;

  double _textWidth(double rowWidth, _TextLayout text) =>
      rowWidth - 2 * _rowPadding - (_hasGutter ? text.gutter : 0);

  /// The rows entry [index] wraps to in a row [crossAxisExtent] wide: one
  /// when it is all Latin-1 and an upper bound of its width, the engine's
  /// rounding included, fits ([logTextCells]), otherwise laid out. A
  /// dropped-lines record keeps to one row; a cut line is laid out for its
  /// note.
  int _measureRows(int index, double crossAxisExtent) {
    final entry = widget.controller[index];
    if (entry is! LogLine) return 1;

    final text = _text!;
    final width = _textWidth(crossAxisExtent, text);
    final cells = entry.truncated
        ? null
        : logTextCells(parseSgr(entry.text).text);
    // One roundoff more than the cells, for the width's own rounding.
    final bound = cells == null
        ? null
        : cells * text.advance * (1 + (cells + 1) * _singlePrecisionRoundoff);
    if (bound != null && bound <= width) return 1;

    final painter = TextPainter(
      text: _lineSpan(entry, text),
      textDirection: TextDirection.ltr,
      strutStyle: text.strut,
      textScaler: text.scaler,
    )..layout(maxWidth: math.max(0, width));
    final rows = math.max(1, (painter.height / text.lineHeight).round());
    painter.dispose();
    return rows;
  }

  /// A guess at the rows of [entry] until a layout measures it: its code
  /// units, escapes included, at the width last measured, and never more
  /// rows than code units.
  int _estimateRows(LogEntry entry) {
    final crossAxisExtent = _rows.crossAxisExtent;
    if (entry is! LogLine || crossAxisExtent == null) return 1;

    final text = _text!;
    final width = _textWidth(crossAxisExtent, text);
    final units = entry.text.length;
    if (width <= 0 || units == 0) return 1;
    return (units * text.advance / width).ceil().clamp(1, units);
  }

  TextSpan _lineSpan(LogLine line, _TextLayout text) => logLineSpan(
    line,
    palette: text.palette,
    base: text.base,
    level: widget.levelOf?.call(line),
    cutNote: _cutNote(line),
  );

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
      _LogScroll.top || _LogScroll.end => double.negativeInfinity,
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
    final text = _text!;
    final following = widget.controller.following.value;
    final colors = Theme.of(context).colorScheme;

    final rows = SliverChildBuilderDelegate(
      (context, index) => _row(index, text),
      childCount: widget.controller.length,
    );
    final list = NotificationListener<ScrollUpdateNotification>(
      onNotification: _onScrollUpdate,
      child: CustomScrollView(
        controller: _vertical,
        semanticChildCount: widget.controller.length,
        slivers: [
          switch (widget.wrap) {
            LogWrap.off => SliverFixedExtentList(
              itemExtent: text.lineHeight,
              delegate: rows,
            ),
            LogWrap.on => _WrappedRows(
              rows: _rows,
              revision: _rows.revision,
              lineHeight: text.lineHeight,
              delegate: rows,
            ),
          },
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
                Positioned.fill(child: list),
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

  Widget _row(int index, _TextLayout text) {
    final entry = widget.controller[index];
    final level = entry is LogLine ? widget.levelOf?.call(entry) : null;
    final Widget body = switch (entry) {
      // RichText, not Text: Text would merge the ambient DefaultTextStyle
      // in, which the measured extents do not see.
      LogLine() => RichText(
        text: _lineSpan(entry, text),
        textDirection: TextDirection.ltr,
        strutStyle: text.strut,
        textScaler: text.scaler,
        softWrap: widget.wrap == LogWrap.on,
        maxLines: widget.wrap == LogWrap.off ? 1 : null,
        overflow: widget.wrap == LogWrap.off
            ? TextOverflow.ellipsis
            : TextOverflow.clip,
      ),
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

    return MergeSemantics(
      child: Padding(
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
      ),
    );
  }

  Widget? _levelIcon(LogLevel? level, _TextLayout text) {
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

/// What every row's layout depends on: the theme, the text scale and the
/// locale (a cut line's note), the monospace style and its strut, and the
/// line height and glyph advance measured from them. A new instance means
/// every measured row is stale.
final class _TextLayout {
  _TextLayout._({
    required this.theme,
    required this.scaler,
    required this.locale,
    required this.base,
    required this.strut,
    required this.lineHeight,
    required this.advance,
  }) : palette = LogPalette.fromTheme(theme);

  /// The layout for [context], or [previous] when nothing it depends on
  /// changed.
  static _TextLayout of(BuildContext context, _TextLayout? previous) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.localeOf(context);
    if (previous != null &&
        previous.theme == theme &&
        previous.scaler == scaler &&
        previous.locale == locale) {
      return previous;
    }

    final families = klabautermannThemeStyle.monoFontFamilies;
    final base = TextStyle(
      fontFamily: families.first,
      fontFamilyFallback: families.skip(1).toList(growable: false),
      fontSize: _fontSize,
      height: _lineHeightFactor,
    );
    // Every row is a whole number of these lines, whatever glyphs or
    // fallback fonts it holds, so extents can be computed.
    final strut = StrutStyle.fromTextStyle(base, forceStrutHeight: true);
    double measure(String sample, {TextStyle? style, bool height = false}) {
      final painter = TextPainter(
        text: TextSpan(text: sample, style: style ?? base),
        textDirection: TextDirection.ltr,
        strutStyle: strut,
        textScaler: scaler,
      )..layout();
      final value = height ? painter.height : painter.width;
      painter.dispose();
      return value;
    }

    return _TextLayout._(
      theme: theme,
      scaler: scaler,
      locale: locale,
      base: base,
      strut: strut,
      lineHeight: measure(' ', height: true),
      // The advance of a Latin-1 glyph in a monospace font, regular or
      // bold; for a proportional fallback, one of its widest.
      advance: math.max(
        measure('W'),
        measure('W', style: base.copyWith(fontWeight: FontWeight.bold)),
      ),
    );
  }

  final ThemeData theme;
  final TextScaler scaler;
  final Locale locale;
  final LogPalette palette;
  final TextStyle base;
  final StrutStyle strut;
  final double lineHeight;
  final double advance;

  double get iconSize => scaler.scale(_fontSize);

  /// The level icon's column.
  double get gutter => iconSize + 6;
}

/// The slots a [_RowCounts] starts with.
const int _minRowSlots = 1024;

/// The row count of every entry a [LogView] holds, for wrap mode, with the
/// rows before any entry found in O(log n) through a Fenwick tree, so a
/// frame costs the same however many lines are held (03 §11.4).
///
/// Only the entries a layout shows, and as many rows above its offset, are
/// measured, once per width, font and locale ([measure]); the others keep
/// the count of their last measurement or, before one, an estimate. A
/// width change therefore lays out only the lines near the view. When
/// measuring an entry above the scroll offset changes its count, the
/// layout moves the offset by the difference, and the offset keeps its
/// share of the entry it is in to within a row ([_keepShare]), so the
/// lines in sight hold still.
final class _RowCounts {
  _RowCounts(this._measure);

  /// The exact rows of the entry at an index in a row of a cross-axis
  /// extent.
  final int Function(int index, double crossAxisExtent) _measure;

  // Entry i lives in slot _front + i; the slots before _front belong to
  // evicted entries, whose rows _frontRows cancels. _tree is the Fenwick
  // tree over _counts, 1-based.
  var _counts = Int32List(_minRowSlots);
  var _measuredIn = Int32List(_minRowSlots);
  var _tree = Int32List(_minRowSlots + 1);
  int _front = 0;
  int _frontRows = 0;
  int _length = 0;
  int _total = 0;
  int _firstSeq = 0;

  /// Counts measured in an older generation are estimates; 0 is never.
  int _generation = 1;
  double? _crossAxisExtent;

  /// Changes whenever the rows would lay out differently, so the sliver
  /// lays out again even when the entry count stays the same.
  int get revision => _revision;
  int _revision = 0;

  int get length => _length;

  /// The rows of every held entry.
  int get total => _total;

  /// The cross-axis extent last measured at, or null before a layout.
  double? get crossAxisExtent => _crossAxisExtent;

  int rowsOf(int index) => _counts[_front + index];

  int rowsBefore(int index) => _prefix(_front + index) - _frontRows;

  /// The entry holding [row], clamped to the held entries.
  int indexAtRow(int row) {
    if (_length == 0 || row <= 0) return 0;

    // The most slots whose rows end at or before row: the next one holds
    // it.
    var rest = row + _frontRows;
    var slots = 0;
    for (var step = 1 << (_counts.length.bitLength - 1); step > 0; step >>= 1) {
      final next = slots + step;
      if (next <= _counts.length && _tree[next] <= rest) {
        slots = next;
        rest -= _tree[next];
      }
    }
    return (slots - _front).clamp(0, _length - 1);
  }

  /// Brings the counts in step with [controller], guessing new entries'
  /// rows with [estimate], and returns the entries that left from the
  /// front and their rows.
  ({int entries, int rows}) sync(
    LogViewController controller,
    int Function(LogEntry entry) estimate,
  ) {
    var entries = 0;
    var rows = 0;
    while (_length > 0 && _firstSeq < controller.firstSeq) {
      final gone = _counts[_front++];
      _frontRows += gone;
      _total -= gone;
      _length--;
      _firstSeq++;
      entries++;
      rows += gone;
    }
    if (_length == 0) _firstSeq = controller.firstSeq;

    final end = controller.firstSeq + controller.length;
    for (var seq = _firstSeq + _length; seq < end; seq++) {
      _append(estimate(controller[seq - controller.firstSeq]));
    }
    _revision++;
    return (entries: entries, rows: rows);
  }

  /// Makes every count an estimate, for a new font, scale, locale or
  /// gutter.
  void invalidate() {
    _generation++;
    _revision++;
  }

  /// Measures the entries a layout of rows [top] to [bottom] shows, with
  /// its scroll offset at row [anchor], and as many rows above that
  /// offset, and returns the rows to move the offset by so the entry at it
  /// stays there and the offset keeps its share of it to within a row.
  int measure(
    double top,
    double anchor,
    double bottom,
    double crossAxisExtent,
  ) {
    if (crossAxisExtent != _crossAxisExtent) {
      _crossAxisExtent = crossAxisExtent;
      _generation++;
    }
    if (_length == 0) return 0;

    // A layout that reaches the newest entry may be a following view's,
    // which then moves to the new end. Measuring the rows the end shows
    // now keeps that to one more pass; otherwise every screenful the
    // counts grew by would cost one, past the viewport's limit of ten.
    final reachesEnd = bottom >= _total;

    // Below the entry at the offset, a new count moves nothing above; above
    // it, every change moves the offset by as much, and the offset keeps
    // its share of that entry's own rows to within a row.
    final first = indexAtRow((anchor + _rowTolerance).floor());
    final firstRow = rowsBefore(first);
    var end = firstRow;
    var firstChange = 0;
    for (var i = first; i < _length && end < bottom; i++) {
      final change = _measureAt(i);
      if (i == first) firstChange = change;
      end += rowsOf(i);
    }

    var correction = _keepShare(anchor - firstRow, rowsOf(first), firstChange);
    if (reachesEnd) {
      var tail = 0;
      for (var i = _length - 1; i >= 0 && tail < bottom - top; i--) {
        final change = _measureAt(i);
        if (i < first) correction += change;
        tail += rowsOf(i);
      }
    }
    // Above the offset, as many rows as the layout spans, though its cache
    // reaches less far: a page up from here then lands on measured rows,
    // and their counts below the new offset cannot push lines not yet seen
    // out past the view.
    var above = anchor - firstRow;
    for (var i = first - 1; i >= 0 && above < bottom - top; i--) {
      correction += _measureAt(i);
      above += rowsOf(i);
    }
    return correction;
  }

  /// The whole rows to move an offset [into] rows into an entry by when
  /// the entry's count changed by [change] to [rows], so the offset keeps
  /// its share of the entry to within a row: it keeps its place in its
  /// row and moves to the row of the entry nearest its old share, so an
  /// offset at the entry's start stays there. Kept as many rows in, the
  /// offset would land past the end of an entry that a wider row shrank,
  /// and the lines in sight below would scroll away unseen; an entry that
  /// grew would push them out of the view instead.
  static int _keepShare(double into, int rows, int change) {
    final before = rows - change;
    final row = (into + _rowTolerance).floor();
    // An offset past the last entry, as in an overscroll, has no share.
    if (change == 0 || row < 0 || row >= before) return 0;
    final target = (into * rows / before - (into - row)).round();
    return target.clamp(0, rows - 1) - row;
  }

  /// Measures the entry at [index] unless this generation did, and returns
  /// how its count changed.
  int _measureAt(int index) {
    final slot = _front + index;
    if (_measuredIn[slot] == _generation) return 0;

    _measuredIn[slot] = _generation;
    final change = _measure(index, _crossAxisExtent!) - _counts[slot];
    if (change != 0) {
      _counts[slot] += change;
      _total += change;
      _add(slot, change);
    }
    return change;
  }

  void _append(int rows) {
    if (_front + _length == _counts.length) _compact();
    final slot = _front + _length++;
    _counts[slot] = rows;
    _measuredIn[slot] = 0;
    _total += rows;
    _add(slot, rows);
  }

  /// Moves the held entries to the start of new slots, twice as many as
  /// they need, so moving costs O(1) a line over time.
  void _compact() {
    final size = math.max(_minRowSlots, 2 * (_length + 1));
    _counts = Int32List(size)..setRange(0, _length, _counts, _front);
    _measuredIn = Int32List(size)..setRange(0, _length, _measuredIn, _front);
    _tree = Int32List(size + 1);
    for (var k = 1; k <= size; k++) {
      _tree[k] += _counts[k - 1];
      final parent = k + (k & -k);
      if (parent <= size) _tree[parent] += _tree[k];
    }
    _front = 0;
    _frontRows = 0;
  }

  void _add(int slot, int change) {
    for (var k = slot + 1; k < _tree.length; k += k & -k) {
      _tree[k] += change;
    }
  }

  /// The rows of slots 0 to [slots] - 1.
  int _prefix(int slots) {
    var sum = 0;
    for (var k = slots; k > 0; k -= k & -k) {
      sum += _tree[k];
    }
    return sum;
  }
}

/// How close to a row boundary a scroll offset counts as on it, in rows.
const double _rowTolerance = 1e-6;

/// The rows of a wrapping [LogView]: a sliver like `SliverVariedExtentList`
/// whose offsets and indexes come from [_RowCounts] in O(log n), where
/// that list sums every extent before an index, and which measures the
/// entries a layout shows before laying them out.
final class _WrappedRows extends SliverMultiBoxAdaptorWidget {
  const _WrappedRows({
    required super.delegate,
    required this.rows,
    required this.revision,
    required this.lineHeight,
  });

  final _RowCounts rows;

  /// [rows]' revision when built: a new one lays the sliver out again.
  final int revision;
  final double lineHeight;

  @override
  _RenderWrappedRows createRenderObject(BuildContext context) =>
      _RenderWrappedRows(
        childManager: context as SliverMultiBoxAdaptorElement,
        rows: rows,
        revision: revision,
        lineHeight: lineHeight,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWrappedRows renderObject,
  ) {
    renderObject
      ..rows = rows
      ..revision = revision
      ..lineHeight = lineHeight;
  }
}

final class _RenderWrappedRows extends RenderSliverFixedExtentBoxAdaptor {
  _RenderWrappedRows({
    required super.childManager,
    required this._rows,
    required this._revision,
    required this._lineHeight,
  });

  _RowCounts _rows;
  set rows(_RowCounts value) {
    if (identical(value, _rows)) return;
    _rows = value;
    markNeedsLayout();
  }

  int _revision;
  set revision(int value) {
    if (value == _revision) return;
    _revision = value;
    markNeedsLayout();
  }

  double _lineHeight;
  set lineHeight(double value) {
    if (value == _lineHeight) return;
    _lineHeight = value;
    markNeedsLayout();
  }

  @override
  double? get itemExtent => null;

  @override
  ItemExtentBuilder get itemExtentBuilder => _extentOf;

  double? _extentOf(int index, SliverLayoutDimensions dimensions) =>
      index < _rows.length ? _rows.rowsOf(index) * _lineHeight : null;

  /// The row [offset] falls in, an offset on a boundary taking the row
  /// after it, as the fixed-extent list rounds.
  int _rowAt(double offset) {
    final rows = offset / _lineHeight;
    final nearest = rows.round();
    if ((rows - nearest).abs() * _lineHeight < precisionErrorTolerance) {
      return nearest;
    }
    return rows.floor();
  }

  /// The last row before [offset].
  int _rowBefore(double offset) {
    final rows = offset / _lineHeight - 1;
    final nearest = rows.round();
    if ((rows - nearest).abs() * _lineHeight < precisionErrorTolerance) {
      return math.max(0, nearest);
    }
    return math.max(0, rows.ceil());
  }

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _rows.rowsBefore(math.min(index, _rows.length)) * _lineHeight;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _rows.indexAtRow(_rowAt(scrollOffset));

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _rows.indexAtRow(_rowBefore(scrollOffset));

  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _rows.total * _lineHeight;

  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _rows.total * _lineHeight;

  @override
  void performLayout() {
    final constraints = this.constraints;
    final top = constraints.scrollOffset + constraints.cacheOrigin;
    final correction = _rows.measure(
      top / _lineHeight,
      constraints.scrollOffset / _lineHeight,
      (top + constraints.remainingCacheExtent) / _lineHeight,
      constraints.crossAxisExtent,
    );
    if (correction != 0) {
      geometry = SliverGeometry(
        scrollOffsetCorrection: correction * _lineHeight,
      );
      return;
    }
    super.performLayout();
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

/// A scroll controller whose position stays on the newest line while
/// [_following] says so: when the content or the viewport changes, the
/// position moves to the end during layout, in the same frame, without a
/// scroll notification.
final class _TailScrollController extends ScrollController {
  _TailScrollController(this._following) : super(keepScrollOffset: false);

  final bool Function() _following;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TailScrollPosition(
    _following,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

final class _TailScrollPosition extends ScrollPositionWithSingleContext {
  _TailScrollPosition(
    this._following, {
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final bool Function() _following;

  /// Moves the offset by [delta] as a layout correction does and lays out
  /// again. A drag carries on from the new offset; a fling, whose
  /// simulation sets absolute offsets, starts again from it at its current
  /// velocity; an animation, which also sets absolute offsets, moves the
  /// rest of its path with the lines ([_ShiftableScrollAnimation]) by
  /// [path], or by [delta] when it is null. [path] differs from [delta]
  /// when the offset cannot move as far as the lines did. Sends no scroll
  /// notification: the user did not scroll.
  void shiftBy(double delta, {double? path}) {
    correctBy(delta);
    final current = activity;
    if (current is BallisticScrollActivity) goBallistic(current.velocity);
    if (current is _ShiftableScrollAnimation) {
      current.shiftBy(delta, path: path ?? delta);
    }
    notifyListeners();
  }

  /// Animates as the inherited animateTo does, but with an animation that
  /// [shiftBy] can move. The desktop scrollbar's track click animates this
  /// way.
  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (nearEqual(to, pixels, physics.toleranceFor(this).distance)) {
      jumpTo(to);
      return Future<void>.value();
    }

    final animation = _ShiftableScrollAnimation(
      this,
      from: pixels,
      to: to,
      toEnd: hasContentDimensions && to > maxScrollExtent - _endTolerance,
      duration: duration,
      curve: curve,
      vsync: context.vsync,
    );
    beginActivity(animation);
    return animation.done;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // Content that shrank under an idle offset (wrapped rows after a wider
    // layout, a long line leaving) moves the offset to the new end at once,
    // following or not. The physics would leave an offset that a layout
    // correction moved past the end and then spring back, and the scroll
    // updates of that spring would resume following. Past the end during a
    // gesture or fling is a bounce, left to the physics.
    final shrank =
        pixels > maxScrollExtent && !(activity?.isScrolling ?? false);
    if (shrank) correctPixels(maxScrollExtent);
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (!shrank && (!_following() || pixels >= maxScrollExtent)) {
      return accepted;
    }

    correctPixels(maxScrollExtent);
    // The viewport laid out its children for the old offset: lay out again.
    return false;
  }
}

/// A scroll animation whose path moves with the lines when old lines leave
/// the buffer during it, so it ends on the line it was aimed at (the
/// oldest line left, if that one left too), or on the newest line when it
/// was aimed at the end, without a jump on the way.
///
/// A plain [DrivenScrollActivity] sets the offsets of its own path each
/// frame, which would undo the shift and land the view off its target by
/// as many lines as left. Restarting the animation instead would start its
/// curve and duration again on every batch.
final class _ShiftableScrollAnimation extends DrivenScrollActivity {
  _ShiftableScrollAnimation(
    super.delegate, {
    required super.from,
    required super.to,
    required this._toEnd,
    required super.duration,
    required super.curve,
    required super.vsync,
  }) : _to = to,
       _value = from;

  /// The animation's target, in the offsets it started with.
  final double _to;

  /// Whether it was aimed at the newest line, which stays at the end as
  /// lines leave instead of moving with them.
  final bool _toEnd;

  /// The animation's latest value, in the offsets it started with.
  double _value;

  /// How far the whole path is moved when it ends on a line.
  double _targetShift = 0;

  /// The shifts of a path that ends at the newest line, each with how far
  /// the value was from [_to] when it came.
  final _endShifts = <({double left, double delta})>[];

  /// Moves the rest of the path with the lines. When it ends on a line,
  /// all of it moves by [path], how far the lines moved, even where the
  /// offset could not follow them all the way ([delta]). When it ends at
  /// the newest line, it moves by [delta] where it is now, the shift the
  /// offset just took, and less on the way to none at the end.
  void shiftBy(double delta, {required double path}) {
    if (!_toEnd) {
      _targetShift += path;
      return;
    }

    final left = _to - _value;
    // At its end already: the next frame sets the end, as it should.
    if (left.abs() < precisionErrorTolerance) return;
    _endShifts.add((left: left, delta: delta));
  }

  @override
  bool applyMoveTo(double value) {
    _value = value;
    // An end shift fades in proportion to the distance left. A curve that
    // turns back from the end or runs past it would scale the shift up or
    // reverse it, so it never takes more than all of it, nor any past the
    // end.
    var shift = _targetShift;
    for (final (:left, :delta) in _endShifts) {
      shift += delta * ((_to - value) / left).clamp(0.0, 1.0);
    }
    // When the lines in sight left, the moved path runs above the oldest
    // line left, and when the line aimed at left too, so does its end.
    // Bouncing physics would show the blank space there, so the path goes
    // no further above the oldest line than its curve does.
    final minExtent = (delegate as ScrollPosition).minScrollExtent;
    return super.applyMoveTo(
      math.max(value + shift, math.min(value, minExtent)),
    );
  }
}
