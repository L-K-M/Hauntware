import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../family_hues.dart';
import '../main.dart';
import '../services/mac_commands.dart';
import '../services/undo_history.dart';
import '../theme.dart' show SeanceTheme;
import 'top_toast.dart';

/// The Snippets tab: reusable command templates, synced across devices. Tapping
/// one inserts it into the active terminal's prompt; if it has `{{placeholder}}`
/// tokens the user is asked to fill them in first. Never runs anything.
class SnippetsPane extends StatefulWidget {
  const SnippetsPane({super.key});

  @override
  State<SnippetsPane> createState() => _SnippetsPaneState();
}

class _SnippetsPaneState extends State<SnippetsPane> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final all = state.snippets;
        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? all
            : all
                  .where(
                    (s) =>
                        s.title.toLowerCase().contains(q) ||
                        s.body.toLowerCase().contains(q),
                  )
                  .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.bookmarks,
                    size: 20,
                    color: FamilyPalette.of(context).glyph(FamilyHue.teal),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Snippets',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'New snippet',
                    icon: const Icon(Icons.add),
                    onPressed: () => _edit(context, state, null),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // A filter box, once there are enough snippets to warrant
            // scrolling — but keep it while a query is active, or filtering
            // the list below the threshold would strand an uneditable filter.
            if (all.length > 4 || _query.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: 'Filter snippets…',
                    border: const OutlineInputBorder(),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                  ),
                ),
              ),
            if (state.commandSuggestions.isNotEmpty) _Suggestions(state: state),
            Expanded(
              child: all.isEmpty
                  ? const _SnippetsEmpty()
                  : filtered.isEmpty
                  ? const _NoMatches()
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final s = filtered[i];
                        final count = s.placeholders.length;
                        return ListTile(
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            count > 0
                                ? '$count placeholder${count == 1 ? '' : 's'} · ${_preview(s.body)}'
                                : _preview(s.body),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SeanceTheme.mono,
                          ),
                          onTap: () => _insert(context, state, s),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) => v == 'edit'
                                ? _edit(context, state, s)
                                : _delete(context, state, s),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  static String _preview(String body) => body.replaceAll('\n', ' ').trim();

  Future<void> _insert(
    BuildContext context,
    AppState state,
    Snippet snippet,
  ) async {
    final session = state.activeSession;
    final overlay = Overlay.of(context, rootOverlay: true);
    if (session == null || !session.isConnected) {
      showTopToast(overlay, message: 'Open a connected session first.');
      return;
    }
    var text = snippet.body;
    final names = snippet.placeholders;
    if (names.isNotEmpty) {
      final values = await showPlaceholderDialog(context, snippet.title, names);
      if (values == null) return; // cancelled
      text = snippet.fill(values);
    }
    try {
      text = PasteSanitizer.sanitize(text);
    } on UnsafePasteException catch (e) {
      showTopToast(overlay, message: e.reason);
      return;
    }
    session.engine.injectInput(text);
    // Top toast so it doesn't cover the prompt the snippet was inserted into.
    showTopToast(
      overlay,
      message: 'Inserted "${snippet.title}" into the prompt',
      duration: const Duration(seconds: 3),
    );
  }

  Future<void> _edit(
    BuildContext context,
    AppState state,
    Snippet? existing,
  ) async {
    await showSnippetEditor(context, state, existing);
  }

  /// On a Mac the snippet goes at once and Edit ▸ Undo, or the toast's
  /// Undo, brings it back, as Finder and Notes delete; elsewhere a dialog
  /// asks first.
  Future<void> _delete(
    BuildContext context,
    AppState state,
    Snippet snippet,
  ) async {
    if (macNativeShell) {
      final change = await deleteSnippetUndoably(state, snippet);
      if (!context.mounted) return;
      showTopToastIn(
        context,
        message: 'Deleted “${snippet.title}”',
        actionLabel: 'Undo',
        // This deletion only, while it is still the one Undo would take
        // back: a later change has its own.
        onAction: () {
          final history = state.undoHistory;
          if (history.isNextUndo(change)) unawaited(history.undo());
        },
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${snippet.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await deleteSnippetUndoably(state, snippet);
  }
}

/// Deletes [snippet] and records it for Edit ▸ Undo, which saves it back,
/// and returns the recorded change.
Future<UndoableChange> deleteSnippetUndoably(
  AppState state,
  Snippet snippet,
) async {
  await state.deleteSnippet(snippet.id);
  final stamps = _RestoreStamps(snippet.updatedAt);
  final change = UndoableChange(
    name: 'Delete Snippet',
    undo: () => state.saveSnippet(snippet.copyWith(updatedAt: stamps.next())),
    redo: () => state.deleteSnippet(snippet.id),
  );
  state.undoHistory.record(change);
  return change;
}

/// Stamps for a snippet written back by Undo or Redo. Each must outrank
/// every version this device stamped before it, the deletion's tombstone
/// included, which beats its row by one: [AppState.deleteSnippet] stamps
/// max(now, prior + 1). A plain "now" would lose to a row from a device
/// whose clock runs ahead, and the restored snippet would vanish again.
final class _RestoreStamps {
  _RestoreStamps(this._latest);

  int _latest;

  int next() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _latest = now > _latest + 1 ? now : _latest + 2;
    return _latest;
  }
}

/// Frequently-run commands (from the local, opt-in history) that aren't
/// snippets yet. Save one to turn it into a real, syncable snippet, or dismiss
/// it to stop it being suggested.
class _Suggestions extends StatelessWidget {
  final AppState state;
  const _Suggestions({required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Row(
              children: [
                Icon(
                  Icons.lightbulb,
                  size: 16,
                  color: FamilyPalette.of(context).glyph(FamilyHue.yellow),
                ),
                const SizedBox(width: 6),
                Text(
                  'Suggested from your history',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
          for (final cmd in state.commandSuggestions)
            ListTile(
              dense: true,
              title: Text(
                cmd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SeanceTheme.mono.copyWith(fontSize: 13),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Save as snippet',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 20),
                    onPressed: () => state.addSuggestionAsSnippet(cmd),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => state.dismissSuggestion(cmd),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

class _SnippetsEmpty extends StatelessWidget {
  const _SnippetsEmpty();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmarks,
              size: 36,
              color: FamilyPalette.of(context).glyph(FamilyHue.teal),
            ),
            const SizedBox(height: 12),
            Text(
              'No snippets yet',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Save commands you reuse. Add {{placeholders}} and you\'ll be '
              'asked to fill them in each time you insert one. Snippets sync '
              'across your devices.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a filter matches no snippets.
class _NoMatches extends StatelessWidget {
  const _NoMatches();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No snippets match your filter.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// Add or edit a snippet.
Future<void> showSnippetEditor(
  BuildContext context,
  AppState state,
  Snippet? existing,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SnippetEditor(state: state, existing: existing),
  );
}

class _SnippetEditor extends StatefulWidget {
  final AppState state;
  final Snippet? existing;
  const _SnippetEditor({required this.state, this.existing});

  @override
  State<_SnippetEditor> createState() => _SnippetEditorState();
}

class _SnippetEditorState extends State<_SnippetEditor> {
  late final TextEditingController _title = TextEditingController(
    text: widget.existing?.title ?? '',
  );
  late final TextEditingController _body = TextEditingController(
    text: widget.existing?.body ?? '',
  );

  /// A snippet needs both a title and a command; Save waits for them
  /// rather than closing on a draft it would drop.
  bool get _complete =>
      _title.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    _body.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_complete) return;
    final title = _title.text.trim();
    final body = _body.text;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = widget.existing;
    final snippet = existing == null
        ? Snippet(
            id: uuidV4(),
            title: title,
            body: body,
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(title: title, body: body, updatedAt: now);
    final state = widget.state;
    // An unchanged save is no change: nothing to write, sync or undo.
    final unchanged =
        existing != null && existing.title == title && existing.body == body;
    if (unchanged) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await state.saveSnippet(snippet);
    final stamps = _RestoreStamps(snippet.updatedAt);
    state.undoHistory.record(
      existing == null
          ? UndoableChange(
              name: 'New Snippet',
              undo: () => state.deleteSnippet(snippet.id),
              redo: () =>
                  state.saveSnippet(snippet.copyWith(updatedAt: stamps.next())),
            )
          : UndoableChange(
              name: 'Edit Snippet',
              undo: () => state.saveSnippet(
                existing.copyWith(updatedAt: stamps.next()),
              ),
              redo: () =>
                  state.saveSnippet(snippet.copyWith(updatedAt: stamps.next())),
            ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Return in the title saves, as a sheet's default button does; the
    // command takes newlines, so ⌘Return (Ctrl+Return) saves from there.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
      },
      child: _dialog(context),
    );
  }

  Widget _dialog(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New snippet' : 'Edit snippet'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 10,
              style: SeanceTheme.mono.copyWith(fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Command',
                hintText: r'e.g. tail -f {{logfile}} | grep {{pattern}}',
                helperText: r'Use {{name}} for values to fill in on insert',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _complete ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Ask the user to fill in [names]; returns name→value, or null if cancelled.
Future<Map<String, String>?> showPlaceholderDialog(
  BuildContext context,
  String title,
  List<String> names,
) {
  return showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _PlaceholderDialog(title: title, names: names),
  );
}

/// Owns one controller per placeholder in its [State] so they are disposed in
/// [State.dispose] — after the route's exit animation, once the fields are
/// truly unmounted. Disposing right after `await showDialog(...)` is too
/// early: the pop future completes when the reverse transition *starts*, the
/// fields stay mounted through it, and the framework can still write to a
/// controller (e.g. `clearComposing()` when the focused field loses focus) —
/// a use-after-dispose that throws in debug builds whenever an IME composing
/// region is active (regression: test/placeholder_dialog_test.dart).
class _PlaceholderDialog extends StatefulWidget {
  const _PlaceholderDialog({required this.title, required this.names});

  final String title;
  final List<String> names;

  @override
  State<_PlaceholderDialog> createState() => _PlaceholderDialogState();
}

class _PlaceholderDialogState extends State<_PlaceholderDialog> {
  late final Map<String, TextEditingController> _controllers = {
    for (final n in widget.names) n: TextEditingController(),
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.names.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _controllers[widget.names[i]],
                    autofocus: i == 0,
                    decoration: InputDecoration(
                      labelText: widget.names[i],
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            for (final e in _controllers.entries) e.key: e.value.text,
          }),
          child: const Text('Insert'),
        ),
      ],
    );
  }
}
