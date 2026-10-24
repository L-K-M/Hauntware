import 'package:flutter/material.dart';
import 'package:seance_terminal/seance_terminal.dart';

import '../services/app_settings.dart';

// The appearance mapping moved to seance_terminal
// (docs/design/seance-terminal.md); this path keeps Séance's imports
// working and keeps the one part that reads Séance's settings.
export 'package:seance_terminal/seance_terminal.dart'
    show
        SeanceTerminalThemes,
        TerminalAppearance,
        TerminalLigatures,
        TerminalPalette,
        clampTerminalFontSize,
        kDefaultTerminalFont,
        kDefaultTerminalFontSize,
        kMaxTerminalFontSize,
        kMinTerminalFontSize,
        kTerminalFontSizeStep;

/// The terminal look [settings] ask for, against the ambient [brightness].
///
/// An empty [AppSettings.terminalFontFamily] means [kDefaultTerminalFont],
/// drawn with ligatures by [AppSettings.terminalLigatures]. Following the
/// app, the colours are the theme's own terminal colours when its palette
/// ([AppSettings.themePalette]) has them; the two pinned choices keep the
/// built-in palettes whatever the theme says.
TerminalAppearance resolveTerminalAppearance(
  AppSettings settings,
  Brightness brightness,
) => TerminalAppearance.of(
  fontSize: settings.terminalFontSize,
  fontFamily: settings.terminalFontFamily,
  ligatures: settings.terminalLigatures,
  palette: settings.terminalPalette,
  themeColors: settings.themePalette.terminal,
  brightness: brightness,
);
