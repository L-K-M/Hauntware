import 'dart:async';

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

  /// Holds focus while anything in the find bar does, its buttons included,
  /// so Escape can tell which open bar the user is in.
  final _searchBarFocus = FocusNode(
    debugLabel: 'find bar',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The same for the tool bar's fields and controls.
  final _toolBarFocus = FocusNode(
    debugLabel: 'tool bar',
    canRequestFocus: false,
    skipTraversal: true,
  );
  int _lastReveal = -1;

  /// Whether this view's route is on top. A tab activated while a dialog is
  /// up, such as the one a close prompt shows, restores focus once the
  /// dialog is gone instead of taking the keyboard from it.
  bool _routeIsCurrent = true;
  bool _restoreWhenCurrent = false;
  bool _routeSeen = false;

  /// The controller's install count this view has handed focus over for.
  /// Read when the view attaches, not lazily on the first change: an install
  /// that changes neither text nor caret can be that first change.
  late int _installSeen;
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
    _installSeen = c.installGeneration;
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
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (!_routeSeen) {
      _routeSeen = true;
      _routeIsCurrent = current;
      // An editor that appears active under a dialog, such as a tab the
      // native menu opened under the command palette, does not autofocus
      // over it: Flutter would let it take the dialog's focus. It focuses
      // once its route is on top.
      _restoreWhenCurrent = !current && widget.isActive;
      return;
    }
    if (current == _routeIsCurrent) return;
    _routeIsCurrent = current;
    if (!current || !_restoreWhenCurrent) return;
    _restoreWhenCurrent = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) c.restoreFocus();
    });
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
      _installSeen = c.installGeneration;
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
          if (_routeIsCurrent) {
            c.restoreFocus();
          } else {
            _restoreWhenCurrent = true;
          }
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
    if (_installSeen != c.installGeneration) {
      _installSeen = c.installGeneration;
      _carryOverInstall();
    }
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

  /// Each install gets a new document field (see the [KeyedSubtree] in the
  /// build), which starts unscrolled and, since its focus node already has
  /// focus, never sees the focus change that opens an input connection:
  /// typing would go nowhere. Hand focus off now and back to the new field
  /// once it is built, and restore the scroll offset.
  void _carryOverInstall() {
    final offset = c.scroll.hasClients ? c.scroll.offset : null;
    final focused = c.editorFocus.hasFocus;
    if (focused) c.editorFocus.unfocus(disposition: UnfocusDisposition.scope);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (offset != null && c.scroll.hasClients) {
        final position = c.scroll.position;
        c.scroll.jumpTo(
          offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
      if (!focused) return;
      // A dialog that opened meanwhile keeps the keyboard; the document takes
      // it back when the dialog closes.
      if (_routeIsCurrent) {
        c.editorFocus.requestFocus();
      } else {
        _restoreWhenCurrent = true;
      }
    });
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
    if (c.toolBarOpen) {
      c.closeTextTool();
    } else if (c.goToLineOpen && !_searchBarFocus.hasFocus) {
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
    _searchBarFocus.dispose();
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
        if (c.searchOpen || c.goToLineOpen || c.toolBarOpen)
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
      },
      child: Column(
        children: [
          if (c.goToLineOpen) ...[
            _goToLineBar(context),
            const Divider(height: 1),
          ],
          if (widget.banner != null) widget.banner!,
          if (c.searchOpen) ...[
            Focus(
              focusNode: _searchBarFocus,
              canRequestFocus: false,
              skipTraversal: true,
              child: _searchBar(context),
            ),
            const Divider(height: 1),
          ],
          // The tool bar shares the find bar's slot; the controller keeps
          // the two mutually exclusive.
          if (c.toolBarOpen && c.toolBarTool != null) ...[
            Focus(
              focusNode: _toolBarFocus,
              canRequestFocus: false,
              skipTraversal: true,
              child: _toolBar(context, c.toolBarTool!),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: Stack(
              children: [
                _decorated(
                  context,
                  _lineCommands(context, _bracketCommands(context, _body())),
                ),
                if (c.toolReport case final report?)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      // The opaque pill would otherwise swallow taps on the
                      // document's bottom lines; a tap dismisses it.
                      child: GestureDetector(
                        onTap: c.clearToolReport,
                        child: _toolNotice(context, report),
                      ),
                    ),
                  ),
              ],
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
    // A pattern that cannot be searched says why instead of reporting no
    // matches, which would look like a file with nothing to find. While its
    // matches are on their way, nothing is claimed either way.
    final failure = c.patternFailure;
    final counter = switch (failure) {
      PatternUnusable(:final message) => strings.patternInvalid(message),
      PatternTimedOut() => strings.patternTooSlow,
      null when c.search.text.isEmpty => '',
      null when c.matches.isEmpty && c.patternSearchPending => '',
      null when c.matches.isEmpty => strings.noMatches,
      null => strings.matchCount(
        c.matchOffset + c.activeMatch + 1,
        c.matchOffset + c.matches.length,
        capped: c.matchesMayContinue,
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Column(
        children: [
          _searchRow(
            field: TextField(
              controller: c.search,
              focusNode: c.searchFocus,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: c.useRegularExpression
                    ? strings.findPatternHint
                    : strings.findHint,
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
            controls: [
              if (c.searchScope != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Tooltip(
                    message: strings.searchScopeHint,
                    child: InputChip(
                      label: Text(strings.searchInSelection),
                      labelStyle: theme.textTheme.labelSmall,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                      onDeleted: c.clearSearchScope,
                    ),
                  ),
                ),
              if (counter.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Semantics(
                    liveRegion: failure != null,
                    child: Text(
                      counter,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: failure != null ? theme.colorScheme.error : null,
                      ),
                    ),
                  ),
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
              Wrap(
                children: [
                  IconButton(
                    isSelected: c.caseSensitive,
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
                    isSelected: c.wholeWord,
                    tooltip: strings.wholeWords,
                    visualDensity: VisualDensity.compact,
                    onPressed: c.toggleWholeWord,
                    icon: Text(
                      'ab',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        decoration: c.wholeWord
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        color: c.wholeWord
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    isSelected: c.useRegularExpression,
                    tooltip: strings.regularExpression,
                    visualDensity: VisualDensity.compact,
                    onPressed: c.toggleRegularExpression,
                    icon: Text(
                      '.*',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: c.useRegularExpression
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    isSelected: c.lineActionsOpen,
                    tooltip: strings.lineActions,
                    visualDensity: VisualDensity.compact,
                    onPressed: c.toggleLineActions,
                    icon: const Icon(Icons.filter_list),
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
                    isSelected: c.replaceOpen,
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
            ],
          ),
          if (c.lineActionsOpen) _lineActionsRow(context),
          if (c.extractOpen) _extractRow(context),
          if (c.replaceOpen)
            _searchRow(
              field: TextField(
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
              controls: [
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
        ],
      ),
    );
  }

  /// The line-action row: the live matching-line count and the Keep and
  /// Delete buttons that apply it to the document.
  Widget _lineActionsRow(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    final failure = c.lineCountFailure;
    final count = c.lineActionCount;
    final label = switch (failure) {
      PatternUnusable(:final message) => strings.patternInvalid(message),
      PatternTimedOut() => strings.patternTooSlow,
      _ when count != null => strings.lineMatchCount(count),
      _ => '',
    };
    final ready = !_locked && !c.isBusy && c.canEditText && count != null;
    return _searchRow(
      field: Text(
        label,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: failure != null ? theme.colorScheme.error : null,
        ),
      ),
      controls: [
        TextButton(
          onPressed: ready
              ? () => unawaited(c.applyLineFilter(keep: true))
              : null,
          child: Text(strings.keepMatchingLines),
        ),
        TextButton(
          onPressed: ready
              ? () => unawaited(c.applyLineFilter(keep: false))
              : null,
          child: Text(strings.deleteMatchingLines),
        ),
      ],
    );
  }

  /// The extraction row: the optional replacement template, the whole
  /// lines toggle, the destination picker and the Extract button.
  Widget _extractRow(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    final failure = c.lineCountFailure;
    final count = c.lineActionCount;
    final ready = !_locked && !c.isBusy && c.canEditText && count != null;
    final targets = [
      'inPlace',
      'clipboard',
      if (c.canExtractToNewDocument) 'newDocument',
    ];
    return _searchRow(
      field: TextField(
        controller: c.extraction,
        focusNode: c.extractionFocus,
        autocorrect: false,
        enableSuggestions: false,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: strings.extractTemplateHint,
          isDense: true,
          border: InputBorder.none,
        ),
        onSubmitted: (_) {
          if (ready) unawaited(c.applyExtract());
        },
      ),
      controls: [
        if (failure != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              switch (failure) {
                PatternUnusable(:final message) => strings.patternInvalid(
                  message,
                ),
                _ => strings.patternTooSlow,
              },
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          )
        else if (count != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              strings.extractCount(count, wholeLines: c.extractWholeLines),
              style: theme.textTheme.labelSmall,
            ),
          ),
        IconButton(
          isSelected: c.extractWholeLines,
          tooltip: strings.extractWholeLinesTooltip,
          visualDensity: VisualDensity.compact,
          onPressed: () => c.setExtractWholeLines(!c.extractWholeLines),
          icon: const Icon(Icons.subject),
        ),
        DropdownButton<String>(
          value: targets.contains(c.extractTarget)
              ? c.extractTarget
              : 'inPlace',
          underline: const SizedBox.shrink(),
          isDense: true,
          items: [
            for (final target in targets)
              DropdownMenuItem(
                value: target,
                child: Text(strings.textToolChoiceName(target)),
              ),
          ],
          onChanged: (value) {
            if (value != null) c.setExtractTarget(value);
          },
        ),
        TextButton(
          onPressed: ready ? () => unawaited(c.applyExtract()) : null,
          child: Text(strings.extractAction),
        ),
      ],
    );
  }

  Widget _searchRow({
    required Widget field,
    required List<Widget> controls,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      const inlineWidth = 600.0;
      final fontSize = Theme.of(context).textTheme.bodyMedium!.fontSize!;
      final textScale =
          MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
      final inline = constraints.maxWidth >= inlineWidth * textScale;
      final actions = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: controls,
      );

      // Stack narrow layouts without replacing field elements, preserving the
      // input connection and composition while resizing. Long labels wrap.
      return Flex(
        direction: inline ? Axis.horizontal : Axis.vertical,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: inline
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: inline ? 1 : 0, child: field),
          Expanded(flex: inline ? 1 : 0, child: actions),
        ],
      );
    },
  );

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

  /// The inline options bar a "…" text tool opens: its declared options,
  /// a scope line, and the dry-run count, in the find bar's slot.
  Widget _toolBar(BuildContext context, TextTool tool) => _ToolBar(
    key: ValueKey(tool.id),
    controller: c,
    strings: widget.strings,
    locked: _locked,
  );

  Widget _statusBar(BuildContext context) {
    final (line, column) = c.caretLineColumn;
    final selected = c.selectionStats;
    final status = [
      if (selected.characters > 0)
        widget.strings.selectionSummary(selected.characters, selected.lines),
      if (c.isSaving) widget.strings.saving,
      if (c.isDirty) widget.strings.unsaved,
      c.metadata.lineEnding == LineEnding.crlf ? 'CRLF' : 'LF',
      c.metadata.utf8Bom == Utf8Bom.present ? 'UTF-8 BOM' : 'UTF-8',
      widget.strings.indentation(c.indentation),
      widget.strings.languageName(c.text.language),
      if (!c.highlightingEnabled) widget.strings.largeFile,
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

  /// The one-line notice a text-tool run leaves over the document's bottom
  /// edge, until the next edit replaces it. It never takes focus — the
  /// document keeps it — so the Undo it offers is a button, while the
  /// keyboard's undo stays the usual shortcut.
  Widget _toolNotice(BuildContext context, TextToolReport report) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: ExcludeFocus(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Material(
            elevation: 2,
            color: theme.colorScheme.inverseSurface,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.strings.textToolNotice(report),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ),
                  if (report.outcome is TextToolChanged &&
                      c.undoController.value.canUndo)
                    TextButton(
                      onPressed: c.undoController.undo,
                      // inverseSurface pairs with inversePrimary — the
                      // default primary falls below readable contrast.
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.inversePrimary,
                      ),
                      child: Text(widget.strings.undo),
                    ),
                ],
              ),
            ),
          ),
        ),
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
                child: KeyedSubtree(
                  // A new document field per installed buffer: the field's
                  // undo history cannot be cleared, and must not reach back
                  // past a load, reload or revert into the previous text.
                  key: ValueKey(c.installGeneration),
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
                        keepsKey: true,
                      ),
                      _OutdentIntent: _EditAction<_OutdentIntent>(
                        enabled: () => !_locked,
                        run: c.outdent,
                        heldWhileComposing: _composing,
                        keepsKey: true,
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
                        autofocus: widget.isActive && _routeIsCurrent,
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
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.6),
                            fontStyle: FontStyle.italic,
                          ),
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

/// The tool bar itself. It owns one text field per free-text and integer
/// option for as long as the bar is open; those fields join the
/// controller's [EditorController.textFocusNodes], so clipboard routing
/// and the host's document-in-use gate see them like the find fields.
class _ToolBar extends StatefulWidget {
  const _ToolBar({
    super.key,
    required this.controller,
    required this.strings,
    required this.locked,
  });

  final EditorController controller;
  final EditorStrings strings;
  final bool locked;

  @override
  State<_ToolBar> createState() => _ToolBarState();
}

class _ToolBarState extends State<_ToolBar> {
  final _fields = <String, TextEditingController>{};
  final _nodes = <String, FocusNode>{};

  /// The first field's option id — it opens focused.
  String? _firstField;

  EditorController get c => widget.controller;
  TextTool get tool => c.toolBarTool!;

  @override
  void initState() {
    super.initState();
    for (final option in tool.options) {
      if (option is! TextOption && option is! IntegerOption) continue;
      final value = c.toolBarOptions[option.id];
      _fields[option.id] = TextEditingController(
        text: value is int ? '$value' : value as String? ?? '',
      );
      final node = FocusNode(debugLabel: 'tool option ${option.id}');
      _nodes[option.id] = node;
      c.trackTextField(node);
      _firstField ??= option.id;
    }
    // The document field is autofocus too and, being earlier in the scope,
    // wins every autofocus race — so the bar asks for its first field
    // outright once it exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes[_firstField]?.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      c.untrackTextField(node);
      node.dispose();
    }
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _submitInteger(TextToolOption option, String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return;
    final minimum = (option as IntegerOption).min;
    c.setToolOption(option.id, parsed < minimum ? minimum : parsed);
  }

  /// The gate both Apply paths — the button and a field's Enter — share.
  bool get _canApply =>
      !widget.locked &&
      c.canEditText &&
      c.toolBarTool != null &&
      c.toolBarPreview?.outcome is! TextToolRefused;

  void _apply() {
    if (_canApply) unawaited(c.applyTextTool());
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    final options = c.toolBarOptions;
    final preview = c.toolBarPreview;

    final controls = <Widget>[
      Text(toolBarName(strings), style: theme.textTheme.titleSmall),
      for (final option in tool.options)
        switch (option) {
          ToggleOption() => _toggle(strings, option, options[option.id]),
          ChoiceOption() => _choice(strings, option, options[option.id]),
          _ => _field(strings, option),
        },
      IconButton(
        tooltip: strings.textToolClose,
        visualDensity: VisualDensity.compact,
        onPressed: c.closeTextTool,
        icon: const Icon(Icons.close),
      ),
    ];

    final (selected, document) = c.toolBarScopeLines;
    final scope = _scopeLine(strings, tool, selected, document);
    final count = preview != null
        ? strings.textToolPreview(preview)
        : c.toolBarPreviewDeferred
        ? strings.textToolPreviewDeferred
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 4,
            children: controls,
          ),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            children: [
              ...scope,
              FilledButton(
                onPressed: _canApply ? _apply : null,
                child: Text(strings.textToolApply),
              ),
            ],
          ),
          if (count.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(count, style: theme.textTheme.labelSmall),
            ),
        ],
      ),
    );
  }

  /// The tool's name as the bar's heading.
  String toolBarName(EditorStrings strings) => strings.textToolName(tool.id);

  List<Widget> _scopeLine(
    EditorStrings strings,
    TextTool tool,
    int selected,
    int document,
  ) {
    final label = Text(
      strings.textToolAppliesTo,
      style: Theme.of(context).textTheme.labelSmall,
    );
    // A document tool with a selection offers the choice; the rest state
    // their scope plainly.
    if (tool.scope == TextToolScope.document && selected > 0) {
      return [
        label,
        _scopeRadio(strings.textToolSelectedLines(selected), false),
        _scopeRadio(strings.textToolWholeDocument(document), true),
      ];
    }
    final text = switch (tool.scope) {
      TextToolScope.document => strings.textToolNothingSelected(document),
      TextToolScope.selection => strings.textToolSelectedLines(selected),
      TextToolScope.paragraph => strings.textToolParagraphAtCaret,
      TextToolScope.word => strings.textToolWordAtCaret,
      TextToolScope.insertion => strings.textToolAtCaret,
    };
    return [label, Text(text, style: Theme.of(context).textTheme.labelSmall)];
  }

  Widget _scopeRadio(String label, bool wholeDocument) => InkWell(
    onTap: () => c.setToolBarScope(wholeDocument: wholeDocument),
    borderRadius: BorderRadius.circular(4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          c.toolBarWholeDocument == wholeDocument
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          size: 16,
          color: c.toolBarWholeDocument == wholeDocument
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );

  Widget _toggle(EditorStrings strings, ToggleOption option, Object? value) =>
      InkWell(
        onTap: () => c.setToolOption(option.id, value != true),
        borderRadius: BorderRadius.circular(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value == true,
              visualDensity: VisualDensity.compact,
              onChanged: (next) => c.setToolOption(option.id, next ?? false),
            ),
            Text(
              strings.textToolOptionName(tool.id, option.id),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      );

  Widget _choice(EditorStrings strings, ChoiceOption option, Object? value) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            strings.textToolOptionName(tool.id, option.id),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(width: 6),
          DropdownButton<String>(
            value: value as String? ?? option.defaultValue as String,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final choice in option.choices)
                DropdownMenuItem(
                  value: choice,
                  child: Text(
                    strings.textToolChoiceName(choice),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
            ],
            onChanged: (next) {
              if (next != null) c.setToolOption(option.id, next);
            },
          ),
        ],
      );

  Widget _field(EditorStrings strings, TextToolOption option) => SizedBox(
    width: option is IntegerOption ? 72 : 160,
    child: TextField(
      controller: _fields[option.id],
      focusNode: _nodes[option.id],
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: option is IntegerOption
          ? TextInputType.number
          : TextInputType.text,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        labelText: strings.textToolOptionName(tool.id, option.id),
        isDense: true,
      ),
      onChanged: (value) => option is IntegerOption
          ? _submitInteger(option, value)
          : c.setToolOption(option.id, value),
      onSubmitted: (_) => _apply(),
    ),
  );
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
    this.keepsKey = false,
  });

  final bool Function() enabled;
  final bool Function() run;

  /// For Tab: while an input method composes, the key belongs to it. Declining
  /// the edit must not let focus traversal take the key and pull focus out of
  /// the document mid-composition, so the key goes on to the platform.
  final bool Function()? heldWhileComposing;

  /// For Tab and Shift+Tab, which the document claims in indent mode: an
  /// edit with nothing to change, such as Shift+Tab on an unindented line,
  /// still keeps the key, or focus traversal would carry focus out of the
  /// document.
  final bool keepsKey;

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
    return keepsKey ? KeyEventResult.handled : KeyEventResult.ignored;
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
