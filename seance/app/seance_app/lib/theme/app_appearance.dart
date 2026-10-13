import 'package:ghost_theme/ghost_theme.dart';

import 'theme_presets.dart';

/// Compatibility shim: [AppAppearance] and [resolveBrightness] moved to
/// `ghost_theme` (design docs/design/ghost-theme.md §5 PR 1). Séance keeps
/// its import path so call sites do not move.
///
/// The brightness helpers ride along because this file used to re-export
/// them from `ghost_ui`.
export 'package:ghost_theme/ghost_theme.dart'
    show
        AppAppearance,
        resolveBrightness,
        ThemeModePreference,
        surfaceBrightness,
        automaticBrightness;

/// A device that has never opened Appearance.
///
/// The model no longer carries this default — it depends on the app's
/// initial preset — so Séance binds it here.
final AppAppearance seanceInitialAppearance = AppAppearance(
  palette: ThemePresets.initial,
);
