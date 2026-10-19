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
import 'log_search.dart';
import 'log_text.dart';
import 'log_view_controller.dart';

/// Whether a [LogView] wraps long lines.
enum LogWrap {
  /// One row a line, plus one a field a journal row shows; a long line
  /// is cut at the view's edge with an ellipsis.
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

/// How many glyph advances a journal row's fields are indented by.
const int _fieldIndent = 2;

/// The rows kept above a search match the view scrolls to.
const int _revealContext = 2;

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
/// match's row into sight (LOG-05). Without wrap a match after the row's
/// first line or past its ellipsis stays out of sight.
///
/// A container line's row (CTX-01) starts with its time and its stream,
/// `stdout` or `stderr` ([LogViewController.containerOf]), the latter in
/// the error colour; a screen reader hears the stream's name.
class LogView extends StatefulWidget {
  const LogView({
    super.key,
    required this.controller,
    this.wrap = LogWrap.off,
    this.levelOf,
    this.search,
  });

  final LogViewController controller;
  final LogWrap wrap;

  /// The level of a line, for its colour and gutter icon. Without it no
  /// line has a level and the view has no gutter.
  final LogLevel? Function(LogLine line)? levelOf;

  /// The search whose matches the view highlights, over [controller].
  final LogSearch? search;

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

  /// The row count of each held entry without wrap, one a line plus its
  /// fields' rows, and with it, wrapped rows, both kept in step with the
  /// controller and the fields shown, so a wrap toggle keeps the counts
  /// measured before it.
  late _RowCounts _lineRows;
  late _RowCounts _wrappedRows;

  /// The counts [LogView.wrap] lays out with, and the other mode's.
  _RowCounts get _rows => widget.wrap == LogWrap.on ? _wrappedRows : _lineRows;
  _RowCounts get _otherRows =>
      widget.wrap == LogWrap.on ? _lineRows : _wrappedRows;

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
    _text = _TextLayout.of(context, previous);
    if (previous == null) {
      _resetRows();
    } else if (!identical(previous, _text)) {
      _invalidateRows();
      // The offset counts lines or rows of the old height.
      final scale = _text!.lineHeight / previous.lineHeight;
      if (scale != 1) _holdLines((pixels) => pixels * scale);
    }
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
      _resetRows();
      return;
    }

