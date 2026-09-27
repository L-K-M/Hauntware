import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:planchette_core/planchette_core.dart';

import 'code_editing_controller.dart';
import 'editor_controller.dart';
import 'editor_strings.dart';

/// The shared document surface. Its host supplies app chrome, file commands,
/// notifications and close decisions; no navigation or native menu is installed.
class PlanchetteEditor extends StatefulWidget {
  const PlanchetteEditor({
    super.key,
    required this.controller,
    this.strings = const EditorStrings(),
    this.textStyle = const TextStyle(
      fontFamily: 'monospace',
      fontSize: 14,
      height: 1.35,
    ),
    this.syntaxTheme,
    this.isActive = true,
    this.editingLocked = false,
    this.showLineNumbers = true,
    this.showStatus = true,
    this.showScrollbar = true,
    this.banner,
    this.statusBuilder,
  });

  final EditorController controller;
  final EditorStrings strings;
  final TextStyle textStyle;
  final EditorSyntaxTheme? syntaxTheme;
  final bool isActive;
  final bool editingLocked;
  final bool showLineNumbers;
  final bool showStatus;

  /// Whether the editor's scrollbar is always on. A document long enough to
  /// lose the caret in it needs one; a host with its own scroll affordance
  /// does not.
  final bool showScrollbar;
  final Widget? banner;
  final Widget Function(BuildContext context, EditorController controller)?
  statusBuilder;

  @override
  State<PlanchetteEditor> createState() => _PlanchetteEditorState();
}

class _PlanchetteEditorState extends State<PlanchetteEditor> {
  static const _padding = 14.0;
  static const _gutterInset = 8.0;

