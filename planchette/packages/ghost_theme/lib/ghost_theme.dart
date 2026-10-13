/// Shared theme model for the Ghost app family — Planchette, Poltergeist,
/// and Seance: the editable [ThemePalette] and the JSON form it is stored
/// and pasted in, the shipped preset tables, and the appearance value the
/// apps' MaterialApps rebuild for.
///
/// Host-neutral like ghost_ui: everything per-app arrives through
/// [GhostThemeStyle] — the brand preset's name and seed, which preset a
/// device starts in, and whether its palettes carry a terminal block —
/// bound into [GhostThemePresets] and [GhostThemeCodec]. This package is
/// the model half of the ghost_theme extraction (design
/// docs/design/ghost-theme.md); the builders, chrome extension and the
/// Appearance editor join it in later PRs.
library;

export 'package:ghost_ui/ghost_ui.dart'
    show ThemeModePreference, surfaceBrightness, automaticBrightness;

export 'src/app_appearance.dart';
export 'src/ghost_theme_codec.dart';
export 'src/ghost_theme_presets.dart';
export 'src/ghost_theme_style.dart';
export 'src/theme_palette.dart';
