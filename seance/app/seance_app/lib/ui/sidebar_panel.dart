import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../family_hues.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'settings_screen.dart';
import 'chat_sidebar.dart';
import 'context_pane.dart';
import 'files_pane.dart';
import 'git_pane.dart';
import 'inspector_page.dart';
import 'selected_tab_view.dart';
import 'snippets_pane.dart';
import 'terminal_pane.dart';

/// The right-hand utility panel: Files, Context, Git, Snippets and the
/// Assistant (the LLM chat, when a provider is configured). Used both as a
/// tiled pane on wide layouts and inside the end-drawer on narrow ones.
class SidebarPanel extends StatefulWidget {
  final bool includeFiles;

  const SidebarPanel({super.key, this.includeFiles = true});

  /// The row of tabs at the panel's top.
  static const tabStripKey = ValueKey('sidebar-panel-tabs');

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel>
    with SingleTickerProviderStateMixin {
  TabController? _tabs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tabs != null) return;
    final state = AppScope.of(context);
    // The wide layout's panel opens on the page the window last showed
    // (Files at first) and follows the page shortcuts. The narrow drawer
    // has no Files and opens on what its button names: the Assistant once
    // one is set up, else Snippets.
    final opening = widget.includeFiles
        ? state.inspectorPage
        : state.llmConfigured
        ? InspectorPage.assistant
        : InspectorPage.snippets;
    final tabs = _panelTabs;
    // includeFiles is fixed at every call site (const constructions), so the
    // controller's length never needs to track a rebuild-time change.
    _tabs = TabController(
      length: tabs.length,
      initialIndex: tabs.indexWhere((tab) => tab.page == opening),
      vsync: this,
    )..addListener(_pageChosen);
    _state = state..addListener(_followState);
  }

  AppState? _state;

  /// Brings Files forward: its tab here, or its own screen from the narrow
  /// drawer, which has no Files tab.
  void _showFiles() {
    if (!mounted) return;
    final files = _panelTabs.indexWhere(
      (tab) => tab.page == InspectorPage.files,
    );
    if (files >= 0) {
      _tabs!.index = files;
      return;
    }
    final navigator = Navigator.of(context);
    Scaffold.maybeOf(context)?.closeEndDrawer();
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const FilesScreen()),
      ),
    );
  }

  @override
  void dispose() {
    _state?.removeListener(_followState);
    _tabs?.dispose();
    super.dispose();
  }

  /// A tab the user opened becomes the window's inspector page, which the
  /// next launch reopens.
  void _pageChosen() {
    final tabs = _tabs;
    if (tabs == null || tabs.indexIsChanging || !widget.includeFiles) return;
    final page = _panelTabs[tabs.index].page;
    final state = _state;
    if (state != null && state.inspectorPage != page) {
      unawaited(state.setInspectorPage(page));
    }
  }

  /// The page a shortcut picked, shown when it differs from the open tab.
  void _followState() {
    final tabs = _tabs;
    final state = _state;
    if (tabs == null || state == null || !widget.includeFiles) return;
    final page = state.inspectorPage;
    final index = _panelTabs.indexWhere((tab) => tab.page == page);
    if (index >= 0 && index != tabs.index) tabs.index = index;
  }

  /// The tabs in order, each with its family hue (Poltergeist's D34, the
  /// sibling apps' colour vocabulary): Files the places blue, Context the
  /// links cyan, Git the code orange, the Snippets the saved-recipe teal,
  /// the Assistant the AI purple.
  List<_PanelTab> get _panelTabs => [
    if (widget.includeFiles)
      const _PanelTab(
        InspectorPage.files,
        'Files',
        Icons.folder_outlined,
        Icons.folder,
        FamilyHue.blue,
      ),
    const _PanelTab(
      InspectorPage.context,
      'Context',
      Icons.dataset_linked_outlined,
      Icons.dataset_linked,
      FamilyHue.cyan,
    ),
    const _PanelTab(
      InspectorPage.git,
      'Git',
      Icons.account_tree_outlined,
      Icons.account_tree,
      FamilyHue.orange,
    ),
    const _PanelTab(
      InspectorPage.snippets,
      'Snippets',
      Icons.bookmarks_outlined,
      Icons.bookmarks,
      FamilyHue.teal,
    ),
    const _PanelTab(
      InspectorPage.assistant,
      'Assistant',
      Icons.auto_awesome_outlined,
      Icons.auto_awesome,
      FamilyHue.purple,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tabs = _panelTabs;
    final controller = _tabs!;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return SafeArea(
          child: Column(
            children: [
              _PanelTabStrip(controller: controller, tabs: tabs),
              Expanded(
                // A tab's page is built when it is first opened, so Files and
                // Git initialize their session's controller only then.
                child: SelectedTabView(
                  controller: _tabs,
                  children: [
                    for (final tab in tabs)
                      switch (tab.page) {
                        InspectorPage.files => const FilesPane(),
                        InspectorPage.context => ContextPane(
                          showFiles: _showFiles,
                        ),
                        InspectorPage.git => const GitPane(),
                        InspectorPage.snippets => const SnippetsPane(),
                        InspectorPage.assistant =>
                          state.llmConfigured
                              ? const ChatSidebar()
                              : const _AssistantSetupPrompt(),
                      },
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The open tab's wash: its own hue at this opacity over the panel,
/// light enough that the glyph keeps 3:1 on it (family_hues_test.dart).
/// Poltergeist's inspector tabs use the same value.
const panelTabWashAlpha = 0.16;

class _PanelTab {
  const _PanelTab(this.page, this.label, this.glyph, this.openGlyph, this.hue);

  final InspectorPage page;
  final String label;

  /// The glyph at rest, and the filled one the open tab shows.
  final IconData glyph;
  final IconData openGlyph;
  final FamilyHue hue;
}

/// The panel's tabs as Poltergeist's inspector header sets its own: a
/// centred row of glyphs in their hues, each named by its tooltip, the
/// open one filled on a wash of its colour. As tall as the terminal's tab
/// strip, with the rule inside it the same way, so the two rules meet in
/// one line across the seam.
class _PanelTabStrip extends StatelessWidget {
  const _PanelTabStrip({required this.controller, required this.tabs});

  static const double _tabWidth = 40;
  static const double _tabHeight = 28;
  static const double _gap = 6;
  static const double _glyphSize = 18;
  static const double _cornerRadius = 6;

  final TabController controller;
  final List<_PanelTab> tabs;

  @override
  Widget build(BuildContext context) {
    final palette = FamilyPalette.of(context);
    final separator = SeanceChrome.of(context, seanceThemeStyle).separator;
    final corner = BorderRadius.circular(_cornerRadius);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SizedBox(
        key: SidebarPanel.tabStripKey,
        height: TerminalTabStrip.height,
        // A DecoratedBox, not a Container's border, so the rule does not
        // inset the row: the tabs centre on whole pixels.
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: separator)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (index, tab) in tabs.indexed) ...[
                if (index > 0) const SizedBox(width: _gap),
                _tab(tab, index, palette.glyph(tab.hue), corner),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(_PanelTab tab, int index, Color tint, BorderRadius corner) {
    final isOpen = controller.index == index;
    void open() => controller.index = index;
    // The label speaks once, through the Semantics below: the tooltip is
    // for the pointer.
    return Tooltip(
      message: tab.label,
      excludeFromSemantics: true,
      child: Semantics(
        selected: isOpen,
        button: true,
        label: tab.label,
        excludeSemantics: true,
        // The excluded InkWell's tap, kept for screen readers.
        onTap: open,
        child: InkWell(
          borderRadius: corner,
          onTap: open,
          child: Container(
            width: _tabWidth,
            height: _tabHeight,
            alignment: Alignment.center,
            decoration: isOpen
                ? BoxDecoration(
                    color: tint.withValues(alpha: panelTabWashAlpha),
                    borderRadius: corner,
                  )
                : null,
            child: Icon(
              isOpen ? tab.openGlyph : tab.glyph,
              size: _glyphSize,
              color: tint,
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantSetupPrompt extends StatelessWidget {
  const _AssistantSetupPrompt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 36,
              color: FamilyPalette.of(context).glyph(FamilyHue.purple),
            ),
            const SizedBox(height: 12),
            Text(
              'Assistant not set up',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Add an LLM provider (Anthropic, or a local OpenAI-compatible '
              'endpoint) to chat about your session and turn plain language '
              'into commands.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => openSettings(SettingsTab.assistant),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
