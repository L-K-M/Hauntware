import 'package:flutter/material.dart';

import '../family_hues.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'settings_screen.dart';
import 'chat_sidebar.dart';
import 'files_pane.dart';
import 'git_pane.dart';
import 'selected_tab_view.dart';
import 'snippets_pane.dart';

/// The right-hand utility panel: an Assistant tab (the LLM chat, when a provider
/// is configured) and a Snippets tab (always available). Used both as a tiled
/// pane on wide layouts and inside the end-drawer on narrow ones.
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
    // includeFiles is fixed at every call site (const constructions), so the
    // controller's length never needs to track a rebuild-time change.
    _tabs = TabController(
      length: widget.includeFiles ? 4 : 3,
      initialIndex: state.llmConfigured ? 0 : 1,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  /// The tabs in order, each with its family hue (Poltergeist's D34, the
  /// sibling apps' colour vocabulary): the Assistant the AI purple, the
  /// Snippets the saved-recipe teal, Files the places blue, Git the code
  /// orange.
  List<_PanelTab> get _panelTabs => [
    const _PanelTab(
      'Assistant',
      Icons.auto_awesome_outlined,
      Icons.auto_awesome,
      FamilyHue.purple,
    ),
    const _PanelTab(
      'Snippets',
      Icons.bookmarks_outlined,
      Icons.bookmarks,
      FamilyHue.teal,
    ),
    if (widget.includeFiles)
      const _PanelTab(
        'Files',
        Icons.folder_outlined,
        Icons.folder,
        FamilyHue.blue,
      ),
    const _PanelTab(
      'Git',
      Icons.account_tree_outlined,
      Icons.account_tree,
      FamilyHue.orange,
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
              Divider(height: 1, color: SeanceChrome.of(context).separator),
              Expanded(
                // A tab's page is built when it is first opened, so Files and
                // Git initialize their session's controller only then.
                child: SelectedTabView(
                  controller: _tabs,
                  children: [
                    state.llmConfigured
                        ? const ChatSidebar()
                        : const _AssistantSetupPrompt(),
                    const SnippetsPane(),
                    if (widget.includeFiles) const FilesPane(),
                    const GitPane(),
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
  const _PanelTab(this.label, this.glyph, this.openGlyph, this.hue);

  final String label;

  /// The glyph at rest, and the filled one the open tab shows.
  final IconData glyph;
  final IconData openGlyph;
  final FamilyHue hue;
}

/// The panel's tabs as Poltergeist's inspector header sets its own: a
/// centred row of glyphs in their hues, each named by its tooltip, the
/// open one filled on a wash of its colour.
class _PanelTabStrip extends StatelessWidget {
  const _PanelTabStrip({required this.controller, required this.tabs});

  static const double _height = 40;
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
    final corner = BorderRadius.circular(_cornerRadius);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SizedBox(
        key: SidebarPanel.tabStripKey,
        height: _height,
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
