import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';

import 'pane_format.dart';

/// [category]'s glyph as an [Icon] in its hue for [context]'s theme.
///
/// The glyph and family hue (D32 §6 as D34 colours it) come from one table
/// for the desktop rows, the phone's kind badges, and every other surface
/// that names an item by its kind. The glyphs are the filled faces, since a
/// hairline outline at 16 px carries too little colour to be told apart at
/// a glance; the active selection repaints them on-accent, where the tint
/// would sink into the fill. The table itself lives in `package:ghost_ui`
/// (`ghostFileKindGlyph`).
Icon kindIcon(
  BuildContext context,
  PaneKindCategory category, {
  required double size,
}) => ghostFileKindIcon(context, category, size: size);
