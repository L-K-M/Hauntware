import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ThemeModePreference, surfaceBrightness, automaticBrightness;

import 'theme_palette.dart';

/// What the app is drawn in: this device's palette and mode, as one value
/// the app's MaterialApp — and the settings window's — rebuilds for, and
/// only for.
///
/// The value itself carries no per-app default: a host that has never
/// opened Appearance binds its own initial palette from its own
/// [GhostThemePresets] (see the design's PR 1 note).
@immutable
class AppAppearance {
  const AppAppearance({
    required this.palette,
    this.mode = ThemeModePreference.system,
  });

  final ThemePalette palette;
  final ThemeModePreference mode;

  @override
  bool operator ==(Object other) =>
      other is AppAppearance && other.palette == palette && other.mode == mode;

  @override
  int get hashCode => Object.hash(palette, mode);
}

/// The brightness [palette] is drawn at: its own surface's when it sets
/// one — a Solarized pane is dark whatever the system says — otherwise
/// what [mode] asks for, where [ThemeModePreference.system] is [platform].
Brightness resolveBrightness(
  ThemePalette palette,
  Brightness platform,
  ThemeModePreference mode,
) {
  if (palette.surface case final surface?) return surfaceBrightness(surface);
  return automaticBrightness(platform, mode);
}