  /// Past this size the gutter falls back to assuming a uniform row height
  /// rather than measuring every row. The estimate is right for any document
  /// whose lines all fit the width, and wrong by one row per folded line
  /// above the viewport otherwise — the same trade the painter's scroll
  /// back-off already makes.
  static const _gutterMeasurementMaxChars = 128 * 1024;
  final _gutterRepaint = ValueNotifier<int>(0);
  final TextPainter _gutterPainter = TextPainter(
    textDirection: TextDirection.ltr,
  );
  List<double> _gutterTops = const [0];
  String? _gutterText;
  double? _gutterWidth;
  TextScaler? _gutterScaler;
  TextStyle? _gutterStyle;
  double? _textWidth;
  int _lastReveal = -1;
  bool _revealQueued = false;
  EditorController get c => widget.controller;
  TextStyle get _style =>
      const TextStyle(fontSize: 14, height: 1.35).merge(widget.textStyle);
  bool get _locked => widget.editingLocked || c.editingLocked;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    c.setEditingLocked(widget.editingLocked, notify: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) c.initialize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    c.text.theme =
        widget.syntaxTheme ??
        EditorSyntaxTheme.of(Theme.of(context).brightness);
  }

  @override
  void didUpdateWidget(PlanchetteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      c.addListener(_changed);
      _lastReveal = -1;
      _gutterText = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) c.initialize();
      });
    }
    c.setEditingLocked(widget.editingLocked, notify: false);
    c.text.theme =
        widget.syntaxTheme ??
        EditorSyntaxTheme.of(Theme.of(context).brightness);
    if (oldWidget.isActive != widget.isActive || oldWidget.controller != c) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.isActive) {
          if (!c.searchFocus.hasFocus && !c.replacementFocus.hasFocus) {
            c.editorFocus.requestFocus();
          }
        } else {
          c.editorFocus.unfocus();
          c.searchFocus.unfocus();
          c.replacementFocus.unfocus();
        }
      });
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_lastReveal != c.revealRequest && !_revealQueued) {
      _revealQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _revealQueued = false;
        if (!mounted) return;
        _lastReveal = c.revealRequest;
        _revealMatch();
      });
    }
  }

  void _revealMatch() {
    if (!c.scroll.hasClients) return;
    if (c.activeMatch < 0 || c.activeMatch >= c.matches.length) return;
    final match = c.matches[c.activeMatch];
    final dy = _rowTopFor(match.start) ?? _measuredTopFor(match.start);
    if (dy == null) return;
    final position = c.scroll.positions.last;
    final target = (dy + _padding - position.viewportDimension / 3).clamp(
      0.0,
      position.maxScrollExtent,
    );
    c.scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
    );
  }

  /// The cached gutter already knows where every logical line begins, so a
  /// reveal normally costs a binary search rather than a fresh layout.
  double? _rowTopFor(int offset) {
    final tops = _gutterTops;
    if (tops.length != c.lineStarts.length) return null;
    final starts = c.lineStarts;
    var lo = 0;
    var hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return tops[lo];
  }

  /// Fallback for a document whose rows and logical lines disagree, which only
  /// happens once a long line has soft-wrapped, or for one too large for the
  /// gutter to measure. The estimate is the same uniform row height the
  /// painter's scroll back-off already assumes.
  double? _measuredTopFor(int offset) {
    if (c.text.text.length > _gutterMeasurementMaxChars || _textWidth == null) {
      final line = c.lineStarts.indexWhere((start) => start > offset) - 1;
      return line *
          MediaQuery.textScalerOf(context).scale(_style.fontSize!) *
          _style.height!;
    }
    final prefix = c.text.text.substring(0, offset);
    _gutterPainter
      ..textScaler = MediaQuery.textScalerOf(context)
      ..text = TextSpan(text: prefix, style: _style);
    _gutterPainter.layout(maxWidth: _textWidth! > 1 ? _textWidth! : 1);
    final dy = _gutterPainter
        .getOffsetForCaret(TextPosition(offset: prefix.length), Rect.zero)
        .dy;
    _gutterPainter.text = const TextSpan(text: '');
    return dy;
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _gutterRepaint.dispose();
    _gutterPainter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The gutter's width depends only on the digit count and the font, not on
    // how much room the window has, so it is measured once per build and
    // shared with the status bar rather than re-measured inside a
    // LayoutBuilder that the status bar builds before.
    final scaler = MediaQuery.textScalerOf(context);
    final gutterWidth = widget.showLineNumbers ? _measureGutter(scaler) : 0.0;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            c.openSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            c.openSearch,
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): () =>
            c.openSearch(replace: true),
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          meta: true,
          alt: true,
        ): () =>
            c.openSearch(replace: true),
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true): c.nextMatch,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true):
            c.nextMatch,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
            c.previousMatch,
        const SingleActivator(
          LogicalKeyboardKey.keyG,
          control: true,
          shift: true,
        ): c.previousMatch,
        const SingleActivator(LogicalKeyboardKey.f3): c.nextMatch,
        const SingleActivator(LogicalKeyboardKey.f3, shift: true):
            c.previousMatch,
        if (c.searchOpen)
          const SingleActivator(LogicalKeyboardKey.escape): c.closeSearch,
      },
      child: Column(
        children: [
          if (widget.banner != null) widget.banner!,
          if (c.searchOpen) ...[_searchBar(context), const Divider(height: 1)],
          Expanded(child: _body(gutterWidth, scaler)),
          if (widget.showStatus && !c.isLoading && c.error == null) ...[
            const Divider(height: 1),
            SafeArea(
              top: false,
              child:
                  widget.statusBuilder?.call(context, c) ??
                  _statusBar(context, gutterWidth),
            ),
          ],
        ],
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    final counter = c.search.text.isEmpty
        ? ''
        : c.matches.isEmpty
        ? strings.noMatches
        : strings.matchCount(
            c.activeMatch + 1,
            c.matches.length,
            capped: c.matches.length >= searchMatchLimit,
          );
    return ColoredBox(
      // The bar needs its own surface. Without one the fields sit straight on
      // whatever is behind them, and in a dark theme "Find in file" was bare
      // text with a caret and nothing that said it was an input.
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _searchField(
                    context,
                    controller: c.search,
                    focusNode: c.searchFocus,
                    hint: strings.findHint,
                    autofocus: true,
                    onSubmitted: (_) {
                      if (HardwareKeyboard.instance.isShiftPressed) {
                        c.previousMatch();
                      } else {
                        c.nextMatch();
                      }
                      c.searchFocus.requestFocus();
                    },
                  ),
                ),
                ExcludeFocus(
                  child: Row(
                    children: [
                      if (counter.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            counter,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      IconButton(
                        tooltip: strings.matchCase,
                        visualDensity: VisualDensity.compact,
                        onPressed: c.toggleCaseSensitive,
                        icon: Text(
                          'Aa',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: c.caseSensitive
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: strings.previousMatch,
                        visualDensity: VisualDensity.compact,
                        onPressed: c.matches.isEmpty ? null : c.previousMatch,
                        icon: const Icon(Icons.keyboard_arrow_up),
                      ),
                      IconButton(
                        tooltip: strings.nextMatch,
                        visualDensity: VisualDensity.compact,
                        onPressed: c.matches.isEmpty ? null : c.nextMatch,
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                      IconButton(
                        tooltip: strings.showReplace,
                        visualDensity: VisualDensity.compact,
                        onPressed: c.toggleReplace,
                        icon: const Icon(Icons.find_replace),
                      ),
                      IconButton(
                        tooltip: strings.closeSearch,
                        visualDensity: VisualDensity.compact,
                        onPressed: c.closeSearch,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (c.replaceOpen)
              Row(
                children: [
                  Expanded(
                    child: _searchField(
                      context,
                      controller: c.replacement,
                      focusNode: c.replacementFocus,
                      hint: strings.replaceHint,
                      autofocus: false,
                      onSubmitted: (_) => c.replaceCurrent(),
                    ),
                  ),
                  ExcludeFocus(
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: _locked || c.isBusy || c.matches.isEmpty
                              ? null
                              : c.replaceCurrent,
                          child: Text(strings.replace),
                        ),
                        TextButton(
                          onPressed: _locked || c.isBusy || c.matches.isEmpty
                              ? null
                              : c.replaceAll,
                          child: Text(strings.replaceAll),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// A find or replace field. It keeps an outline so it reads as an input
  /// rather than as a label, and it uses the editor's monospace face so a
  /// pattern is shaped the way it will match.
  Widget _searchField(
    BuildContext context, {
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required bool autofocus,
    required ValueChanged<String> onSubmitted,
  }) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      style: _style.copyWith(fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: theme.colorScheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: theme.dividerColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: theme.dividerColor),
        ),
      ),
      onSubmitted: onSubmitted,
    );
  }

  Widget _statusBar(BuildContext context, double gutterWidth) {
    final (line, column) = c.caretLineColumn;
    final document = c.document;
    final status = [
      if (c.isSaving) widget.strings.saving,
      if (c.isDirty) widget.strings.unsaved,
      document?.lineEnding == LineEnding.crlf ? 'CRLF' : 'LF',
      document?.hasUtf8Bom == true ? 'UTF-8 BOM' : 'UTF-8',
      if (c.text.language case final language? when c.highlightingEnabled)
        language.id,
      if (!c.highlightingEnabled) widget.strings.largeFile,
    ];
    return Padding(
      // The caret's left edge is where the text starts, so the position
      // readout starts there too rather than under the line numbers.
      padding: EdgeInsets.fromLTRB(gutterWidth + _padding, 6, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.strings.documentPosition(
                line,
                column,
                c.lineStarts.length,
                c.byteCount,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          Flexible(
            child: Text(
              status.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(double gutterWidth, TextScaler scaler) {
    if (c.isLoading) return const Center(child: CircularProgressIndicator());
    if (c.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.text_snippet_outlined, size: 40),
              const SizedBox(height: 12),
              Text(c.error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _textWidth = constraints.maxWidth - gutterWidth - 2 * _padding;
        if (widget.showLineNumbers) _ensureGutterLayout(_textWidth!, scaler);
        final theme = Theme.of(context);
        return NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _gutterRepaint.value++;
            return false;
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showLineNumbers)
                SizedBox(
                  key: const ValueKey('editor-line-gutter'),
                  width: gutterWidth,
                  child: CustomPaint(
                    painter: _LineNumberGutterPainter(
                      scroll: c.scroll,
                      repaint: _gutterRepaint,
                      lineTops: _gutterTops,
                      topInset: _padding,
                      caretLine: c.caretLineColumn.$1,
                      textStyle: _style,
                      numberColor: theme.colorScheme.onSurfaceVariant,
                      caretLineColor: theme.colorScheme.onSurface,
                      dividerColor: theme.dividerColor,
                      textScaler: scaler,
                      rightInset: _gutterInset,
                    ),
                  ),
                ),
              Expanded(
                // The field's own scrollable never gets a Scrollbar of its own,
                // so without this a 10,000 line document gives no indication
                // of where the caret is in it and nothing to drag.
                child: Scrollbar(
                  controller: c.scroll,
                  thumbVisibility: widget.showScrollbar,
                  child: Actions(
                    actions: {
                      if (_locked) ...{
                        UndoTextIntent: CallbackAction<UndoTextIntent>(
                          onInvoke: (_) => null,
                        ),
                        RedoTextIntent: CallbackAction<RedoTextIntent>(
                          onInvoke: (_) => null,
                        ),
                      },
                    },
                    child: TextField(
                      key: const ValueKey('planchette.document'),
                      controller: c.text,
                      undoController: c.undoController,
                      readOnly: _locked,
                      focusNode: c.editorFocus,
                      scrollController: c.scroll,
                      autofocus: widget.isActive,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      autocorrect: false,
                      enableSuggestions: false,
                      smartDashesType: SmartDashesType.disabled,
                      smartQuotesType: SmartQuotesType.disabled,
                      style: _style,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(_padding),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  double _measureGutter(TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(
        text: '0' * c.lineStarts.length.toString().length,
        style: _style,
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return _gutterInset * 2 + width + 1;
  }

  void _ensureGutterLayout(double width, TextScaler scaler) {
    if (identical(_gutterText, c.text.text) &&
        _gutterWidth == width &&
        _gutterScaler == scaler &&
        _gutterStyle == _style) {
      return;
    }
    _gutterTops = _measuredTops(width, scaler);
    _gutterText = c.text.text;
    _gutterWidth = width;
    _gutterScaler = scaler;
    _gutterStyle = _style;
  }

  List<double> _uniformTops(int lineCount, double lineHeight) => [
    for (var i = 0; i < lineCount; i++) i * lineHeight,
  ];

  /// Where each logical line begins.
  ///
  /// Flutter's `TextField` cannot turn soft wrap off, so a long line may have
  /// folded and the tops cannot be assumed uniform. One `computeLineMetrics`
  /// call measures every row at once — an order of magnitude cheaper than a
  /// caret lookup per line, which is what this used to do — and the row count
  /// it returns says whether anything folded at all. Only a document that
  /// genuinely folded needs the per-line path, and only a document too large
  /// to measure affordably falls back to the uniform estimate.
  List<double> _measuredTops(double width, TextScaler scaler) {
    final lineHeight = scaler.scale(_style.fontSize!) * _style.height!;
    final lineCount = c.lineStarts.length;
    if (c.text.text.length > _gutterMeasurementMaxChars) {
      return _uniformTops(lineCount, lineHeight);
    }
    _gutterPainter
      ..textScaler = MediaQuery.textScalerOf(context)
      ..text = c.text.buildTextSpan(
        context: context,
        style: _style,
        withComposing: false,
      )
      ..layout(maxWidth: width > 1 ? width : 1);
    final rows = _gutterPainter.computeLineMetrics();
    if (rows.length == lineCount) {
      _gutterPainter.text = const TextSpan(text: '');
      // LineMetrics reports each row's own height rather than its offset, so
      // the tops are a running sum — plain arithmetic over the same rows the
      // single call already produced.
      final tops = <double>[];
      var top = 0.0;
      for (final row in rows) {
        tops.add(top);
        top += row.height;
      }
      return tops;
    }
    return [
      for (final offset in c.lineStarts)
        _gutterPainter
            .getOffsetForCaret(TextPosition(offset: offset), Rect.zero)
            .dy,
    ];
  }
}

/// Paints right-aligned line numbers at each logical line's visual top,
/// tracking the editor's scroll offset. Only lines intersecting the
/// viewport are laid out, and scroll notifications repaint through
/// [CustomPainter.repaint] without a widget rebuild.
class _LineNumberGutterPainter extends CustomPainter {
  /// Read for the live offset at paint time; its notifications do not
  /// reach this painter — [repaint] (bumped by scroll notifications)
  /// drives repaints instead.
  final ScrollController scroll;
  final List<double> lineTops;
  final double topInset;

  /// 1-based logical line holding the caret, drawn brighter.
  final int caretLine;
  final TextStyle textStyle;
  final Color numberColor;
  final Color caretLineColor;
  final Color dividerColor;
  final TextScaler textScaler;
  final double rightInset;

  _LineNumberGutterPainter({
    required this.scroll,
    required Listenable repaint,
    required this.lineTops,
    required this.topInset,
    required this.caretLine,
    required this.textStyle,
    required this.numberColor,
    required this.caretLineColor,
    required this.dividerColor,
    required this.textScaler,
    required this.rightInset,
  }) : assert(
         textStyle.fontSize != null,
         '_LineNumberGutterPainter needs a TextStyle with an explicit '
         'fontSize.',
       ),
       super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // During reparenting the old text field detaches at frame finalization,
    // after its replacement has attached. Paint against the newest position
    // rather than asserting that this transient attachment count is one.
    final offset = scroll.hasClients ? scroll.positions.last.pixels : 0.0;
    final lineHeight =
        textScaler.scale(textStyle.fontSize!) * (textStyle.height ?? 1);
    canvas.clipRect(Offset.zero & size);
    // Skip ahead to the first line whose box bottom is still on screen.
    final threshold = offset - topInset - lineHeight;
    var lo = 0;
    var hi = lineTops.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (lineTops[mid] > threshold) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    // Insurance against line-height estimate error: painting extra
    // off-screen lines is clipped, skipping a visible one isn't. Past the
    // highlighting cap the estimate lags by one row per soft wrap above the
    // viewport, so the backoff is sized in viewport rows, not one line.
    lo -= (size.height / lineHeight).ceil();
    if (lo < 0) lo = 0;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    for (var i = lo; i < lineTops.length; i++) {
      final y = topInset + lineTops[i] - offset;
      if (y > size.height) break;
      painter.text = TextSpan(
        text: '${i + 1}',
        style: textStyle.copyWith(
          color: i + 1 == caretLine ? caretLineColor : numberColor,
        ),
      );
      painter.layout();
      painter.paint(
        canvas,
        Offset(size.width - 1 - rightInset - painter.width, y),
      );
    }
    painter.dispose();
    canvas.drawRect(
      Rect.fromLTWH(size.width - 1, 0, 1, size.height),
      Paint()..color = dividerColor,
    );
  }

  @override
  bool shouldRepaint(_LineNumberGutterPainter old) =>
      !identical(lineTops, old.lineTops) ||
      caretLine != old.caretLine ||
      topInset != old.topInset ||
      textStyle != old.textStyle ||
      numberColor != old.numberColor ||
      caretLineColor != old.caretLineColor ||
      dividerColor != old.dividerColor ||
      textScaler != old.textScaler ||
      rightInset != old.rightInset;
}
