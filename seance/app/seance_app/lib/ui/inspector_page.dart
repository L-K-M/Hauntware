/// The pages of the window's right-hand inspector (`SidebarPanel`), in the
/// order its tabs show them.
///
/// Device-local, with the panes' widths: which panels a window shows is a
/// property of the screen in front of you, not of the account.
enum InspectorPage { files, context, git, snippets, assistant }

extension InspectorPageLabel on InspectorPage {
  /// The page's name in menus and the palette, matching its inspector tab.
  String get label => switch (this) {
    InspectorPage.files => 'Files',
    InspectorPage.context => 'Context',
    InspectorPage.git => 'Git',
    InspectorPage.snippets => 'Snippets',
    InspectorPage.assistant => 'Assistant',
  };
}
