/// Compatibility shim: the palette model moved to `ghost_theme`, shared
/// with the rest of the Ghost app family (design docs/design/ghost-theme.md
/// §5 PR 1). Séance keeps its import path so call sites do not move.
library;

export 'package:ghost_theme/ghost_theme.dart'
    show
        ThemeSlot,
        ThemeTerminalColors,
        ThemePalette,
        parseThemeColor,
        formatThemeColor;
