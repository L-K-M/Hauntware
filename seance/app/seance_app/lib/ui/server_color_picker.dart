import 'package:flutter/material.dart';
import 'package:ghost_marks/ghost_marks.dart' as marks;
import 'package:seance_core/seance_core.dart';

import 'color_picker.dart' show seanceHexStyle;

/// Picks a colour of the user's own for a server's accent: ghost_marks'
/// picker with the hex box in Séance's monospace stack.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [mark] is
/// what the server is currently marked with, so the preview shows the badge
/// the colour will actually be drawn under.
Future<Color?> showServerColorPicker(
  BuildContext context, {
  required Color initial,
  required ServerMark mark,
}) => marks.showServerColorPicker(
  context,
  initial: initial,
  mark: mark,
  hexStyle: seanceHexStyle,
);
