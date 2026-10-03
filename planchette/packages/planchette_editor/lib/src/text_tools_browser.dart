import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart';

import 'editor_controller.dart';
import 'editor_strings.dart';
import 'ghost_menus.dart';
import 'text_tool_history.dart';

/// The shared text-tools catalog browser: Repeat and Recent first, then
/// the seven groups with descriptions and a keyword filter. Hosts open it
/// through [EditorController.openTextTools] — typically from one header
/// icon — and the shared view renders it; choosing a row dispatches back
/// through the controller, so every host runs the same transitions: a
/// find-bar tool opens its find row, a tool with options opens the options
/// bar, and the rest run at their defaults through the guarded runner.
///
/// The list scrolls inside whatever height its parent gives it, so a
/// narrow phone shows a usable scrolling surface. The header stacks the
/// filter below the title, like the find bar below 600 px, so 320 px
/// widths and large text scales never overflow.
class TextToolsBrowser extends StatefulWidget {
  const TextToolsBrowser({
    super.key,
    required this.controller,
    required this.strings,
    required this.locked,
  });

  final EditorController controller;
  final EditorStrings strings;

  /// The view's own lock, which joins the controller's gate: rows stay
  /// disabled while either holds, but the list still browses.
  final bool locked;

  @override
  State<TextToolsBrowser> createState() => TextToolsBrowserState();
}

class TextToolsBrowserState extends State<TextToolsBrowser> {
  final _filter = TextEditingController();
  final _filterNode = FocusNode(debugLabel: 'text tools filter');

  EditorController get c => widget.controller;
  EditorStrings get strings => widget.strings;

  bool get _canRun => !widget.locked && c.canEditText;

  @override
  void initState() {
    super.initState();
    c.trackTextField(_filterNode);
    // The document field is autofocus too and, being earlier in the scope,
    // wins every autofocus race — so the filter asks outright once built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterNode.requestFocus();
    });
  }

  @override
  void dispose() {
    c.untrackTextField(_filterNode);
    _filterNode.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _filter.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                container: true,
                label: strings.textToolsTitle,
                excludeSemantics: true,
                child: Text(
                  strings.textToolsTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ),
            IconButton(
              tooltip: strings.textToolsClose,
              visualDensity: VisualDensity.compact,
              onPressed: c.closeTextTools,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        TextField(
          contextMenuBuilder: ghostTextContextMenu,
          controller: _filter,
          focusNode: _filterNode,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: strings.textToolsFilterHint,
            prefixIcon: const Icon(Icons.search),
            isDense: true,
          ),
        ),
        const SizedBox(height: 4),
        Flexible(child: _list(context, query)),
      ],
    );
  }

  Widget _list(BuildContext context, String query) {
    final rows = <Widget>[];
    final recent = c.toolHistory.recent;
    final last = c.toolHistory.last;
    final words = _words(query);
    var visible = 0;

    bool matchesTool(TextTool tool) => words.isEmpty || _matches(tool, words);
    bool matchesRecord(TextToolRunRecord record) {
      // A host-built record can outlive its tool; without a row to run,
      // it is filtered from Repeat and Recent whatever the filter is.
      final tool = textToolById(record.toolId);
      if (tool == null) return false;
      if (words.isEmpty) return true;
      final summary = strings.textToolOptionsSummary(record);
      final haystack =
          '${strings.textToolName(tool.id)} $summary ${strings.textToolDescription(tool.id)}';
      return _containsAll(haystack, words);
    }

    if (last != null && matchesRecord(last)) {
      rows.add(_repeatTile(last));
      visible++;
    }
    final matchingRecent = [
      for (final record in recent)
        if (matchesRecord(record)) record,
    ];
    if (matchingRecent.isNotEmpty) {
      rows.add(_header(strings.textToolsHistoryGroup));
      for (final record in matchingRecent) {
        rows.add(_recentTile(record));
        visible++;
      }
    }
    for (final group in TextToolGroup.values) {
      final tools = [
        for (final tool in textToolCatalog)
          if (tool.group == group && matchesTool(tool)) tool,
      ];
      if (tools.isEmpty) continue;
      rows.add(_header(strings.textToolGroupName(group)));
      for (final tool in tools) {
        rows.add(_toolTile(tool));
        visible++;
      }
    }
    if (visible == 0) {
      return Center(child: Text(strings.textToolsNoResults));
    }
    return ListView(children: rows);
  }

  Widget _header(String label) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge),
    ),
  );

  Widget _repeatTile(TextToolRunRecord last) {
    final tool = textToolById(last.toolId);
    return ListTile(
      leading: const Icon(Icons.repeat),
      title: Text(strings.repeatTextToolLabel(last)),
      subtitle: tool == null
          ? null
          : Text(strings.textToolDescription(tool.id)),
      enabled: _canRun,
      onTap: _canRun ? () => unawaited(c.repeatTextTool()) : null,
    );
  }

  Widget _recentTile(TextToolRunRecord record) {
    final tool = textToolById(record.toolId);
    if (tool == null) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.history),
      title: Text(strings.recentTextToolLabel(record)),
      subtitle: Text(strings.textToolDescription(tool.id)),
      enabled: _canRun,
      onTap: _canRun ? () => unawaited(c.runRecentTextTool(record)) : null,
    );
  }

  Widget _toolTile(TextTool tool) => ListTile(
    title: Text(strings.textToolMenuLabel(tool.id)),
    subtitle: Text(strings.textToolDescription(tool.id)),
    enabled: _canRun,
    onTap: _canRun ? () => c.chooseTextTool(tool.id) : null,
  );

  /// The filter's words, lowercased: every word must match somewhere.
  static List<String> _words(String query) => [
    for (final word in query.toLowerCase().split(RegExp(r'\s+')))
      if (word.isNotEmpty) word,
  ];

  static bool _containsAll(String haystack, List<String> words) {
    final folded = haystack.toLowerCase();
    for (final word in words) {
      if (!folded.contains(word)) return false;
    }
    return true;
  }

  bool _matches(TextTool tool, List<String> words) {
    final strings = this.strings;
    final haystack = StringBuffer()
      ..write(strings.textToolName(tool.id))
      ..write(' ')
      ..write(strings.textToolDescription(tool.id))
      ..write(' ')
      ..write(strings.textToolGroupName(tool.group));
    for (final keyword in strings.textToolKeywords(tool.id)) {
      haystack
        ..write(' ')
        ..write(keyword);
    }
    return _containsAll(haystack.toString(), words);
  }
}
