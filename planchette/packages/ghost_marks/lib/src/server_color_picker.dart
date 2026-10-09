import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ColorPickerStrings, showColorPicker;
import 'package:seance_protocol/seance_protocol.dart';

import 'server_appearance.dart';
import 'server_appearance_strings.dart';

/// Picks a colour of the user's own for a server's accent.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [mark] is
/// what the server is currently marked with, so the preview shows the badge
/// the colour will actually be drawn under rather than an empty swatch.
/// [strings] give the title and hint, [colorStrings] the picker's own words,
/// and [hexStyle] the host's monospace stack for the hex box.
Future<Color?> showServerColorPicker(
  BuildContext context, {
  required Color initial,
  required ServerMark mark,
  ServerAppearanceStrings strings = const ServerAppearanceStrings(),
  ColorPickerStrings colorStrings = const ColorPickerStrings(),
  TextStyle? hexStyle,
}) {
  return showColorPicker(
    context,
    initial: initial,
    title: strings.serverColorTitle,
    hexStyle: hexStyle,
    strings: colorStrings,
    preview: (context, color) {
      // One tint for both halves of the preview: the bar and the badge show
      // the same colour two ways, and building it twice is how they drift
      // apart.
      final tint = ServerTint(custom: color);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Previewed as the list will draw it, in this theme: the line and
          // the fill are derived from the picked colour rather than painted
          // raw, and this is where that shows.
          ServerAccentBar(tint: tint, height: 48),
          const SizedBox(width: 12),
          ServerBadge(tint: tint, mark: mark, size: 48),
        ],
      );
    },
    note: strings.serverColorHint,
  );
}
