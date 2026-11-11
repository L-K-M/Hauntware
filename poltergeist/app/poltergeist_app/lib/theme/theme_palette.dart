// The palette model moved to `ghost_theme`, shared with the rest of the
// Ghost app family (design docs/design/ghost-theme.md). Poltergeist keeps
// its import path so call sites do not move.
library;

export 'package:ghost_theme/ghost_theme.dart'
    show
        ThemeSlot,
        ThemePalette,
        parseThemeColor,
        formatThemeColor;
