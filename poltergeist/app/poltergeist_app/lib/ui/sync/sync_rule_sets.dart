// Sync's named skip rule sets (05 §3): the Add Rule Set menu beside a
// pair's excludes, the manager that creates, edits and deletes sets, and
// the editor both use. A set is a template: adding one copies its lines
// into the pair, so nothing here changes a pair after the fact.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/skip_rule_sets.dart';
import '../../services/skip_rule_sets_controller.dart';
import '../../theme/app_theme.dart';

/// Keys for the rule-set controls, so tests find them without string
/// literals. Per-set controls key on `(key, set name)`.
enum SkipRuleSetKey {
  addMenu,
  addItem,
  saveAs,
  manage,
  managerNew,
  managerEdit,
  managerDelete,
  managerError,
  editorName,
  editorPatterns,
  editorSave,
  editorError,
  deleteConfirm,
}

/// Add Rule Set: a menu of this device's sets; picking one hands it to
/// [onAdd], which appends its lines to the pair ([appendSkipRules]).
final class SkipRuleSetMenu extends StatelessWidget {
  const SkipRuleSetMenu({super.key, required this.sets, required this.onAdd});

  final SkipRuleSetsController sets;
  final ValueChanged<SkipRuleSet> onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: sets,
      builder: (context, _) => MenuAnchor(
        menuChildren: [
          if (sets.value.isEmpty)
            MenuItemButton(onPressed: null, child: Text(l10n.syncRuleSetsNone)),
          for (final set in sets.value)
            MenuItemButton(
              key: ValueKey((SkipRuleSetKey.addItem, set.name)),
              onPressed: () => onAdd(set),
              trailingIcon: Text(l10n.syncSheetRuleCount(set.patterns.length)),
              child: Text(set.name),
            ),
        ],
        builder: (context, menu, _) => TextButton.icon(
          key: const ValueKey(SkipRuleSetKey.addMenu),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(Icons.arrow_drop_down),
          iconAlignment: IconAlignment.end,
          label: Text(l10n.syncRuleSetsAdd),
        ),
      ),
    );
  }
}

/// Manage Rule Sets: lists this device's sets with edit and delete, and
/// starts new ones. Changes save as they are made; Done only closes.
Future<void> showSkipRuleSetsManager(
  BuildContext context,
  SkipRuleSetsController sets,
) => showDialog<void>(
  context: context,
  builder: (_) => _ManagerDialog(sets: sets),
);

/// Creates a set, or edits [initial] (renaming it when the name changes),
/// starting from [patterns] for a new one. Completes with the saved set,
/// or null when cancelled.
Future<SkipRuleSet?> showSkipRuleSetEditor(
  BuildContext context,
  SkipRuleSetsController sets, {
  SkipRuleSet? initial,
  List<String> patterns = const [],
}) => showDialog<SkipRuleSet>(
  context: context,
  builder: (_) => _EditorDialog(
    sets: sets,
    initial: initial,
    patterns: initial?.patterns ?? patterns,
  ),
);

class _ManagerDialog extends StatefulWidget {
  const _ManagerDialog({required this.sets});

  final SkipRuleSetsController sets;

  @override
  State<_ManagerDialog> createState() => _ManagerDialogState();
}

class _ManagerDialogState extends State<_ManagerDialog> {
  /// Why the last delete failed; the list stays as stored.
  String? _error;

  Future<void> _edit(SkipRuleSet? set) async {
    setState(() => _error = null);
    await showSkipRuleSetEditor(context, widget.sets, initial: set);
  }

  Future<void> _delete(SkipRuleSet set) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _error = null);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.syncRuleSetDeleteTitle(set.name)),
        content: Text(l10n.syncRuleSetDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.syncCancel),
          ),
          FilledButton(
            key: const ValueKey(SkipRuleSetKey.deleteConfirm),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.syncRuleSetDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.sets.remove(set.name);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.syncRuleSetDeleteFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    return AlertDialog(
      title: Text(l10n.syncRuleSetsTitle),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: ListenableBuilder(
          listenable: widget.sets,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.sets.value.isEmpty)
                Text(
                  l10n.syncRuleSetsEmpty,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: chrome.secondaryText,
                  ),
                ),
              for (final set in widget.sets.value)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(set.name),
                  subtitle: Text(l10n.syncSheetRuleCount(set.patterns.length)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: ValueKey((SkipRuleSetKey.managerEdit, set.name)),
                        tooltip: l10n.syncRuleSetsEditTooltip(set.name),
                        onPressed: () => _edit(set),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        key: ValueKey((SkipRuleSetKey.managerDelete, set.name)),
                        tooltip: l10n.syncRuleSetsDeleteTooltip(set.name),
                        onPressed: () => _delete(set),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    key: const ValueKey(SkipRuleSetKey.managerError),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey(SkipRuleSetKey.managerNew),
          onPressed: () => _edit(null),
          child: Text(l10n.syncRuleSetsNew),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.syncRulesDone),
        ),
      ],
    );
  }
}

class _EditorDialog extends StatefulWidget {
  const _EditorDialog({
    required this.sets,
    required this.initial,
    required this.patterns,
  });

  final SkipRuleSetsController sets;
  final SkipRuleSet? initial;
  final List<String> patterns;

  @override
  State<_EditorDialog> createState() => _EditorDialogState();
}

class _EditorDialogState extends State<_EditorDialog> {
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _patterns = TextEditingController(
    text: widget.patterns.join('\n'),
  );
  String? _nameError;
  String? _patternsError;
  String? _saveError;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _patterns.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    final patterns = skipRuleLines(_patterns.text);
    final taken = skipRuleSetNamed(widget.sets.value, name);
    final renamingItself = taken != null && taken.name == widget.initial?.name;
    setState(() {
      _nameError = name.isEmpty
          ? l10n.syncRuleSetNameEmpty
          : (taken != null && !renamingItself
                ? l10n.syncRuleSetNameTaken(taken.name)
                : null);
      _patternsError = hasSkipPattern(patterns)
          ? null
          : l10n.syncRuleSetNoPatterns;
      _saveError = null;
    });
    if (_nameError != null || _patternsError != null) return;

    final set = SkipRuleSet(name: name, patterns: patterns);
    setState(() => _saving = true);
    try {
      await widget.sets.put(set, replacing: widget.initial?.name);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = l10n.syncRuleSetSaveFailed;
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(set);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? l10n.syncRuleSetNewTitle
            : l10n.syncRuleSetEditTitle,
      ),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey(SkipRuleSetKey.editorName),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.syncRuleSetName,
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey(SkipRuleSetKey.editorPatterns),
              controller: _patterns,
              minLines: 4,
              maxLines: 10,
              style: theme.textTheme.bodyMedium?.merge(
                poltergeistMonoTextStyle,
              ),
              decoration: InputDecoration(
                helperText: l10n.syncRulesHint,
                helperMaxLines: 3,
                errorText: _patternsError,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_saveError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  key: const ValueKey(SkipRuleSetKey.editorError),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.syncCancel),
        ),
        FilledButton(
          key: const ValueKey(SkipRuleSetKey.editorSave),
          onPressed: _saving ? null : _save,
          child: Text(l10n.syncRuleSetSave),
        ),
      ],
    );
  }
}
