// ghost_marks' server colour picker (shared with Séance since 2026-10-08),
// in this app's ARB strings (D20) and monospace stack.
import 'package:flutter/material.dart';
import 'package:ghost_marks/ghost_marks.dart' as marks;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'server_appearance_strings.dart';

/// Picks a colour of the user's own for a server's accent. Returns the
/// chosen colour, or null if the dialog was dismissed; [mark] is previewed
/// on it.
Future<Color?> showServerColorPicker(
  BuildContext context, {
  required Color initial,
  required ServerMark mark,
}) {
  final l10n = AppLocalizations.of(context);
  return marks.showServerColorPicker(
    context,
    initial: initial,
    mark: mark,
    strings: PoltergeistServerAppearanceStrings(l10n),
    colorStrings: PoltergeistColorPickerStrings(l10n),
    hexStyle: poltergeistMonoTextStyle,
  );
}
