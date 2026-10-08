/// Shared UI primitives for the Ghost app family — Planchette,
/// Poltergeist, and Seance.
///
/// Everything here is host-agnostic: strings arrive through injected
/// string bags, colours through [SidebarThemeTokens] or the ambient
/// theme, and behavior through callbacks, so each app keeps its own
/// domain, localization, and theme system.
library;

export 'src/appearance.dart';
export 'src/badge_image.dart';
export 'src/color_picker.dart';
export 'src/contrast.dart';
export 'src/family_hues.dart';
export 'src/ghost_chords.dart';
export 'src/ghost_command_menu.dart';
export 'src/ghost_file_columns.dart';
export 'src/ghost_file_compact_row.dart';
export 'src/ghost_file_format.dart';
export 'src/ghost_file_item.dart';
export 'src/ghost_file_kinds.dart';
export 'src/ghost_file_row.dart';
export 'src/ghost_file_theme.dart';
export 'src/ghost_menus.dart';
export 'src/middle_ellipsis_text.dart';
export 'src/selected_tab_view.dart';
export 'src/sidebar_kit.dart';
export 'src/sidebar_theme_tokens.dart';
export 'src/top_toast.dart';
