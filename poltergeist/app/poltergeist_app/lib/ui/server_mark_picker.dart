// ghost_marks' server mark picker (shared with Séance since 2026-10-08), in
// this app's ARB strings (D20).
import 'package:flutter/material.dart';
import 'package:ghost_marks/ghost_marks.dart' as marks;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import 'server_appearance_strings.dart';

/// Picks what a server is marked with: a built-in glyph, an emoji, or an
/// imported image. Returns the new mark, or null if the picker was
/// dismissed; [accent] is the server's colour, every candidate's fill.
Future<ServerMark?> showServerMarkPicker(
  BuildContext context, {
  required ServerMark current,
  required marks.ServerTint accent,
}) => marks.showServerMarkPicker(
  context,
  current: current,
  accent: accent,
  strings: PoltergeistServerAppearanceStrings(AppLocalizations.of(context)),
);
