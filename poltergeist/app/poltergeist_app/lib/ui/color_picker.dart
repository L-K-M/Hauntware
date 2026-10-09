// ghost_ui's colour picker (shared with Séance since 2026-10-08), in this
// app's ARB strings (D20) and monospace stack.
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' as ghost;

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'server_appearance_strings.dart';

export 'package:ghost_ui/ghost_ui.dart' show ColorSwatchBox;

/// Picks a colour: hue, saturation and brightness sliders, and a hex box.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [preview]
/// draws the colour the way it will be used beside the hex box; [allowAlpha]
/// adds an opacity slider; [note] is a line under the sliders. [title] is
/// required because copy comes from ARB.
Future<Color?> showColorPicker(
  BuildContext context, {
  required Color initial,
  required String title,
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
  hexStyle: poltergeistMonoTextStyle,
  strings: PoltergeistColorPickerStrings(AppLocalizations.of(context)),
);
