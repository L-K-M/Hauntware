// The appearance value moved to `ghost_theme`, shared with the rest of the
// Ghost app family (design docs/design/ghost-theme.md). Poltergeist keeps
// its import path so call sites do not move.
library;

export 'package:ghost_theme/ghost_theme.dart'
    show AppAppearance, resolveBrightness, ThemeModePreference, surfaceBrightness, automaticBrightness;

import 'package:ghost_theme/ghost_theme.dart' show AppAppearance;

import 'theme_presets.dart' show ThemePresets;

/// A device that has never opened Appearance.
AppAppearance get poltergeistInitialAppearance =>
    AppAppearance(palette: ThemePresets.initial);
