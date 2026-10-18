/// Shared theme stack for the Ghost app family — Planchette, Poltergeist,
/// and Seance: the editable [ThemePalette] and the JSON form it is stored
/// and pasted in, the shipped preset tables, the appearance value the apps'
/// MaterialApps rebuild for, and the builders and [GhostChrome] extension
/// each host binds through [GhostThemeStyle].
///
/// Host-neutral like ghost_ui: everything per-app arrives through
/// [GhostThemeStyle] — the brand preset's name and seed, which preset a
/// device starts in, whether its palettes carry a terminal block, and every
/// component-level divergence between the apps — bound into
/// [GhostThemePresets], [GhostThemeCodec] and [GhostTheme], and the
/// Appearance editor, [GhostAppearanceSection], which a host lays out in
/// its own settings page and words through [GhostAppearanceStrings]
/// (design docs/design/ghost-theme.md).
library;

export 'package:ghost_ui/ghost_ui.dart'
    show ThemeModePreference, surfaceBrightness, automaticBrightness;

export 'src/app_appearance.dart';
export 'src/appearance_section.dart';
export 'src/ghost_theme.dart';
export 'src/ghost_theme_codec.dart';
export 'src/ghost_theme_neutrals.dart';
export 'src/ghost_theme_presets.dart';
export 'src/ghost_theme_style.dart';
export 'src/theme_palette.dart';
