// The palette-independent half of the sibling apps' app_appearance.dart
// (Séance's, ported to Poltergeist @ 8714859). The AppAppearance model and
// resolveBrightness stayed with the hosts: they type against each app's
// own ThemePalette/ThemePresets, and their adapters call these helpers.
import 'package:flutter/material.dart';

/// Which brightness a host palette's Automatic colours follow.
///
/// A device setting beside the palette rather than a field of it, so
/// picking another preset keeps it, as does pasting a theme someone else
/// made on a machine set up the other way round.
enum ThemeModePreference {
  /// The system's light or dark appearance, and its changes while the app
  /// runs.
  system,
  light,
  dark,
}

/// Whether a colour a host palette sets as its surface is light or dark.
///
/// The framework's own estimate: dark below a relative luminance of about
/// 0.34, a cut-off Material biases toward light text rather than WCAG's
/// equal-contrast point (about 0.18). A mid grey at 0.4 is therefore light,
/// and the neutrals this chooses bring the text colour with them.
Brightness surfaceBrightness(Color surface) =>
    ThemeData.estimateBrightnessForColor(surface);

/// The brightness a palette's Automatic colours follow under [mode]:
/// [platform] for [ThemeModePreference.system].
Brightness automaticBrightness(Brightness platform, ThemeModePreference mode) =>
    switch (mode) {
      ThemeModePreference.system => platform,
      ThemeModePreference.light => Brightness.light,
      ThemeModePreference.dark => Brightness.dark,
    };
