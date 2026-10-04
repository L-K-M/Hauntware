import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ThemeModePreference, surfaceBrightness, automaticBrightness;

import 'theme_palette.dart';
import 'theme_presets.dart';

export 'package:ghost_ui/ghost_ui.dart'
    show ThemeModePreference, surfaceBrightness, automaticBrightness;

/// What the app is drawn in: this device's palette and mode, as one value
/// the app's MaterialApp — and the settings window's — rebuilds for, and
/// only for.
@immutable
class AppAppearance {
  const AppAppearance({
    required this.palette,
    this.mode = ThemeModePreference.system,
  });

  /// A device that has never opened Appearance.
  static final AppAppearance initial = AppAppearance(
    palette: ThemePresets.initial,
  );

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
