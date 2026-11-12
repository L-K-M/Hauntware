import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Which side of a resizable pane its [GhostResizeHandle] sits on: a
/// leading pane grows as the handle moves toward the trailing edge, a
/// trailing pane as it moves toward the leading edge.
enum GhostPaneEdge { leading, trailing }

const double _resizeKeyStep = 16;

/// A labelled, keyboard-adjustable divider with the same clamping and
/// persistence boundary as a pointer drag. Physical arrow direction follows
/// the divider; assistive increase/decrease follows the owned pane's width.
/// A double tap calls [onReset] for the owner's default width.
class GhostResizeHandle extends StatefulWidget {
  final String label;
  final double width;
  final double minimumWidth;
  final double maximumWidth;
  final GhostPaneEdge edge;
  final double Function(double delta) widthAfterStep;
  final ValueChanged<double> onStep;
  final VoidCallback onStart;
  final ValueChanged<double> onDelta;
  final VoidCallback onEnd;

  /// The handle's hit width, centred on the seam it floats over.
  final double handleWidth;

  /// [width] as assistive technology reads it, such as `320 pixels`.
  final String Function(double width) valueText;

  /// A double tap: the owner's default width, when it has one.
  final VoidCallback? onReset;

  /// When the drag begins. Only observable while another gesture competes
  /// for the pointer: [DragStartBehavior.down] reports the whole drag from
  /// the pointer-down position, the default [DragStartBehavior.start] the
  /// drag from where this recognizer wins the arena, dropping the move
  /// made before it did.
  final DragStartBehavior dragStartBehavior;

  const GhostResizeHandle({
    super.key,
    required this.label,
    required this.width,
    required this.minimumWidth,
    required this.maximumWidth,
    required this.edge,
    required this.widthAfterStep,
    required this.onStep,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
    required this.handleWidth,
    required this.valueText,
    this.onReset,
    this.dragStartBehavior = DragStartBehavior.start,
  });

  @override
  State<GhostResizeHandle> createState() => _GhostResizeHandleState();
}

class _GhostResizeHandleState extends State<GhostResizeHandle> {
  final _focusNode = FocusNode();
  bool _focused = false;
  bool _dragging = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _startDrag() {
    _dragging = true;
    widget.onStart();
  }

  void _finishDrag() {
    // The drag recognizer also cancels when a tap wins the arena.
    if (!_dragging) return;
    _dragging = false;
    widget.onEnd();
  }

  double get _direction =>
      Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  double get _grow => widget.edge == GhostPaneEdge.leading ? 1 : -1;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onStep(_resizeKeyStep * _direction);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onStep(-_resizeKeyStep * _direction);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: widget.label,
      slider: true,
      value: widget.valueText(widget.width),
      increasedValue: widget.valueText(widget.widthAfterStep(_resizeKeyStep)),
      decreasedValue: widget.valueText(widget.widthAfterStep(-_resizeKeyStep)),
      onIncrease: widget.width < widget.maximumWidth
          ? () => widget.onStep(_resizeKeyStep * _grow)
          : null,
      onDecrease: widget.width > widget.minimumWidth
          ? () => widget.onStep(-_resizeKeyStep * _grow)
          : null,
      child: Focus(
        focusNode: _focusNode,
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: widget.dragStartBehavior,
            onTap: _focusNode.requestFocus,
            onHorizontalDragStart: (_) => _startDrag(),
            onHorizontalDragUpdate: (d) =>
                widget.onDelta(d.delta.dx * _direction),
            onHorizontalDragEnd: (_) => _finishDrag(),
            onHorizontalDragCancel: _finishDrag,
            onDoubleTap: widget.onReset,
            // The line itself is the layout's seam underneath; the handle
            // draws only its focus ring over it.
            child: SizedBox(
              width: widget.handleWidth,
              child: _focused
                  ? Center(
                      child: Container(
                        width: 3,
                        color: theme.colorScheme.primary,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
