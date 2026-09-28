import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    this.banner,
    this.statusBuilder,
    this.currentLineColor,
  });

  final EditorController controller;
  final EditorStrings strings;
  final TextStyle textStyle;
  final EditorSyntaxTheme? syntaxTheme;
  final bool isActive;
  final bool editingLocked;
  final bool showLineNumbers;
  final bool showStatus;
  final Widget? banner;
  final Widget Function(BuildContext context, EditorController controller)?
  statusBuilder;

  /// The band behind the caret's line. Defaults to a faint tint of the
  /// theme's text color; pass [Colors.transparent] to turn it off.
  final Color? currentLineColor;

  @override
  State<PlanchetteEditor> createState() => _PlanchetteEditorState();
}

class _PlanchetteEditorState extends State<PlanchetteEditor> {
  static const _padding = 14.0;
  static const _gutterInset = 8.0;
  final _gutterRepaint = ValueNotifier<int>(0);
  final _decorationsKey = GlobalKey();
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
    c.setViewEditingLocked(this, widget.editingLocked);
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
      oldWidget.controller.setViewEditingLocked(this, false);
      c.addListener(_changed);
      _lastReveal = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) c.initialize();
      });
    }
    c.setViewEditingLocked(this, widget.editingLocked);
    c.text.theme =
        widget.syntaxTheme ??
        EditorSyntaxTheme.of(Theme.of(context).brightness);
    if (oldWidget.isActive != widget.isActive || oldWidget.controller != c) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.isActive) {
          c.restoreFocus();
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
    final decorations = _decorationsKey.currentContext?.findRenderObject();
    // The laid-out document knows where the match is, soft wraps included.
    // Before its first layout, estimate from the logical line.
    final dy =
        (decorations is _RenderDocumentDecorations
            ? decorations.textTopOf(match.start)
            : null) ??
        (c.lineStarts.takeWhile((offset) => offset <= match.start).length - 1) *
            MediaQuery.textScalerOf(context).scale(_style.fontSize!) *
            _style.height!;
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
    c.setViewEditingLocked(this, false);
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
          Expanded(child: _decorated(context, _body())),
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
                    if (c.caseFoldingLimited)
                      Tooltip(
                        message: strings.caseFoldLimited,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            Icons.info_outline,
                            size: 16,
                            color: theme.colorScheme.tertiary,
                          ),
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

  /// Line numbers and the current-line band are painted around the document
  /// by one render object; see [_RenderDocumentDecorations].
  Widget _decorated(BuildContext context, Widget body) {
    if (c.isLoading || c.error != null) return body;
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return _DocumentDecorations(
      key: _decorationsKey,
      controller: c,
      repaint: _gutterRepaint,
      gutterWidth: widget.showLineNumbers ? _measureGutter(scaler) : 0,
      textStyle: _style,
      textScaler: scaler,
      numberColor: theme.colorScheme.onSurfaceVariant,
      caretNumberColor: theme.colorScheme.onSurface,
      dividerColor: theme.dividerColor,
      currentLineColor:
          widget.currentLineColor ??
          theme.colorScheme.onSurface.withValues(alpha: 0.045),
      rightInset: _gutterInset,
      child: body,
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
                ),
              Expanded(
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
}

/// Paints the line-number gutter and the current-line band behind [child],
/// which holds the gutter's space and the document field.
///
/// Positions come from the document's own [RenderEditable], which the text
/// field has already laid out, and only for lines in view. Nothing lays out
/// the document a second time, so edits cost no extra layout and numbers stay
/// aligned with soft-wrapped lines at any document size.
class _DocumentDecorations extends SingleChildRenderObjectWidget {
  const _DocumentDecorations({
    super.key,
    required this.controller,
    required this.repaint,
    required this.gutterWidth,
    required this.textStyle,
    required this.textScaler,
    required this.numberColor,
    required this.caretNumberColor,
    required this.dividerColor,
    required this.currentLineColor,
    required this.rightInset,
    required super.child,
  });

  final EditorController controller;
  final Listenable repaint;
  final double gutterWidth;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final Color numberColor;
  final Color caretNumberColor;
  final Color dividerColor;
  final Color currentLineColor;
  final double rightInset;

  @override
  _RenderDocumentDecorations createRenderObject(BuildContext context) =>
      _RenderDocumentDecorations(this);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDocumentDecorations renderObject,
  ) => renderObject.configuration = this;
}

class _RenderDocumentDecorations extends RenderProxyBox {
  _RenderDocumentDecorations(this._configuration);

  _DocumentDecorations _configuration;
  set configuration(_DocumentDecorations value) {
    final previous = _configuration;
    _configuration = value;
    if (attached && !identical(previous.repaint, value.repaint)) {
      previous.repaint.removeListener(markNeedsPaint);
      value.repaint.addListener(markNeedsPaint);
    }
    // The host rebuilds on every edit and caret move; either can move lines.
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _configuration.repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _configuration.repaint.removeListener(markNeedsPaint);
    super.detach();
  }

  // Unscrolled line tops for the current layout. Each caret query walks every
  // row of the paragraph, which made scroll frames on 100,000-line documents
  // cost about 90 ms; scrolling does not move a line's unscrolled top, so each
  // line is measured once per layout instead of once per frame.
  Object? _topsText;
  RenderEditable? _topsEditable;
  Size? _topsSize;
  TextStyle? _topsStyle;
  TextScaler? _topsScaler;
  double _topsBias = 0;
  final Map<int, double> _tops = {};

  double _unscrolledTop(RenderEditable editable, List<int> starts, int line) {
    final config = _configuration;
    final text = config.controller.text.text;
    if (!identical(text, _topsText) ||
        !identical(editable, _topsEditable) ||
        editable.size != _topsSize ||
        config.textStyle != _topsStyle ||
        config.textScaler != _topsScaler) {
      _tops.clear();
      _topsText = text;
      _topsEditable = editable;
      _topsSize = editable.size;
      _topsStyle = config.textStyle;
      _topsScaler = config.textScaler;
      _topsBias =
          editable.getLocalRectForCaret(const TextPosition(offset: 0)).top +
          editable.offset.pixels;
    }
    return _tops[line] ??=
        editable.getLocalRectForCaret(TextPosition(offset: starts[line])).top +
        editable.offset.pixels -
        _topsBias;
  }

  /// The document field's text render object, or null before it is laid out.
  RenderEditable? _editable() {
    final pending = <RenderObject>[?child];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is RenderEditable) {
        if (node.hasSize) return node;
        continue;
      }
      node.visitChildren(pending.add);
    }
    return null;
  }

  /// The unscrolled top of the line holding [offset], or null before layout.
  double? textTopOf(int offset) {
    final editable = _editable();
    if (editable == null) return null;
    return _LineGeometry(editable).topOf(offset) + editable.offset.pixels;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final editable = _editable();
    if (editable != null) _paintDecorations(context.canvas, offset, editable);
    super.paint(context, offset);
  }

  void _paintDecorations(
    Canvas canvas,
    Offset offset,
    RenderEditable editable,
  ) {
    final config = _configuration;
    final controller = config.controller;
    final starts = controller.lineStarts;
    final lines = _LineGeometry(editable);
    final origin = offset + editable.localToGlobal(Offset.zero, ancestor: this);
    double topOf(int offset) => origin.dy + lines.topOf(offset);
    final pixels = editable.offset.pixels;
    double lineTop(int line) =>
        origin.dy + _unscrolledTop(editable, starts, line) - pixels;

    // Clip to the text's own viewport so numbers never show for lines whose
    // text has scrolled into the field's padding.
    final viewport = Rect.fromLTRB(
      offset.dx,
      origin.dy,
      offset.dx + size.width,
      origin.dy + editable.size.height,
    );
    canvas
      ..save()
      ..clipRect(viewport);

    final (caretLineNumber, _) = controller.caretLineColumn;
    final caretLine = caretLineNumber - 1;
    final selection = controller.text.selection;
    if (config.currentLineColor.a > 0 &&
        selection.isValid &&
        selection.isCollapsed) {
      final lineEnd = caretLine + 1 < starts.length
          ? starts[caretLine + 1] - 1
          : controller.text.text.length;
      canvas.drawRect(
        Rect.fromLTRB(
          viewport.left,
          topOf(starts[caretLine]),
          viewport.right,
          topOf(lineEnd) + editable.preferredLineHeight,
        ),
        Paint()..color = config.currentLineColor,
      );
    }

    if (config.gutterWidth > 0) {
      // The last line starting at or above the viewport's top edge: one hit
      // test finds the text at the top row, then a search of the line starts.
      final atTop = editable
          .getPositionForPoint(editable.localToGlobal(Offset.zero))
          .offset;
      var first = 0;
      var last = starts.length - 1;
      while (first < last) {
        final middle = (first + last + 1) >> 1;
        if (starts[middle] <= atTop) {
          first = middle;
        } else {
          last = middle - 1;
        }
      }
      while (first > 0 && lineTop(first) > viewport.top) {
        first--;
      }
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: config.textScaler,
      );
      final right = offset.dx + config.gutterWidth - 1 - config.rightInset;
      for (var line = first; line < starts.length; line++) {
        final top = lineTop(line);
        if (top > viewport.bottom) break;
        painter
          ..text = TextSpan(
            text: '${line + 1}',
            style: config.textStyle.copyWith(
              color: line == caretLine
                  ? config.caretNumberColor
                  : config.numberColor,
            ),
          )
          ..layout()
          ..paint(canvas, Offset(right - painter.width, top));
      }
      painter.dispose();
    }
    canvas.restore();

    if (config.gutterWidth > 0) {
      canvas.drawRect(
        Rect.fromLTWH(
          offset.dx + config.gutterWidth - 1,
          offset.dy,
          1,
          size.height,
        ),
        Paint()..color = config.dividerColor,
      );
    }
  }
}

/// Line tops in a [RenderEditable]'s local coordinates, which include its
/// scroll offset.
///
/// The caret rectangle is the only public per-position geometry, and it
/// carries a platform-specific vertical adjustment. Line 0 starts at the top
/// of the text, so measuring its caret calibrates that adjustment away.
final class _LineGeometry {
  _LineGeometry(this.editable)
    : _bias =
          editable.getLocalRectForCaret(const TextPosition(offset: 0)).top +
          editable.offset.pixels;

  final RenderEditable editable;
  final double _bias;

  double topOf(int offset) =>
      editable.getLocalRectForCaret(TextPosition(offset: offset)).top - _bias;
}
