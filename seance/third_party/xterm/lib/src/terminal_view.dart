import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';

import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/gesture/gesture_handler.dart';
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/src/ui/keyboard_visibility.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/scroll_handler.dart';
import 'package:xterm/src/ui/shortcut/actions.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

enum _SelectionHandle { start, end }

/// [seance fork] The keys [TerminalViewState._linkModifierOutranksRemote]
/// reads.
final _linkModifierKeys = {
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
};

class TerminalView extends StatefulWidget {
  const TerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.backgroundOpacity = 1,
    this.focusNode,
    this.autofocus = false,
    this.onTapUp,
    this.onLinkTap,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTouchSelectionEnd,
    this.mouseCursor = SystemMouseCursors.text,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.alwaysShowCursor = false,
    this.deleteDetection = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  final TerminalController? controller;

  /// The theme to use for this terminal.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  final TextScaler? textScaler;

  /// Padding around the inner [Scrollable] widget.
  final EdgeInsets? padding;

  /// Scroll controller for the inner [Scrollable] widget.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Opacity of the terminal background. Set to 0 to make the terminal
  /// background transparent.
  final double backgroundOpacity;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// [seance fork] Opens visible HTTP(S) links on Ctrl-click (Cmd-click on
  /// Apple platforms) or touch tap. Plain mouse clicks retain selection behavior.
  final ValueChanged<Uri>? onLinkTap;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// [seance fork] Called when a touch gesture has selected text: a
  /// long-press (with or without a drag) or a double/triple tap. Touch has
  /// no secondary click, so this is where a host shows its selection
  /// toolbar, at [TerminalViewState.selectionToolbarAnchors].
  final VoidCallback? onTouchSelectionEnd;

