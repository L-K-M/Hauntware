import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverLayoutDimensions;
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

  /// Long lines wrap; each line's extent is measured once per width and
  /// cached.
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

/// The log viewer of 03 §10.8 over a [LogViewController]: a
/// `ListView.builder` with a fixed line extent when [wrap] is off and a
/// measured extent cache when it is on, follow with pause on scroll
/// (LOG-02), level colours with a gutter icon, and keyboard operation
/// with a visible focus ring (03 §10.6, MVP).
///
/// Following keeps the newest line in sight. Scrolling away from it pauses
/// following, and the view then stays on the lines it shows while new
/// lines arrive and old ones leave the buffer; scrolling back to the
/// newest line, End, or the Follow button resumes it. Keys: Up and Down
/// move a line, Page Up and Page Down a page, Home goes to the oldest
/// line, End follows.
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

  /// The width estimate and wrapped row count of each held entry, from
  /// [_metricsFirstSeq] on, kept in step with the controller.
  final _metrics = ListQueue<_EntryMetrics>();
  int _metricsFirstSeq = 0;

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _l10n = AppLocalizations.of(context);
    final first = _text == null;
    _text = _TextLayout.of(context, _text);
    if (first) _resetMetrics();
  }

  @override
  void didUpdateWidget(LogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unlisten(oldWidget.controller);
      _listen(widget.controller);
      _resetMetrics();
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

  void _resetMetrics() {
    _metrics.clear();
    _metricsFirstSeq = widget.controller.firstSeq;
    _syncMetrics();
  }

  /// Brings [_metrics] in step with the controller and returns the extent
  /// of the entries that left from the front.
  double _syncMetrics() {
    final controller = widget.controller;
    var removed = 0.0;
    while (_metrics.isNotEmpty && _metricsFirstSeq < controller.firstSeq) {
      final gone = _metrics.removeFirst();
      _metricsFirstSeq++;
      removed += _extentOf(gone);
    }
    if (_metrics.isEmpty) _metricsFirstSeq = controller.firstSeq;

    final end = controller.firstSeq + controller.length;
    for (var seq = _metricsFirstSeq + _metrics.length; seq < end; seq++) {
      _metrics.addLast(_EntryMetrics());
    }
    return removed;
  }

  void _onLines() {
    final removed = _syncMetrics();
    // While paused, keep the lines in sight where they are: the entries
    // that left the buffer took their extent from above them.
    if (removed > 0 && !widget.controller.following.value) {
      final position = _vertical.hasClients ? _vertical.position : null;
      if (position is _TailScrollPosition && position.hasPixels) {
        position.shiftBy(-math.min(removed, position.pixels));
      }
    }
    setState(() {});
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

  double _extentOf(_EntryMetrics metrics) {
    final text = _text!;
    if (widget.wrap == LogWrap.off || metrics.rowsFor != text) {
      return text.lineHeight;
    }
    return metrics.rows * text.lineHeight;
  }

  /// The measured extent cache: a line whose width bound fits is one row;
  /// a longer one is laid out once per width and [_TextLayout].
  double? _wrappedExtent(int index, SliverLayoutDimensions dimensions) {
    final controller = widget.controller;
    if (index >= controller.length) return null;

    final text = _text!;
    final entry = controller[index];
    final metrics = _metrics.elementAt(index);
    final width = _textWidth(dimensions.crossAxisExtent, text);
    if (metrics.rowsFor == text && metrics.rowsWidth == width) {
      return metrics.rows * text.lineHeight;
    }

    // A dropped-lines record keeps to one row; a cut line is laid out for
    // its note.
    var rows = 1;
    if (entry is LogLine &&
        (entry.truncated || _widthBound(entry, metrics, text) > width)) {
      final painter = TextPainter(
        text: _lineSpan(entry, text),
        textDirection: TextDirection.ltr,
        strutStyle: text.strut,
        textScaler: text.scaler,
      )..layout(maxWidth: math.max(0, width));
      rows = math.max(1, (painter.height / text.lineHeight).round());
      painter.dispose();
    }
    metrics
      ..rows = rows
      ..rowsFor = text
      ..rowsWidth = width;
    return rows * text.lineHeight;
  }

  double _widthBound(LogLine line, _EntryMetrics metrics, _TextLayout text) =>
      (metrics.cells ??= logTextCells(parseSgr(line.text).text)) * text.advance;

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

    final list = NotificationListener<ScrollUpdateNotification>(
      onNotification: _onScrollUpdate,
      child: ListView.builder(
        controller: _vertical,
        itemCount: widget.controller.length,
        itemExtent: widget.wrap == LogWrap.off ? text.lineHeight : null,
        itemExtentBuilder: widget.wrap == LogWrap.on ? _wrappedExtent : null,
        itemBuilder: (context, index) => _row(index, text),
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

/// One entry's width estimate ([logTextCells]), taken when wrap first
/// needs it, and its row count when wrapped, valid for [rowsFor] at
/// [rowsWidth].
final class _EntryMetrics {
  int? cells;
  int rows = 1;
  _TextLayout? rowsFor;
  double rowsWidth = 0;
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
  /// velocity. Sends no scroll notification: the user did not scroll.
  void shiftBy(double delta) {
    correctBy(delta);
    final current = activity;
    if (current is BallisticScrollActivity) goBallistic(current.velocity);
    notifyListeners();
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // Content that shrank under a following offset (wrapped rows after a
    // wider layout, a long line leaving) moves the offset to the new end
    // at once. Past the end during a gesture or fling is a bounce, left to
    // the physics.
    final shrank =
        _following() &&
        pixels > maxScrollExtent &&
        !(activity?.isScrolling ?? false);
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