    if (oldWidget.wrap != widget.wrap) {
      // The offset counts the old mode's rows, now the other counts.
      final previous = _otherRows;
      _holdLines((pixels) => _offsetIn(previous, pixels));
    }
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
    _RowCounts counts(LogWrap wrap) => _RowCounts(
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
      if (position is _TailScrollPosition && position.hasPixels) {
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
        _expanded[line.seq] = line.journal!.fields;
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
    if (position is! _TailScrollPosition || !position.hasPixels) return;
    position.shiftBy(convert(position.pixels) - position.pixels);
  }

  /// The offset [pixels] into the rows of [previous] as an offset into
  /// [_rows] on the same entry and as far into its rows, for when what the
  /// rows count changes: lines and fields without wrap, wrapped rows with
  /// it.
  double _offsetIn(_RowCounts previous, double pixels) {
    if (previous.length == 0 || _rows.length == 0) return pixels;

    final line = _text!.lineHeight;
    final at = math.max(0.0, pixels / line);
    final index = previous.indexAtRow((at + _rowTolerance).floor());
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
    if (at + _rowTolerance >= end) return at + change;

    final kept = end + change;
    if (at + _rowTolerance < kept) return at;
    return kept - 1 + math.max(0.0, at - (at + _rowTolerance).floor());
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
    if (line.journal!.fieldsLeftOut > 0)
      _l10n.logJournalFieldsLeftOut(line.journal!.fieldsLeftOut),
  ];

  bool get _hasGutter => widget.levelOf != null;

  double _textWidth(double rowWidth, _TextLayout text) =>
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

    final container = widget.controller.containerOf(entry);
    var rows =
        _note(entry) == null &&
            fits(logRowText(entry, container: container), width)
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
  int _layoutRows(TextSpan span, double width, _TextLayout text) {
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
        (container == null ? 0 : logContainerSourceLength(container));
    if (width <= 0 || units == 0) return 1 + fields;
    return (units * text.advance / width).ceil().clamp(1, units) + fields;
  }

  TextSpan _lineSpan(LogLine line, _TextLayout text) {
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
    );
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
          _LogRows(
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
  Widget _richText(TextSpan span, _TextLayout text) => RichText(
    text: span,
    textDirection: TextDirection.ltr,
    strutStyle: text.strut,
    textScaler: text.scaler,
    softWrap: widget.wrap == LogWrap.on,
    maxLines: widget.wrap == LogWrap.off ? 1 : null,
    overflow: widget.wrap == LogWrap.off
        ? TextOverflow.ellipsis
        : TextOverflow.clip,
  );

  Widget _row(int index, _TextLayout text) {
    final entry = widget.controller[index];
    final level = entry is LogLine ? widget.levelOf?.call(entry) : null;
    final fields = _expanded[entry.seq];
    final Widget body = switch (entry) {
      LogLine() when fields != null => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _richText(_lineSpan(entry, text), text),
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
      LogLine() => _richText(_lineSpan(entry, text), text),
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
    if (entry is! LogLine || entry.journal == null) {
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

  /// How far a journal row's fields are indented.
  double get fieldIndent => _fieldIndent * advance;
}

/// The slots a [_RowCounts] starts with.
const int _minRowSlots = 1024;

/// The row count of every entry a [LogView] holds, with the rows before
/// any entry found in O(log n) through a Fenwick tree, so a frame costs
/// the same however many lines are held (03 §11.4).
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
  _RowCounts(this._measure, this._estimate);

  /// The exact rows of the entry at an index in a row of a cross-axis
  /// extent.
  final int Function(int index, double crossAxisExtent) _measure;

  /// A guess at the rows of the entry at an index until a layout measures
  /// it, from the cross-axis extent last measured at, if any.
  final int Function(int index, double? crossAxisExtent) _estimate;

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

  /// The cross-axis extent last measured at, or null before a layout.
  double? _crossAxisExtent;

  /// Changes whenever the rows would lay out differently, so the sliver
  /// lays out again even when the entry count stays the same.
  int get revision => _revision;
  int _revision = 0;

  int get length => _length;

  /// The rows of every held entry.
  int get total => _total;

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
  /// rows, and returns the entries that left from the front and their
  /// rows.
  ({int entries, int rows}) sync(LogViewController controller) {
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
      _append(_estimate(seq - controller.firstSeq, _crossAxisExtent));
    }
    _revision++;
    return (entries: entries, rows: rows);
  }

  /// Measures the entry at [index] again at once, for a change only it
  /// sees, such as its fields showing, and returns how its count changed.
  /// Before a layout gives the counts a width, it estimates the entry.
  int remeasure(int index) {
    final slot = _front + index;
    _measuredIn[slot] = 0;
    final change = _crossAxisExtent == null
        ? _recount(slot, _estimate(index, null))
        : _measureAt(index);
    _revision++;
    return change;
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
    return _recount(slot, _measure(index, _crossAxisExtent!));
  }

  /// Sets the count in [slot] to [rows] and returns how it changed.
  int _recount(int slot, int rows) {
    final change = rows - _counts[slot];
    if (change != 0) {
      _counts[slot] = rows;
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

/// The rows of a [LogView]: a sliver like `SliverVariedExtentList` whose
/// offsets and indexes come from [_RowCounts] in O(log n), where that
/// list sums every extent before an index, and which measures the entries
/// a layout shows before laying them out.
final class _LogRows extends SliverMultiBoxAdaptorWidget {
  const _LogRows({
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
  _RenderLogRows createRenderObject(BuildContext context) => _RenderLogRows(
    childManager: context as SliverMultiBoxAdaptorElement,
    rows: rows,
    revision: revision,
    lineHeight: lineHeight,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderLogRows renderObject) {
    renderObject
      ..rows = rows
      ..revision = revision
      ..lineHeight = lineHeight;
  }
}

final class _RenderLogRows extends RenderSliverFixedExtentBoxAdaptor {
  _RenderLogRows({
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
    // Bouncing physics would show the blank space there, and clamping
    // physics would report overscroll, which ends the animation on the
    // oldest line, so the path goes no further above the oldest line than
    // its curve does.
    final minExtent = (delegate as ScrollPosition).minScrollExtent;
    return super.applyMoveTo(
      math.max(value + shift, math.min(value, minExtent)),
    );
  }
}