  /// The mouse cursor for mouse pointers that are hovering over the terminal.
  /// [SystemMouseCursors.text] by default.
  final MouseCursor mouseCursor;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Whether to always show the cursor. This is useful for debugging.
  /// [false] by default.
  final bool alwaysShowCursor;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Prefered on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  final bool simulateScroll;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView> {
  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();

  final _selectionStartLink = LayerLink();
  final _selectionEndLink = LayerLink();
  SelectionOverlay? _selectionOverlay;
  _SelectionHandle? _draggingHandle;
  CellAnchor? _handleDragAnchor;
  Offset? _handleDragPosition;

  String? _composingText;

  int _tapCount = 0;

  /// [seance fork] The link the press now down opens instead of reaching a
  /// mouse-reporting remote, captured at mouse-down, or null when that press
  /// reaches the remote; see [_claimPressForLink].
  Uri? _pressOpensLink;

  Uri? _hoveredLink;
  bool _hoverInvalidationPending = false;

  /// [seance fork] Global position of the mouse hovering the view, or null
  /// once it leaves. Holding Cmd changes which links show, and the pointer
  /// may not move when it does.
  Offset? _hoverPosition;

  /// [seance fork] The cell of the last plain primary click, kept as a
  /// content-glued buffer anchor so a later shift-click can select the range
  /// between the two points (even across scrolling or trimming in between).
  CellAnchor? _lastTapAnchor;

  late TerminalController _controller;

  late ScrollController _scrollController;

  RenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as RenderTerminal;

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    widget.terminal.addListener(_invalidateLinkHover);
    _scrollController.addListener(_invalidateLinkHover);
    _controller.addListener(_invalidateLinkHover);
    _controller.addListener(_updateSelectionHandles);
    widget.terminal.addListener(_updateSelectionHandles);
    _focusNode.addListener(_onSelectionFocusChange);
    HardwareKeyboard.instance.addHandler(_onLinkModifierKey);
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    super.initState();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    if (oldWidget.focusNode != widget.focusNode) {
      _hideSelectionHandles();
      _focusNode.removeListener(_onSelectionFocusChange);
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_onSelectionFocusChange);
    }
    if (oldWidget.controller != widget.controller) {
      _hideSelectionHandles();
      _controller.removeListener(_invalidateLinkHover);
      _controller.removeListener(_updateSelectionHandles);
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
      _controller.addListener(_invalidateLinkHover);
      _controller.addListener(_updateSelectionHandles);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      _scrollController.removeListener(_invalidateLinkHover);
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
      _scrollController.addListener(_invalidateLinkHover);
    }
    if (oldWidget.terminal != widget.terminal) {
      _hideSelectionHandles();
      oldWidget.terminal.removeListener(_invalidateLinkHover);
      oldWidget.terminal.removeListener(_updateSelectionHandles);
      widget.terminal.addListener(_invalidateLinkHover);
      widget.terminal.addListener(_updateSelectionHandles);
      // [seance fork] The recorded click belongs to the old terminal's
      // buffer; resolving it against the new one would mix coordinate
      // spaces (and can throw — the new buffer may be far shorter).
      _lastTapAnchor?.dispose();
      _lastTapAnchor = null;
    }
    _hoveredLink = null;
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    super.didUpdateWidget(oldWidget);
  }

  @override
  void deactivate() {
    _hideSelectionHandles();
    super.deactivate();
  }

  @override
  void dispose() {
    _hideSelectionHandles();
    widget.terminal.removeListener(_invalidateLinkHover);
    widget.terminal.removeListener(_updateSelectionHandles);
    _scrollController.removeListener(_invalidateLinkHover);
    _controller.removeListener(_invalidateLinkHover);
    _controller.removeListener(_updateSelectionHandles);
    _focusNode.removeListener(_onSelectionFocusChange);
    HardwareKeyboard.instance.removeHandler(_onLinkModifierKey);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _shortcutManager.dispose();
    _lastTapAnchor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_selectionOverlay != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateSelectionHandles();
      });
    }
    Widget child = Scrollable(
      key: _scrollableKey,
      controller: _scrollController,
      viewportBuilder: (context, offset) {
        return _TerminalView(
          key: _viewportKey,
          terminal: widget.terminal,
          controller: _controller,
          offset: offset,
          padding: MediaQuery.of(context).padding,
          autoResize: widget.autoResize,
          textStyle: widget.textStyle,
          textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
          theme: widget.theme,
          focusNode: _focusNode,
          cursorType: widget.cursorType,
          alwaysShowCursor: widget.alwaysShowCursor,
          onEditableRect: _onEditableRect,
          composingText: _composingText,
          selectionStartLink: _selectionStartLink,
          selectionEndLink: _selectionEndLink,
        );
      },
    );

    child = TerminalScrollGestureHandler(
      terminal: widget.terminal,
      simulateScroll: widget.simulateScroll,
      // [seance fork] The scroll handler records *global* pointer positions;
      // getCellOffset expects local ones. Upstream passed them through
      // unconverted, mis-aiming alt-buffer wheel reports.
      getCellOffset: (offset) =>
          renderTerminal.getCellOffset(renderTerminal.globalToLocal(offset)),
      getLineHeight: () => renderTerminal.lineHeight,
      child: child,
    );

    if (!widget.hardwareKeyboardOnly) {
      child = CustomTextEdit(
        key: _customTextEditKey,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        inputType: widget.keyboardType,
        keyboardAppearance: widget.keyboardAppearance,
        deleteDetection: widget.deleteDetection,
        onInsert: _onInsert,
        onDelete: () {
          _scrollToBottom();
          widget.terminal.keyInput(TerminalKey.backspace);
        },
        onComposing: _onComposing,
        onAction: (action) {
          _scrollToBottom();
          if (action == TextInputAction.done) {
            widget.terminal.keyInput(TerminalKey.enter);
          }
        },
        onKeyEvent: _handleKeyEvent,
        readOnly: widget.readOnly,
        child: child,
      );
    } else if (!widget.readOnly) {
      // Only listen for key input from a hardware keyboard.
      child = CustomKeyboardListener(
        child: child,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onInsert: _onInsert,
        onComposing: _onComposing,
        onKeyEvent: _handleKeyEvent,
      );
    }

    child = TerminalActions(
      terminal: widget.terminal,
      controller: _controller,
      child: child,
    );

    child = KeyboardVisibilty(
      onKeyboardShow: _onKeyboardShow,
      child: child,
    );

    child = TerminalGestureHandler(
      terminalView: this,
      terminalController: _controller,
      onTapUp: _onTapUp,
      onTapDown: _onTapDown,
      onSecondaryTapDown:
          widget.onSecondaryTapDown != null ? _onSecondaryTapDown : null,
      onSecondaryTapUp:
          widget.onSecondaryTapUp != null ? _onSecondaryTapUp : null,
      onLongPressEnd: (_) => _onTouchSelectionEnd(),
      claimPressForLink: _claimPressForLink,
      readOnly: widget.readOnly,
      child: child,
    );

    child = MouseRegion(
      cursor: widget.onLinkTap != null && _hoveredLink != null
          ? SystemMouseCursors.click
          : widget.mouseCursor,
      onHover: widget.onLinkTap == null ? null : _onLinkHover,
      onExit: (_) {
        _hoverPosition = null;
        _setHoveredLink(null);
      },
      child: child,
    );

    child = Container(
      color: widget.theme.background.withOpacity(widget.backgroundOpacity),
      padding: widget.padding,
      child: child,
    );

    return child;
  }

  void requestKeyboard() {
    _customTextEditKey.currentState?.requestKeyboard();
  }

  void closeKeyboard() {
    _customTextEditKey.currentState?.closeKeyboard();
  }

  Rect get cursorRect {
    return renderTerminal.cursorOffset & renderTerminal.cellSize;
  }

  Rect get globalCursorRect {
    return renderTerminal.localToGlobal(renderTerminal.cursorOffset) &
        renderTerminal.cellSize;
  }

  void _onLinkHover(PointerHoverEvent event) {
    _hoverPosition = event.position;
    _refreshLinkHover();
  }

  /// [seance fork] Re-reads the hovered link when a modifier that decides
  /// it goes up or down, so the hand follows Cmd without the pointer moving.
  bool _onLinkModifierKey(KeyEvent event) {
    if (_hoverPosition != null &&
        widget.onLinkTap != null &&
        _linkModifierKeys.contains(event.logicalKey)) {
      _refreshLinkHover();
    }
    return false;
  }

  void _refreshLinkHover() {
    final position = _hoverPosition;
    if (position == null) return;
    final offset = renderTerminal.getCellOffset(
      renderTerminal.globalToLocal(position),
    );
    _setHoveredLink(_remoteOwnsTapAt(offset) && !_linkModifierOutranksRemote
        ? null
        : widget.terminal.buffer.getLinkAt(offset));
  }

  bool _remoteOwnsTapAt(CellOffset offset) =>
      !widget.readOnly &&
      _controller.shouldSendPointerInput(PointerInput.tap) &&
      widget.terminal.mouseMode != MouseMode.none &&
      offset.y >= widget.terminal.buffer.scrollBack;

  bool get _isApplePlatform =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// [seance fork] Cmd has no bit in the mouse protocol, so a remote that
  /// reports clicks (tmux with `mouse on`, a TUI) would read a Cmd-click as a
  /// plain one. On Apple platforms the link modifier outranks mouse reporting,
  /// as in other macOS terminals. Ctrl, the link modifier elsewhere, is a
  /// reportable modifier, so there the remote keeps the click.
  bool get _linkModifierOutranksRemote {
    final keys = HardwareKeyboard.instance;
    return _isApplePlatform &&
        keys.isMetaPressed &&
        !keys.isShiftPressed &&
        !keys.isAltPressed;
  }

  /// [seance fork] Decides, as a primary press goes down at [press], whether
  /// it opens a link instead of reaching a mouse-reporting remote. The
  /// gesture handler asks at the raw pointer layer — before any recognizer
  /// resolves, so the decision sees the modifiers the press started with —
  /// and a claimed press reaches the remote neither down nor up. The release
  /// then honours the same decision: Cmd pressed only after a reported press
  /// opens nothing, and a claimed press opens its link even when the
  /// modifiers change before its release. Without the capture a press the
  /// remote never saw would be re-decided at mouse-up and vanish whenever
  /// the modifiers drifted — and for a quick click the tap's own down only
  /// resolves at mouse-up, so even its claim would come too late.
  bool _claimPressForLink(PointerDownEvent press, int tapCount) {
    // Every press re-decides: one that does not claim clears the claim, so
    // no release can act on a stale one.
    _pressOpensLink = null;

    if (widget.onLinkTap == null || tapCount != 1) return false;

    final keys = HardwareKeyboard.instance;
    final linkGesture = press.kind == PointerDeviceKind.touch ||
        (_isApplePlatform ? keys.isMetaPressed : keys.isControlPressed);
    if (!linkGesture || keys.isShiftPressed || keys.isAltPressed) return false;

    final offset = renderTerminal.getCellOffset(press.localPosition);
    // Cmd outranks a mouse-reporting remote on Apple. Everywhere else a
    // link modifier is reportable and a remote that owns the tap keeps it,
    // but a press nobody owns (no mouse reporting, or the scrollback) has
    // to decide here — its release must open the link whatever the
    // modifiers do in between.
    if (!_linkModifierOutranksRemote && _remoteOwnsTapAt(offset)) return false;

    _pressOpensLink = widget.terminal.buffer.getLinkAt(offset);
    return _pressOpensLink != null;
  }

  void _invalidateLinkHover() {
    if (_hoveredLink == null || _hoverInvalidationPending) return;
    _hoverInvalidationPending = true;
    // Resize and scroll notifications can arrive during layout. Defer the
    // cursor rebuild rather than dirtying an ancestor mid-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hoverInvalidationPending = false;
      if (mounted) _setHoveredLink(null);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _setHoveredLink(Uri? link) {
    if (_hoveredLink == link) return;
    setState(() => _hoveredLink = link);
  }

  void _onTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    // [seance fork] The press decides: a claimed press opens its link even
    // when the link modifier is gone (or Shift/Alt is down) at mouse-up.
    // The remote never saw that press, so a release that opens nothing here
    // would lose the click entirely.
    final claimedLink = _pressOpensLink;
    _pressOpensLink = null;
    if (claimedLink != null) {
      // Intentionally no re-validation at release: the press decided, and a
      // link that scrolled away between the press and its release must not
      // eat the click.
      widget.onLinkTap?.call(claimedLink);
    } else {
      final keys = HardwareKeyboard.instance;
      final linkGesture = details.kind == PointerDeviceKind.touch ||
          (_isApplePlatform ? keys.isMetaPressed : keys.isControlPressed);

      // Click-only mouse reporting consumes DOWN but not UP. Keep that
      // release from opening a browser even when the gesture handler passes
      // it through.
      if (widget.onLinkTap != null &&
          _tapCount == 1 &&
          linkGesture &&
          !keys.isShiftPressed &&
          !keys.isAltPressed &&
          !_remoteOwnsTapAt(offset)) {
        final link = widget.terminal.buffer.getLinkAt(offset);
        if (link != null) widget.onLinkTap!(link);
      }
    }
    widget.onTapUp?.call(details, offset);

    // [seance fork] A touch double/triple tap selected a word/line on its
    // way down.
    if (details.kind == PointerDeviceKind.touch && _tapCount > 1) {
      _onTouchSelectionEnd();
    }
  }

  void _onTouchSelectionEnd() {
    if (_controller.selection == null) return;
    _focusNode.requestFocus();
    _showSelectionHandles();
    widget.onTouchSelectionEnd?.call();
  }

  void _showSelectionHandles() {
    final selection = _controller.selection?.normalized;
    if (selection == null || selection.begin == selection.end) return;
    final render = renderTerminal;
    _selectionOverlay ??= SelectionOverlay(
      context: context,
      startHandleType: TextSelectionHandleType.left,
      endHandleType: TextSelectionHandleType.right,
      lineHeightAtStart: render.lineHeight,
      lineHeightAtEnd: render.lineHeight,
      selectionEndpoints: const [],
      selectionControls: switch (Theme.of(context).platform) {
        TargetPlatform.iOS ||
        TargetPlatform.macOS =>
          cupertinoTextSelectionControls,
        _ => materialTextSelectionControls,
      },
      selectionDelegate: null,
      clipboardStatus: null,
      startHandleLayerLink: _selectionStartLink,
      endHandleLayerLink: _selectionEndLink,
      toolbarLayerLink: _selectionStartLink,
      dragStartBehavior: DragStartBehavior.down,
      onStartHandleDragStart: (_) => _startHandleDrag(_SelectionHandle.start),
      onEndHandleDragStart: (_) => _startHandleDrag(_SelectionHandle.end),
      onStartHandleDragUpdate: (details) =>
          _updateHandleDrag(_SelectionHandle.start, details),
      onEndHandleDragUpdate: (details) =>
          _updateHandleDrag(_SelectionHandle.end, details),
      onStartHandleDragEnd: (_) => _endHandleDrag(_SelectionHandle.start),
      onEndHandleDragEnd: (_) => _endHandleDrag(_SelectionHandle.end),
      onSelectionHandleTapped: () => widget.onTouchSelectionEnd?.call(),
    );
    _selectionOverlay!.showHandles();
  }

  void _updateSelectionHandles() {
    final overlay = _selectionOverlay;
    if (overlay == null) return;
    final selection = _controller.selection;
    final base = _controller.selectionBaseAnchor;
    if (selection == null ||
        selection.begin == selection.end ||
        base == null ||
        !widget.terminal.buffer.ownsAnchor(base)) {
      _hideSelectionHandles();
      return;
    }
    overlay
      ..lineHeightAtStart = renderTerminal.lineHeight
      ..lineHeightAtEnd = renderTerminal.lineHeight;
  }

  void _onSelectionFocusChange() {
    if (!_focusNode.hasFocus) _hideSelectionHandles();
  }

  void _hideSelectionHandles() {
    _selectionOverlay?.dispose();
    _selectionOverlay = null;
    _draggingHandle = null;
    _handleDragAnchor?.dispose();
    _handleDragAnchor = null;
    _handleDragPosition = null;
  }

  void _startHandleDrag(_SelectionHandle handle) {
    // Flutter permits concurrent handles and repeats pen starts. Keep one
    // drag's anchor and accumulated movement until that gesture ends.
    if (_draggingHandle != null) return;
    final selection = _controller.selection?.normalized;
    if (selection == null) return;
    _draggingHandle = handle;
    ContextMenuController.removeAny();
    _handleDragAnchor?.dispose();
    final start = handle == _SelectionHandle.start;
    _handleDragAnchor = widget.terminal.buffer.createAnchorFromOffset(
      start ? selection.end : selection.begin,
    );
    final render = renderTerminal;
    // Keep the finger's grab offset: handles sit below the selected row.
    _handleDragPosition = render.localToGlobal(
      render.getOffset(start ? selection.begin : selection.end) +
          Offset(0, render.lineHeight / 2),
    );
  }

  void _updateHandleDrag(_SelectionHandle handle, DragUpdateDetails details) {
    if (_draggingHandle != handle) return;
    final fixed = _handleDragAnchor;
    final position = _handleDragPosition;
    final buffer = widget.terminal.buffer;
    if (fixed == null || position == null || !buffer.ownsAnchor(fixed)) return;
    _handleDragPosition = position + details.delta;
    final moving = renderTerminal.createSelectionBoundaryAnchorAt(
      renderTerminal.globalToLocal(_handleDragPosition!),
    );
    final start = handle == _SelectionHandle.start;
    // Keep a nonempty range and the opposite endpoint pinned to its text.
    if (start
        ? !moving.offset.isBefore(fixed.offset)
        : !moving.offset.isAfter(fixed.offset)) {
      moving.dispose();
      return;
    }
    final anchor = buffer.createAnchorFromOffset(fixed.offset);
    _controller.setSelection(start ? moving : anchor, start ? anchor : moving);
  }

  void _endHandleDrag(_SelectionHandle handle) {
    if (_draggingHandle != handle) return;
    _draggingHandle = null;
    _handleDragAnchor?.dispose();
    _handleDragAnchor = null;
    _handleDragPosition = null;
    _onTouchSelectionEnd();
  }

  /// [seance fork] Where a selection toolbar points, in global coordinates:
  /// the top of the selection's first row (the toolbar sits above it when it
  /// fits) and the bottom of its last row (below it otherwise), centred
  /// between the selection's ends. Both are clamped to the view, so a
  /// selection reaching into the scrollback still gets a toolbar on screen.
  /// Null without a selection.
  TextSelectionToolbarAnchors? get selectionToolbarAnchors {
    final selection = _controller.selection?.normalized;
    if (selection == null) return null;

    final render = renderTerminal;
    final begin = render.getOffset(selection.begin);
    final end = render.getOffset(selection.end);
    final view = Offset.zero & render.size;
    final x = ((begin.dx + end.dx) / 2).clamp(view.left, view.right);
    Offset anchor(double y) =>
        render.localToGlobal(Offset(x, y.clamp(view.top, view.bottom)));

    return TextSelectionToolbarAnchors(
      primaryAnchor: anchor(begin.dy),
      secondaryAnchor: anchor(end.dy + render.lineHeight),
    );
  }

  void _onTapDown(TapDownDetails details, int tapCount) {
    if (details.kind == PointerDeviceKind.mouse) _hideSelectionHandles();
    _tapCount = tapCount;
    // [seance fork] Shift-click extends instead of clearing: from the live
    // selection's base if one exists, else from the last plain click.
    if (HardwareKeyboard.instance.isShiftPressed &&
        _tryExtendSelection(details)) {
      return;
    }

    // [seance fork] Only a plain single tap clears the selection. Upstream
    // cleared on *every* tap-down, which killed the word/line selection a
    // double/triple-click was about to make (the third tap of a triple always
    // read as a fresh first tap to its hand-rolled tracker).
    if (tapCount > 1) {
      return;
    }

    _lastTapAnchor?.dispose();
    _lastTapAnchor = renderTerminal.createAnchorAt(details.localPosition);

    if (_controller.selection != null) {
      _controller.clearSelection();
    } else {
      if (!widget.hardwareKeyboardOnly) {
        _customTextEditKey.currentState?.requestKeyboard();
      } else {
        _focusNode.requestFocus();
      }
    }
  }

  /// [seance fork] Shift-click selection extension. Returns false when there
  /// is nothing to extend from (no live selection and no recorded click).
  /// Every anchor is validated against the ACTIVE buffer — an anchor captured
  /// in the main buffer must not be resolved against the alt buffer (its row
  /// can exceed the alt buffer's height, and even in range it points at
  /// unrelated text).
  bool _tryExtendSelection(TapDownDetails details) {
    final buffer = widget.terminal.buffer;
    final base = _controller.selectionBaseAnchor;
    if (base != null &&
        buffer.ownsAnchor(base) &&
        _controller.extendSelectionTo(
          renderTerminal.createAnchorAt(details.localPosition),
        )) {
      return true;
    }
    final last = _lastTapAnchor;
    if (last != null && buffer.ownsAnchor(last)) {
      _controller.setSelection(
        buffer.createAnchorFromOffset(last.offset),
        renderTerminal.createAnchorAt(details.localPosition),
      );
      return true;
    }
    return false;
  }

  void _onSecondaryTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapDown?.call(details, offset);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapUp?.call(details, offset);
  }

  bool get hasInputConnection {
    return _customTextEditKey.currentState?.hasInputConnection == true;
  }

  void _onInsert(String text) {
    final key = charToTerminalKey(text.trim());

    // On mobile platforms there is no guarantee that virtual keyboard will
    // generate hardware key events. So we need first try to send the key
    // as a hardware key event. If it fails, then we send it as a text input.
    final consumed = key == null ? false : widget.terminal.keyInput(key);

    if (!consumed) {
      widget.terminal.textInput(text);
    }

    _scrollToBottom();
  }

  void _onComposing(String? text) {
    setState(() => _composingText = text);
  }

  KeyEventResult _handleKeyEvent(FocusNode focusNode, KeyEvent event) {
    final resultOverride = widget.onKeyEvent?.call(focusNode, event);
    if (resultOverride != null && resultOverride != KeyEventResult.ignored) {
      return resultOverride;
    }

    // ignore: invalid_use_of_protected_member
    final shortcutResult = _shortcutManager.handleKeypress(
      focusNode.context!,
      event,
    );

    if (shortcutResult != KeyEventResult.ignored) {
      return shortcutResult;
    }

    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);

    if (key == null) {
      return KeyEventResult.ignored;
    }

    final handled = widget.terminal.keyInput(
      key,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );

    if (handled) {
      _scrollToBottom();
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onKeyboardShow() {
    // [seance fork] Only re-pin when the user was already at the bottom.
    // Upstream jumped unconditionally, so tapping a scrolled-up terminal on
    // touch (which summons the keyboard) yanked the viewport to the bottom
    // mid-selection — the long-press then selected the wrong text.
    if (_focusNode.hasFocus && renderTerminal.stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  void _onEditableRect(Rect rect, Rect caretRect) {
    _customTextEditKey.currentState?.setEditableRect(rect, caretRect);
  }

  void _scrollToBottom() {
    final position = _scrollableKey.currentState?.position;
    if (position != null) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  /// [seance fork] Scrolls the scrollback by [pixels], clamped to the scroll
  /// extents. Drives the drag-selection edge autoscroll.
  void autoScrollBy(double pixels) {
    final position = _scrollableKey.currentState?.position;
    if (position == null) return;
    final target = (position.pixels + pixels)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) {
      position.jumpTo(target);
    }
  }
}

class _TerminalView extends LeafRenderObjectWidget {
  const _TerminalView({
    super.key,
    required this.terminal,
    required this.controller,
    required this.offset,
    required this.padding,
    required this.autoResize,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.focusNode,
    required this.cursorType,
    required this.alwaysShowCursor,
    this.onEditableRect,
    this.composingText,
    required this.selectionStartLink,
    required this.selectionEndLink,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool autoResize;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final bool alwaysShowCursor;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  final LayerLink selectionStartLink;
  final LayerLink selectionEndLink;

  @override
  RenderTerminal createRenderObject(BuildContext context) {
    return RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      autoResize: autoResize,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      focusNode: focusNode,
      cursorType: cursorType,
      alwaysShowCursor: alwaysShowCursor,
      onEditableRect: onEditableRect,
      composingText: composingText,
      selectionStartLink: selectionStartLink,
      selectionEndLink: selectionEndLink,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..autoResize = autoResize
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..alwaysShowCursor = alwaysShowCursor
      ..onEditableRect = onEditableRect
      ..composingText = composingText;
  }
}
