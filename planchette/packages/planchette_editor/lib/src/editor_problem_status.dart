import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart' show TextProblemSeverity;

import 'editor_controller.dart';
import 'editor_strings.dart';

/// The status row's problem segment: the problem on the caret's line
/// described, else the document's problem count, behind the icon of the
/// most severe. Tapping it goes to the next problem. It shows nothing while
/// the document has none.
///
/// The default status row includes it; a host that builds its own row
/// through [PlanchetteEditor.statusBuilder] places it there.
class EditorProblemStatus extends StatelessWidget {
  const EditorProblemStatus({
    super.key,
    required this.controller,
    this.strings = const EditorStrings(),
    this.style,
  });

  final EditorController controller;
  final EditorStrings strings;

  /// The label's style; the theme's `labelSmall`, as status rows use, when
  /// null.
  final TextStyle? style;

  /// The widest the segment grows, so a long message leaves the rest of the
  /// row its room and ellipsizes instead; the tooltip has it in full.
  static const _maxWidth = 420.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _segment(context),
  );

  Widget _segment(BuildContext context) {
    final problems = controller.problems;
    if (problems.isEmpty) return const SizedBox.shrink();

    final atCaret = controller.problemAtCaret;
    final severity =
        atCaret?.severity ??
        (problems.any(
              (problem) => problem.severity == TextProblemSeverity.error,
            )
            ? TextProblemSeverity.error
            : TextProblemSeverity.warning);
    final label = atCaret == null
        ? strings.problemCount(problems.length)
        : strings.problemMessage(atCaret);
    final textStyle = style ?? Theme.of(context).textTheme.labelSmall;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: Tooltip(
        message: atCaret == null ? strings.nextProblemHint : label,
        child: InkWell(
          onTap: controller.canMoveCaret ? controller.nextProblem : null,
          borderRadius: BorderRadius.circular(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                severity == TextProblemSeverity.error
                    ? Icons.error_outline
                    : Icons.warning_amber_rounded,
                // The syntax theme the view installed: the colours the
                // underlines and gutter use, whatever theme the host has.
                color: controller.text.theme.problemColor(severity),
                size: (textStyle?.fontSize ?? 11) + 3,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The start of a status row: [position] at its own width, then the problem
/// segment in the room left. Two flexible children would each be capped at
/// half the row, clipping a message beside a short position; here the
/// position yields only when the row cannot hold it beside the problem icon.
class EditorStatusLead extends StatelessWidget {
  const EditorStatusLead({
    super.key,
    required this.controller,
    required this.position,
    this.strings = const EditorStrings(),
    this.style,
  });

  final EditorController controller;

  /// The caret position readout, which should ellipsize when constrained.
  final Widget position;
  final EditorStrings strings;
  final TextStyle? style;

  static const _gap = 12.0;

  /// The gap plus the problem icon and a little of its label.
  static const _problemMinimum = _gap + 32.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => LayoutBuilder(builder: _row),
  );

  Widget _row(BuildContext context, BoxConstraints constraints) {
    final problems = controller.problems.isNotEmpty;
    final room = constraints.maxWidth;
    return Row(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: problems ? math.max(0, room - _problemMinimum) : room,
          ),
          child: position,
        ),
        if (problems) ...[
          const SizedBox(width: _gap),
          Flexible(
            child: EditorProblemStatus(
              controller: controller,
              strings: strings,
              style: style,
            ),
          ),
        ],
      ],
    );
  }
}
