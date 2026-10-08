// ghost_ui's colour picker (shared with Séance since 2026-10-08), in this
// app's ARB strings (D20) and monospace stack.
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' as ghost;

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;

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
  strings: _LocalizedColorPickerStrings(AppLocalizations.of(context)),
);

/// The picker's words from the ARB catalog.
final class _LocalizedColorPickerStrings extends ghost.ColorPickerStrings {
  const _LocalizedColorPickerStrings(this._l10n);

  final AppLocalizations _l10n;

  @override
  String get hexLabel => _l10n.colorPickerHexLabel;

  @override
  String get hexError => _l10n.colorPickerHexError;

  @override
  String get hexErrorAlpha => _l10n.colorPickerHexErrorAlpha;

  @override
  String get hue => _l10n.colorPickerHue;

  @override
  String get saturation => _l10n.colorPickerSaturation;

  @override
  String get brightness => _l10n.colorPickerBrightness;

  @override
  String get opacity => _l10n.colorPickerOpacity;

  @override
  String degrees(int degrees) => _l10n.colorPickerDegrees(degrees);

  @override
  String percent(int percent) => _l10n.colorPickerPercent(percent);

  @override
  String get cancel => _l10n.colorPickerCancel;

  @override
  String get use => _l10n.colorPickerUse;
}
