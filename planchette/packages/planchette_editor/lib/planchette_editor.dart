/// Embeddable editor UI shared by Planchette, Poltergeist, and Seance.
library;

export 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;
export 'src/code_editing_controller.dart';
export 'src/editor_controller.dart';
export 'src/editor_fonts.dart';
export 'src/editor_strings.dart';
export 'src/editor_view.dart';
export 'src/ghost_menus.dart';
export 'src/search_history.dart';
export 'src/text_tool_history.dart';
export 'src/text_tools_browser.dart';
