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
  });

  @override
  State<GhostResizeHandle> createState() => _GhostResizeHandleState();
}

class _GhostResizeHandleState extends State<GhostResizeHandle> {
  bool _focused = false;

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
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => widget.onStart(),
            onHorizontalDragUpdate: (d) =>
                widget.onDelta(d.delta.dx * _direction),
            onHorizontalDragEnd: (_) => widget.onEnd(),
            onHorizontalDragCancel: widget.onEnd,
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
