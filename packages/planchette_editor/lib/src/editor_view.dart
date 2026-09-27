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
    this.highlightCaretLine = true,
    this.showStatus = true,
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

  /// Draw a subtle full-width band behind the caret's line, as mainstream
  /// code editors do. Hosts can opt out.
  final bool highlightCaretLine;
  final bool showStatus;
  final Widget? banner;
  final Widget Function(BuildContext context, EditorController controller)?
  statusBuilder;

  @override
  State<PlanchetteEditor> createState() => _PlanchetteEditorState();
}

class _PlanchetteEditorState extends State<PlanchetteEditor> {
  static const _padding = 14.0;
  static const _gutterInset = 8.0;
  final _gutterRepaint = ValueNotifier<int>(0);
  List<double> _gutterTops = const [0];
  String? _gutterText;
  double? _gutterWidth;
  TextScaler? _gutterScaler;
  TextStyle? _gutterStyle;
  double? _textWidth;

  /// Laid-out height of the whole document text; bounds the caret-line
  /// band when the caret is on the final (possibly wrapped) line.
  double _documentHeight = 0;
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
    double dy;
    if (c.text.text.length <= syntaxHighlightingMaxChars &&
        _textWidth != null) {
      final prefix = c.text.text.substring(0, match.start);
      final painter = TextPainter(
        text: TextSpan(text: prefix, style: _style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: _textWidth! > 1 ? _textWidth! : 1);
      dy = painter
          .getOffsetForCaret(TextPosition(offset: prefix.length), Rect.zero)
          .dy;
      painter.dispose();
    } else {
      final line =
          c.lineStarts.takeWhile((offset) => offset <= match.start).length - 1;
      dy =
          line *
          MediaQuery.textScalerOf(context).scale(_style.fontSize!) *
          _style.height!;
    }
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

  @override
  void dispose() {
    c.removeListener(_changed);
    _gutterRepaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          Expanded(child: _body()),
          if (widget.showStatus && !c.isLoading && c.error == null) ...[
            const Divider(height: 1),
            SafeArea(
              top: false,
              child:
                  widget.statusBuilder?.call(context, c) ?? _statusBar(context),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: c.search,
                  focusNode: c.searchFocus,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: strings.findHint,
                    isDense: true,
                    border: InputBorder.none,
                  ),
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
                        child: Text(counter, style: theme.textTheme.labelSmall),
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
                  child: TextField(
                    controller: c.replacement,
                    focusNode: c.replacementFocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      hintText: strings.replaceHint,
                      isDense: true,
                      border: InputBorder.none,
                    ),
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
    );
  }

  Widget _statusBar(BuildContext context) {
    final (line, column) = c.caretLineColumn;
    final document = c.document;
    final status = [
      if (c.isSaving) widget.strings.saving,
      if (c.isDirty) widget.strings.unsaved,
      document?.lineEnding == LineEnding.crlf ? 'CRLF' : 'LF',
      document?.hasUtf8Bom == true ? 'UTF-8 BOM' : 'UTF-8',
      if (c.text.language case final language?) language.id,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

  Widget _body() {
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
        final scaler = MediaQuery.textScalerOf(context);
        final gutterWidth = widget.showLineNumbers
            ? _measureGutter(scaler)
            : 0.0;
        _textWidth = constraints.maxWidth - gutterWidth - 2 * _padding;
        // The gutter or the caret band consumes line tops; skip the
        // O(document) layout when both features are disabled.
        if (widget.showLineNumbers || widget.highlightCaretLine) {
          _ensureGutterLayout(_textWidth!, scaler);
        }
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
                child: Stack(
                  children: [
                    if (widget.highlightCaretLine)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            key: const ValueKey('editor-caret-band'),
                            painter: _CaretLineBandPainter(
                              scroll: c.scroll,
                              repaint: _gutterRepaint,
                              lineTops: _gutterTops,
                              documentHeight: _documentHeight,
                              topInset: _padding,
                              caretLine: c.caretLineColumn.$1,
                              lineHeight:
                                  scaler.scale(_style.fontSize ?? 14) *
                                  (_style.height ?? 1.35),
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.05,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Actions(
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
                  ],
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
    final lineHeight = scaler.scale(_style.fontSize!) * _style.height!;
    if (c.text.text.length <= syntaxHighlightingMaxChars) {
      final painter = TextPainter(
        text: c.text.buildTextSpan(
          context: context,
          style: _style,
          withComposing: false,
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width > 1 ? width : 1);
      _gutterTops = [
        for (final offset in c.lineStarts)
          painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
      ];
      // The painter laid out the whole document, so its height already
      // accounts for any wrapped rows the per-line tops cannot express.
      _documentHeight = painter.height;
      painter.dispose();
    } else {
      _gutterTops = [
        for (var i = 0; i < c.lineStarts.length; i++) i * lineHeight,
      ];
      _documentHeight = c.lineStarts.length * lineHeight;
    }
    _gutterText = c.text.text;
    _gutterWidth = width;
    _gutterScaler = scaler;
    _gutterStyle = _style;
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

/// Paints a subtle full-width band behind the caret's logical line, from
/// that line's visual top to the next line's top (so wrapped rows are
/// covered). Tracks the editor's scroll offset like the gutter painter and
/// shares its repaint listenable.
class _CaretLineBandPainter extends CustomPainter {
  final ScrollController scroll;
  final List<double> lineTops;

  /// Laid-out height of the whole document; bounds the band on the final
  /// line, whose wrapped rows have no successor entry in [lineTops].
  final double documentHeight;
  final double topInset;
  final int caretLine;
  final double lineHeight;
  final Color color;

  _CaretLineBandPainter({
    required this.scroll,
    required Listenable repaint,
    required this.lineTops,
    required this.documentHeight,
    required this.topInset,
    required this.caretLine,
    required this.lineHeight,
    required this.color,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final index = caretLine - 1;
    if (index < 0 || index >= lineTops.length) return;
    // During reparenting the newest attached position is the live one.
    final offset = scroll.hasClients ? scroll.positions.last.pixels : 0.0;
    final top = topInset + lineTops[index] - offset;
    final nextTop = index + 1 < lineTops.length
        ? topInset + lineTops[index + 1] - offset
        : topInset + documentHeight - offset;
    // Never invert if documentHeight is briefly stale.
    final bottom = nextTop > top ? nextTop : top + lineHeight;
    final band = Rect.fromLTWH(0, top, size.width, bottom - top);
    canvas.drawRect(band.intersect(Offset.zero & size), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CaretLineBandPainter old) =>
      !identical(lineTops, old.lineTops) ||
      documentHeight != old.documentHeight ||
      caretLine != old.caretLine ||
      topInset != old.topInset ||
      lineHeight != old.lineHeight ||
      color != old.color;

  @override
  String toString() =>
      '_CaretLineBandPainter(caretLine: $caretLine, lines: ${lineTops.length}, '
      'documentHeight: $documentHeight)';
}
