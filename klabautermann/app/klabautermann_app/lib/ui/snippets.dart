import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/snippets_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'actions/action_entry.dart';
import 'actions/action_preview.dart';
import 'actions/cron_run_output.dart';

/// Hands the [SnippetsController] to the server header; without one, as
/// in tests that leave snippets out, no surface offers them.
class SnippetsScope extends InheritedNotifier<SnippetsController> {
  const SnippetsScope({
    super.key,
    required SnippetsController snippets,
    required super.child,
  }) : super(notifier: snippets);

  static SnippetsController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SnippetsScope>()?.notifier;
}

/// The server header's way to Séance's snippets (AUT-01), shown where
/// actions on [serverId] are allowed.
class SnippetsButton extends StatelessWidget {
  const SnippetsButton({
    super.key,
    required this.serverId,
    required this.serverName,
  });

  final String serverId;
  final String serverName;

  @override
  Widget build(BuildContext context) {
    final snippets = SnippetsScope.maybeOf(context);
    if (snippets == null ||
        !actionsAllowedAt(context, serverId, ActionEntryPoint.snippetRun)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.integration_instructions_outlined),
      tooltip: AppLocalizations.of(context).snippetsTitle,
      onPressed: () => unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SnippetsPage(
              snippets: snippets,
              serverId: serverId,
              serverName: serverName,
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether [snippet] holds every term of [terms] in its title or command,
/// ignoring case.
bool snippetMatches(Snippet snippet, List<String> terms) {
  if (terms.isEmpty) return true;

  final haystack = '${snippet.title}\n${snippet.body}'.toLowerCase();
  return terms.every(haystack.contains);
}

/// The snippets page (03 §7.21, AUT-01): the account's snippets, as
/// Séance saved them, searchable; choosing one fills its placeholders
/// and previews it as an action on [serverId], whose output shows once
/// it ran.
class SnippetsPage extends StatefulWidget {
  const SnippetsPage({
    super.key,
    required this.snippets,
    required this.serverId,
    required this.serverName,
  });

  final SnippetsController snippets;
  final String serverId;
  final String serverName;

  @override
  State<SnippetsPage> createState() => _SnippetsPageState();
}

class _SnippetsPageState extends State<SnippetsPage> {
  var _terms = const <String>[];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.snippetsPageTitle(widget.serverName))),
      body: ListenableBuilder(
        listenable: widget.snippets,
        builder: (context, _) {
          final all = widget.snippets.snippets;
          final shown = [
            for (final snippet in all)
              if (snippetMatches(snippet, _terms)) snippet,
          ];
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (all.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    decoration: InputDecoration(
                      labelText: l10n.snippetsSearch,
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (text) => setState(
                      () => _terms = [
                        for (final term in text.toLowerCase().split(' '))
                          if (term.isNotEmpty) term,
                      ],
                    ),
                  ),
                ),
              if (all.isEmpty)
                _Note(l10n.snippetsEmpty)
              else if (shown.isEmpty)
                _Note(l10n.snippetsNoMatch),
              for (final snippet in shown)
                ListTile(
                  title: Text(_titleOf(l10n, snippet)),
                  subtitle: Text(
                    snippet.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _mono(context),
                  ),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () => unawaited(_run(snippet)),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Fills [snippet]'s placeholders, when it has any, then previews it.
  Future<void> _run(Snippet snippet) async {
    final l10n = AppLocalizations.of(context);
    final command = snippet.placeholders.isEmpty
        ? snippet.body
        : await showDialog<String>(
            context: context,
            builder: (_) => SnippetFillDialog(
              snippet: snippet,
              title: _titleOf(l10n, snippet),
            ),
          );
    if (command == null || !mounted) return;

    startAction(
      context,
      RunSnippet(widget.serverId, title: snippet.title, command: command),
      onRun: _showOutput,
    );
  }

  /// The run's output sheet, as a cron line's run shows it.
  void _showOutput(String planId, ActionPreview preview) {
    if (!mounted) return;
    final operations = OperationsScope.maybeOf(context);
    if (operations == null) return;
    unawaited(
      showCronRunOutput(
        context,
        operations: operations,
        planId: planId,
        title: preview.targetName,
      ),
    );
  }
}

/// The placeholder dialog (AUT-01): a field per placeholder, in the order
/// the command names them, and the command as it will be filled. It pops
/// the filled command, and allows it only once every value is in, so a
/// blank never turns `rm -rf /{{dir}}` into `rm -rf /`.
class SnippetFillDialog extends StatefulWidget {
  const SnippetFillDialog({
    super.key,
    required this.snippet,
    required this.title,
  });

  final Snippet snippet;
  final String title;

  @override
  State<SnippetFillDialog> createState() => _SnippetFillDialogState();
}

class _SnippetFillDialogState extends State<SnippetFillDialog> {
  late final Map<String, TextEditingController> _fields = {
    for (final name in widget.snippet.placeholders)
      name: TextEditingController(),
  };

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {
    for (final MapEntry(:key, :value) in _fields.entries) key: value.text,
  };

  bool get _complete => _fields.values.every((f) => f.text.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final complete = _complete;
    return AlertDialog(
      title: Text(l10n.snippetsFillTitle(widget.title)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(l10n.snippetsFillHint),
            for (final (index, MapEntry(key: name, value: field))
                in _fields.entries.indexed)
              TextField(
                controller: field,
                autofocus: index == 0,
                decoration: InputDecoration(labelText: name),
                onChanged: (_) => setState(() {}),
              ),
            Text(
              l10n.snippetsFillCommand,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            SelectableText(widget.snippet.fill(_values), style: _mono(context)),
            if (!complete) Text(l10n.snippetsFillRequired),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.snippetsCancel),
        ),
        FilledButton(
          onPressed: complete
              ? () => Navigator.of(context).pop(widget.snippet.fill(_values))
              : null,
          child: Text(l10n.snippetsContinue),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Text(text));
}

String _titleOf(AppLocalizations l10n, Snippet snippet) =>
    snippet.title.trim().isEmpty ? l10n.snippetsUntitled : snippet.title;

TextStyle? _mono(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
      fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies
          .skip(1)
          .toList(growable: false),
    );
