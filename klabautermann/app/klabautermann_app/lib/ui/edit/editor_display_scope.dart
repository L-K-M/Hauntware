import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart'
    show ghostMonoFontFamilies, resolveMonoFamily;

import '../../controllers/editor_display.dart';

export '../../controllers/editor_display.dart' show EditorDisplay;

/// The device's editor display (03 §8.5) for the file editors under it;
/// the composition root puts it above every route, and a test may leave it
/// out, which draws the editors at their defaults.
class EditorDisplayScope extends InheritedNotifier<EditorDisplaySettings> {
  const EditorDisplayScope({
    super.key,
    required EditorDisplaySettings display,
    required super.child,
  }) : super(notifier: display);

  /// The display for [context], which rebuilds when it changes, or null
  /// when none is provided.
  static EditorDisplay? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<EditorDisplayScope>()
      ?.notifier
      ?.value;
}

/// The shared editor text style for [display]: the chosen family resolved to
/// a bundled one when it names one, the shared monospace stack as its
/// fallback, and the display's size and line height.
TextStyle editorDisplayTextStyle(EditorDisplay display) => TextStyle(
  fontFamily: switch (display.chosenFamily) {
    final family? => resolveMonoFamily(family),
    null => ghostMonoFontFamilies.first,
  },
  fontFamilyFallback: ghostMonoFontFamilies,
  fontSize: display.textSize.toDouble(),
  height: 1.35,
);
