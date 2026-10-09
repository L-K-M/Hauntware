/// Shared server appearance for Séance and Poltergeist: the accent a
/// server's colour derives, its badge and accent bar, the glyph and colour
/// tables behind them, and the mark and colour pickers, so identical server
/// records draw identical marks in both apps.
///
/// Host-neutral like ghost_ui: colours come from the ambient theme, words
/// through [ServerAppearanceStrings], and the glyph and colour names are
/// vocabulary (data), not product copy.
library;

export 'src/server_appearance.dart';
export 'src/server_appearance_strings.dart';
export 'src/server_color_picker.dart';
export 'src/server_mark_picker.dart';
