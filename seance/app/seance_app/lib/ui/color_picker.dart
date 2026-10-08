import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' as ghost;

import '../theme.dart' show SeanceTheme;

export 'package:ghost_ui/ghost_ui.dart' show ColorSwatchBox;

/// The hex box's style in Séance's pickers: the monospace stack. A bare
/// 'monospace' resolves on Android only.
final TextStyle seanceHexStyle = TextStyle(
  fontFamily: SeanceTheme.monoFallback.first,
  fontFamilyFallback: SeanceTheme.monoFallback,
);

/// ghost_ui's colour picker in Séance's words and monospace stack: hue,
/// saturation and brightness sliders, and a hex box.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [preview]
/// draws the colour the way it will be used beside the hex box; [allowAlpha]
/// adds an opacity slider; [note] is a line under the sliders.
Future<Color?> showColorPicker(
  BuildContext context, {
  required Color initial,
  String title = 'Custom colour',
  bool allowAlpha = false,
  Widget Function(BuildContext context, Color color)? preview,
  String? note,
}) => ghost.showColorPicker(
  context,
  initial: initial,
  title: title,
  allowAlpha: allowAlpha,
  preview: preview,
  note: note,
  hexStyle: seanceHexStyle,
);
