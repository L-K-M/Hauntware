import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:planchette_core/planchette_core.dart';

import 'code_editing_controller.dart';
import 'editor_controller.dart';
import 'editor_fonts.dart';
import 'editor_strings.dart';

/// What the Tab key does inside the document.
enum EditorTabKeyBehavior {
  /// Tab and Shift+Tab indent and outdent, as in a code editor. Neither
  /// traverses focus then; a host whose keyboard-only users need Tab to leave
  /// the document should offer another shortcut or choose [moveFocus].
  indent,

  /// Tab and Shift+Tab move keyboard focus, as in an ordinary text field.
  moveFocus,
}

/// The shared document surface. Its host supplies app chrome, file commands,
/// notifications and close decisions; no navigation or native menu is installed.
class PlanchetteEditor extends StatefulWidget {
  const PlanchetteEditor({
    super.key,
    required this.controller,
    this.strings = const EditorStrings(),
    this.textStyle = const TextStyle(fontSize: 14, height: 1.35),
    this.syntaxTheme,
    this.isActive = true,
    this.editingLocked = false,
    this.showLineNumbers = true,
    this.showStatus = true,
    this.banner,
    this.statusBuilder,
    this.currentLineColor,
    this.placeholder,
    this.tabKeyBehavior = EditorTabKeyBehavior.indent,
  });

  final EditorController controller;
  final EditorStrings strings;

  /// Merged over the platform's monospace family ([editorMonospaceFor]), a
  /// 14 px size and 1.35 line height. A `fontFamily` here is tried first,
  /// except the generic `monospace`, which selects the platform family;
  /// the platform stack stays as its fallback unless `fontFamilyFallback`
  /// is set too, so a missing host font still lands on a monospace face.
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

  /// Faint text shown whenever the document is empty: it goes on the first
  /// keystroke and returns if the text is deleted. Screen readers announce it
  /// as the field's hint.
  final String? placeholder;

  /// Enter and Backspace always follow the document's indentation; this only
  /// decides whether Tab indents or leaves the editor.
  final EditorTabKeyBehavior tabKeyBehavior;

  @override
  State<PlanchetteEditor> createState() => _PlanchetteEditorState();
}

class _PlanchetteEditorState extends State<PlanchetteEditor> {
  static const _padding = 14.0;
  static const _gutterInset = 8.0;
  final _gutterRepaint = ValueNotifier<int>(0);
  final _decorationsKey = GlobalKey();
  int _lastReveal = -1;
  int _lastCaretReveal = 0;
  bool _revealQueued = false;
  EditorController get c => widget.controller;
  TextStyle get _style {
    // Installed fonts follow the operating system, not a theme's platform.
    final base = editorMonospaceFor(
      defaultTargetPlatform,
    ).merge(const TextStyle(fontSize: 14, height: 1.35));
    final style = base.merge(widget.textStyle);
    // Hosts written for the old default pass the generic name, which only
    // fontconfig and Android resolve; it means the platform's own family.
    return style.fontFamily?.toLowerCase() == 'monospace'
        ? style.copyWith(fontFamily: base.fontFamily)
        : style;
  }

  bool get _locked => widget.editingLocked || c.editingLocked;
  bool get _apple => switch (Theme.of(context).platform) {
    TargetPlatform.macOS || TargetPlatform.iOS => true,
    _ => false,
  };

  /// The widget's own theme, else the host theme's extension, else the
  /// built-in palette for the current brightness.
  EditorSyntaxTheme get _syntaxTheme {
    final theme = Theme.of(context);
    return widget.syntaxTheme ??
        theme.extension<EditorSyntaxTheme>() ??
        EditorSyntaxTheme.of(theme.brightness);
  }

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _lastCaretReveal = c.caretRevealRequest;
    c.setViewEditingLocked(this, widget.editingLocked);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) c.initialize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    c.text.theme = _syntaxTheme;
  }

  @override
  void didUpdateWidget(PlanchetteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.setViewEditingLocked(this, false);
      c.addListener(_changed);
      _lastReveal = -1;
      _lastCaretReveal = c.caretRevealRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) c.initialize();
      });
    }
    c.setViewEditingLocked(this, widget.editingLocked);
    c.text.theme = _syntaxTheme;
    if (oldWidget.isActive != widget.isActive || oldWidget.controller != c) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.isActive) {
          c.restoreFocus();
        } else {
          for (final node in c.textFocusNodes) {
            node.unfocus();
          }
        }
      });
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_lastCaretReveal != c.caretRevealRequest) {
      _lastCaretReveal = c.caretRevealRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealCaret();
      });
    }
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

  /// Scrolls to a caret that a command moved, since only typing scrolls by
  /// itself: just far enough for an edit or a bracket jump, the way typing
  /// does, and for Go to Line, whose target may be far away, a third of the
  /// way down the view unless it is already in view.
  void _revealCaret() {
    final selection = c.text.selection;
    if (!selection.isValid) return;
    final field = c.editorFocus.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (field == null) return;
    switch (c.caretRevealPlacement) {
      case CaretReveal.nearest:
        field.bringIntoView(selection.extent);
      case CaretReveal.upperThird:
        final editable = field.renderEditable;
        if (!editable.hasSize || !c.scroll.hasClients) return;
        final caret = editable.getLocalRectForCaret(selection.extent);
        if (caret.top >= 0 && caret.bottom <= editable.size.height) return;
        final position = c.scroll.positions.last;
        c.scroll.jumpTo(
          (caret.top + position.pixels - position.viewportDimension / 3).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
    }
  }

  /// Closes the bar that has focus, or from the document the Go to Line
  /// bar first, since it opens above the find bar.
  void _escape() {
    final inSearch = c.searchFocus.hasFocus || c.replacementFocus.hasFocus;
    if (c.goToLineOpen && !inSearch) {
      c.closeGoToLine();
    } else {
      c.closeSearch();
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
      // Command on Apple platforms and Control elsewhere, never both: Control
      // chords are Cocoa text bindings on macOS (Ctrl+F moves forward, Ctrl+H
      // deletes backward), and Ctrl+G is Go to Line on Windows and Linux.
      bindings: {
        if (_apple) ...{
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              c.openSearch,
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            meta: true,
            alt: true,
          ): () =>
              c.openSearch(replace: true),
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
              c.nextMatch,
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            meta: true,
            shift: true,
          ): c.previousMatch,
          const SingleActivator(LogicalKeyboardKey.keyL, meta: true):
              c.openGoToLine,
        } else ...{
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              c.openSearch,
          const SingleActivator(LogicalKeyboardKey.keyH, control: true): () =>
              c.openSearch(replace: true),
          const SingleActivator(LogicalKeyboardKey.keyG, control: true):
              c.openGoToLine,
        },
        const SingleActivator(LogicalKeyboardKey.f3): c.nextMatch,
        const SingleActivator(LogicalKeyboardKey.f3, shift: true):
            c.previousMatch,
        if (c.searchOpen || c.goToLineOpen)
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
      },
      child: Column(
        children: [
          if (c.goToLineOpen) ...[
            _goToLineBar(context),
            const Divider(height: 1),
          ],
          if (widget.banner != null) widget.banner!,
          if (c.searchOpen) ...[_searchBar(context), const Divider(height: 1)],
          Expanded(
            child: _decorated(
              context,
              _lineCommands(context, _bracketCommands(context, _body())),
            ),
          ),
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

  Widget _goToLineBar(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Icon(
            Icons.format_list_numbered,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: c.goToLineInput,
              focusNode: c.goToLineFocus,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              // A text keyboard, so touch devices can type line:column.
              keyboardType: TextInputType.text,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: strings.goToLineHint(c.lineStarts.length),
                errorText: c.goToLineInputInvalid
                    ? strings.goToLineInvalid(c.lineStarts.length)
                    : null,
                isDense: true,
                border: InputBorder.none,
              ),
              onSubmitted: (_) {
                if (c.submitGoToLine()) return;
                // Keep the field and select its text, so typing replaces it.
                c.goToLineInput.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: c.goToLineInput.text.length,
                );
                c.goToLineFocus.requestFocus();
              },
            ),
          ),
          ExcludeFocus(
            child: IconButton(
              tooltip: strings.closeGoToLine,
              visualDensity: VisualDensity.compact,
              onPressed: c.closeGoToLine,
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBar(BuildContext context) {
    final (line, column) = c.caretLineColumn;
    final document = c.document;
    final selected = c.selectionStats;
    final status = [
      if (selected.characters > 0)
        widget.strings.selectionSummary(selected.characters, selected.lines),
      if (c.isSaving) widget.strings.saving,
      if (c.isDirty) widget.strings.unsaved,
      document?.lineEnding == LineEnding.crlf ? 'CRLF' : 'LF',
      document?.hasUtf8Bom == true ? 'UTF-8 BOM' : 'UTF-8',
      widget.strings.indentation(c.indentation),
      widget.strings.languageName(c.text.language),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Tooltip(
                message: widget.strings.goToLine,
                child: InkWell(
                  onTap: c.openGoToLine,
                  borderRadius: BorderRadius.circular(4),
                  child: Text(
                    widget.strings.documentPosition(
                      line,
                      column,
                      c.lineStarts.length,
                      c.fileByteCount,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
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
                    _IndentIntent: _EditAction<_IndentIntent>(
                      enabled: () => !_locked,
                      run: c.indent,
                      heldWhileComposing: _composing,
                    ),
                    _OutdentIntent: _EditAction<_OutdentIntent>(
                      enabled: () => !_locked,
                      run: c.outdent,
                      heldWhileComposing: _composing,
                    ),
                    _NewlineIntent: _EditAction<_NewlineIntent>(
                      enabled: () => !_locked,
                      run: c.insertNewline,
                    ),
                    _DeleteIndentIntent: _EditAction<_DeleteIndentIntent>(
                      enabled: () => !_locked && c.canDeleteIndentBackward,
                      run: c.deleteIndentBackward,
                    ),
                  },
                  child: Shortcuts(
                    shortcuts: {
                      if (widget.tabKeyBehavior ==
                          EditorTabKeyBehavior.indent) ...const {
                        SingleActivator(LogicalKeyboardKey.tab):
                            _IndentIntent(),
                        SingleActivator(LogicalKeyboardKey.tab, shift: true):
                            _OutdentIntent(),
                      },
                      const SingleActivator(LogicalKeyboardKey.enter):
                          const _NewlineIntent(),
                      const SingleActivator(LogicalKeyboardKey.numpadEnter):
                          const _NewlineIntent(),
                      const SingleActivator(LogicalKeyboardKey.backspace):
                          const _DeleteIndentIntent(),
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
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(_padding),
                        hintText: widget.placeholder,
                        hintStyle: _style.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                          fontStyle: FontStyle.italic,
                        ),
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

  /// Line commands, bound around the document field only so the find fields
  /// keep their own arrow keys.
  Widget _lineCommands(BuildContext context, Widget document) {
    final apple = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    return Shortcuts(
      shortcuts: apple ? _appleLineShortcuts : _lineShortcuts,
      child: Actions(actions: _lineActions, child: document),
    );
  }

  // Built once: a new map or action on every keystroke's rebuild would make
  // the shortcut manager re-index and the actions notify their dependents.
  late final Map<Type, Action<Intent>> _lineActions = {
    _LineCommandIntent: _LineCommandAction(() => c),
  };
  static final _appleLineShortcuts = _lineCommandShortcuts(apple: true);
  static final _lineShortcuts = _lineCommandShortcuts(apple: false);

  /// Command on Apple platforms and Control elsewhere; Option or Alt with an
  /// arrow moves lines on every platform.
  static Map<ShortcutActivator, Intent> _lineCommandShortcuts({
    required bool apple,
  }) {
    SingleActivator primary(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, meta: apple, control: !apple, shift: shift);
    return {
      primary(LogicalKeyboardKey.keyD, shift: true): const _LineCommandIntent(
        _LineCommand.duplicate,
      ),
      const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
          const _LineCommandIntent(_LineCommand.moveUp),
      const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
          const _LineCommandIntent(_LineCommand.moveDown),
      primary(LogicalKeyboardKey.keyK, shift: true): const _LineCommandIntent(
        _LineCommand.delete,
      ),
      primary(LogicalKeyboardKey.keyJ): const _LineCommandIntent(
        _LineCommand.join,
      ),
      primary(LogicalKeyboardKey.slash): const _LineCommandIntent(
        _LineCommand.toggleComment,
      ),
    };
  }

  /// Go to Matching Bracket, bound around the document field only so the
  /// find fields keep their own keys.
  Widget _bracketCommands(BuildContext context, Widget document) {
    final apple = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    return Shortcuts(
      shortcuts: apple ? _appleBracketShortcuts : _bracketShortcuts,
      child: Actions(actions: _bracketActions, child: document),
    );
  }

  // Built once: a new map or action on every keystroke's rebuild would make
  // the shortcut manager re-index and the actions notify their dependents.
  late final Map<Type, Action<Intent>> _bracketActions = {
    _BracketJumpIntent: _BracketJumpAction(() => c),
  };
  static final _appleBracketShortcuts = _bracketJumpShortcuts(apple: true);
  static final _bracketShortcuts = _bracketJumpShortcuts(apple: false);

  /// Command+B on Apple platforms and Control+B elsewhere; Shift selects.
  static Map<ShortcutActivator, Intent> _bracketJumpShortcuts({
    required bool apple,
  }) => {
    SingleActivator(LogicalKeyboardKey.keyB, meta: apple, control: !apple):
        const _BracketJumpIntent(extend: false),
    SingleActivator(
      LogicalKeyboardKey.keyB,
      meta: apple,
      control: !apple,
      shift: true,
    ): const _BracketJumpIntent(
      extend: true,
    ),
  };

  bool _composing() => c.text.value.composing.isValid;

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

final class _IndentIntent extends Intent {
  const _IndentIntent();
}

final class _OutdentIntent extends Intent {
  const _OutdentIntent();
}

final class _NewlineIntent extends Intent {
  const _NewlineIntent();
}

final class _DeleteIndentIntent extends Intent {
  const _DeleteIndentIntent();
}

/// A disabled or declined edit lets its key fall through to Flutter's default
/// text handling, so ordinary typing, focus traversal and input methods keep
/// working whenever the indentation-aware edit does not apply. An edit
/// declines, for example, while an input method is composing.
final class _EditAction<T extends Intent> extends Action<T> {
  _EditAction({
    required this.enabled,
    required this.run,
    this.heldWhileComposing,
  });

  final bool Function() enabled;
  final bool Function() run;

  /// For Tab: while an input method composes, the key belongs to it. Declining
  /// the edit must not let focus traversal take the key and pull focus out of
  /// the document mid-composition, so the key goes on to the platform.
  final bool Function()? heldWhileComposing;

  @override
  bool isEnabled(T intent) => enabled();

  @override
  Object? invoke(T intent) => run();

  @override
  KeyEventResult toKeyEventResult(T intent, Object? invokeResult) {
    if (invokeResult == true) return KeyEventResult.handled;
    if (heldWhileComposing?.call() ?? false) {
      return KeyEventResult.skipRemainingHandlers;
    }
    return KeyEventResult.ignored;
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

enum _LineCommand { duplicate, moveUp, moveDown, delete, join, toggleComment }

class _LineCommandIntent extends Intent {
  const _LineCommandIntent(this.command);
  final _LineCommand command;
}

/// Runs a line command. While the buffer cannot be edited (read-only,
/// loading, or an input method composing) the key is left to the text
/// field, so Option+arrow still moves the caret in a locked document. A
/// command that does not apply, such as moving the first line up, still
/// consumes its key rather than falling through to an unrelated binding.
class _LineCommandAction extends Action<_LineCommandIntent> {
  // Read on each use, since the view can be handed another controller.
  _LineCommandAction(this._controller);
  final EditorController Function() _controller;

  @override
  bool isEnabled(_LineCommandIntent intent) =>
      intent.command == _LineCommand.toggleComment
      ? _controller().canToggleComment
      : _controller().canEditText;

  @override
  bool invoke(_LineCommandIntent intent) {
    final controller = _controller();
    return switch (intent.command) {
      _LineCommand.duplicate => controller.duplicateLines(),
      _LineCommand.moveUp => controller.moveLines(LineDirection.up),
      _LineCommand.moveDown => controller.moveLines(LineDirection.down),
      _LineCommand.delete => controller.deleteLines(),
      _LineCommand.join => controller.joinLines(),
      _LineCommand.toggleComment => controller.toggleComment(),
    };
  }
}

class _BracketJumpIntent extends Intent {
  const _BracketJumpIntent({required this.extend});
  final bool extend;
}

/// Runs Go to Matching Bracket. While the caret cannot move (loading, or an
/// input method composing) the key is left to the text field. With nowhere
/// to jump, the key is still consumed rather than reaching an unrelated
/// binding.
class _BracketJumpAction extends Action<_BracketJumpIntent> {
  // Read on each use, since the view can be handed another controller.
  _BracketJumpAction(this._controller);
  final EditorController Function() _controller;

  @override
  bool isEnabled(_BracketJumpIntent intent) => _controller().canMoveCaret;

  @override
  bool invoke(_BracketJumpIntent intent) =>
      _controller().goToMatchingBracket(extend: intent.extend);
}
