import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show normalizeEditorExtensions, validateEditorDisplayName;

import 'editor_definition.dart';
import 'editor_registry.dart';

/// The registry the Settings section edits. Every mutation persists before
/// it resolves and throws when it could not, leaving [registry] as stored.
abstract interface class EditorRegistryModel implements Listenable {
  /// The live registry.
  EditorRegistry get registry;

  /// Adds or replaces [editor].
  Future<void> register(ExternalEditorDefinition editor);

  Future<void> remove(String id);

  /// Sets the global default to a selector or a registered editor id.
  Future<void> setDefault(String id);

  /// Binds [extension] to [editorId]; null clears the binding.
  Future<void> setExtensionDefault(String extension, String? editorId);
}

/// The platform's application picker behind Add editor: null when the
/// user cancels. [GhostEditorLauncher.pickEditor] in an app's own engine.
typedef EditorPicker =
    Future<ExternalEditorDefinition?> Function({required String dialogTitle});

/// [GhostEditorsSettingsSection]'s strings, in the app's own words and
/// language.
@immutable
final class GhostEditorsStrings {
  const GhostEditorsStrings({
    required this.defaultLabel,
    required this.builtInOption,
    required this.systemDefaultOption,
    required this.otherPlatformName,
    required this.listLabel,
    required this.emptyState,
    required this.desktopOnly,
    required this.addLabel,
    required this.pickDialogTitle,
    required this.addTitle,
    required this.editTitle,
    required this.editLabel,
    required this.removeLabel,
    required this.removeTitle,
    required this.removeBody,
    required this.removeDefaultBody,
    required this.nameFieldLabel,
    required this.extensionsFieldLabel,
    required this.extensionsFieldHint,
    required this.extensionsFieldHelper,
    required this.cancel,
    required this.save,
    required this.bindingsLabel,
    required this.bindingsEmpty,
    required this.bindingAddLabel,
    required this.bindingAddTitle,
    required this.bindingExtensionLabel,
    required this.bindingExtensionHint,
    required this.bindingEditorLabel,
    required this.bindingExtensionInvalid,
    required this.bindingEditorRejects,
  });

  /// The global default dropdown's label.
  final String defaultLabel;

  /// The built-in text editor, as a choice.
  final String builtInOption;

  /// The OS default application, as a choice.
  final String systemDefaultOption;

  /// An editor configured for another platform, by its `name`.
  final String Function(String name) otherPlatformName;

  /// The heading over the configured editors.
  final String listLabel;

  /// Shown instead of the list when no editor is configured.
  final String emptyState;

  /// Shown instead of Add editor on a host without desktop editors.
  final String desktopOnly;

  final String addLabel;

  /// The application picker's title.
  final String pickDialogTitle;

  /// The edit dialog's title after a pick, and when editing.
  final String addTitle;
  final String editTitle;

  /// A row's actions.
  final String editLabel;
  final String removeLabel;

  /// The remove confirmation, by editor `name`; the body when the editor
  /// is not, and when it is, the current default.
  final String Function(String name) removeTitle;
  final String removeBody;
  final String removeDefaultBody;

  /// The edit dialog's fields.
  final String nameFieldLabel;
  final String extensionsFieldLabel;
  final String extensionsFieldHint;
  final String extensionsFieldHelper;

  final String cancel;
  final String save;

  /// The heading over the per-extension defaults.
  final String bindingsLabel;

  /// Shown instead of the bindings when there are none.
  final String bindingsEmpty;

  /// The button that adds a binding, and its dialog's title.
  final String bindingAddLabel;
  final String bindingAddTitle;

  /// The binding dialog's fields.
  final String bindingExtensionLabel;
  final String bindingExtensionHint;
  final String bindingEditorLabel;

  /// The extension field holds no single extension (blank, or a list).
  final String bindingExtensionInvalid;

  /// The chosen editor does not accept the extension, by editor `name`
  /// and bare `extension`.
  final String Function(String name, String extension) bindingEditorRejects;
}

/// Settings' external editor sections: the global default dropdown, the
/// configured editors with Add, Edit and Remove, and the per-extension
/// defaults. Other-platform editors stay visible but disabled, since a
/// synced registry can carry them.
final class GhostEditorsSettingsSection extends StatelessWidget {
  const GhostEditorsSettingsSection({
    super.key,
    required this.model,
    required this.picker,
    required this.strings,
    required this.onError,
  });

  final EditorRegistryModel model;
  final EditorPicker picker;
  final GhostEditorsStrings strings;

  /// Reports a failed pick or write; the section has already left the
  /// registry as the model holds it.
  final void Function(BuildContext context, Object error, StackTrace stack)
  onError;

  Future<void> _guarded(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      if (context.mounted) onError(context, error, stackTrace);
    }
  }

  /// Add editor: the platform pick, then the edit dialog, so extensions
  /// can be scoped before the registration persists. A cancelled dialog
  /// discards the pick.
  Future<void> _addEditor(BuildContext context) => _guarded(context, () async {
    final picked = await picker(dialogTitle: strings.pickDialogTitle);
    if (picked == null || !context.mounted) return;
    final updated = await _editEditorDialog(
      context,
      editor: picked,
      strings: strings,
      adding: true,
    );
    if (updated == null || !context.mounted) return;
    await model.register(updated);
  });

  Future<void> _editEditor(
    BuildContext context,
    ExternalEditorDefinition editor,
  ) async {
    final updated = await _editEditorDialog(
      context,
      editor: editor,
      strings: strings,
    );
    if (updated == null || !context.mounted) return;
    await _guarded(context, () => model.register(updated));
  }

  Future<void> _removeEditor(
    BuildContext context,
    ExternalEditorDefinition editor,
  ) async {
    final isDefault = model.registry.defaultEditorId == editor.id;
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('editors.remove.dialog'),
        title: Text(strings.removeTitle(editor.displayName)),
        content: Text(
          isDefault ? strings.removeDefaultBody : strings.removeBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('editors.remove.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.removeLabel),
          ),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    await _guarded(context, () => model.remove(editor.id));
  }

  Future<void> _addBinding(BuildContext context) async {
    final binding = await showDialog<(String, String)>(
      context: context,
      builder: (_) =>
          _BindingDialog(registry: model.registry, strings: strings),
    );
    if (binding == null || !context.mounted) return;
    final (extension, editorId) = binding;
    await _guarded(
      context,
      () => model.setExtensionDefault(extension, editorId),
    );
  }

  String _targetName(EditorRegistry registry, String id) {
    if (id == EditorRegistry.builtInId) return strings.builtInOption;
    if (id == EditorRegistry.systemDefaultId) {
      return strings.systemDefaultOption;
    }
    final editor = registry.byId(id);
    if (editor == null) return id;
    return editor.isAvailableOnCurrentPlatform
        ? editor.displayName
        : strings.otherPlatformName(editor.displayName);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final registry = model.registry;
      final desktop = currentEditorHostPlatform != null;
      final theme = Theme.of(context);
      final bindings = registry.extensionDefaults.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(strings.defaultLabel)),
              Flexible(
                child: DropdownButton<String>(
                  key: const ValueKey('editors.default'),
                  value: registry.defaultEditorId,
                  isExpanded: true,
                  items: _editorChoiceItems(
                    registry,
                    strings,
                    keyPrefix: 'editors.default',
                    includeOtherPlatform: true,
                  ),
                  onChanged: (id) {
                    if (id == null) return;
                    unawaited(_guarded(context, () => model.setDefault(id)));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(strings.listLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          if (registry.editors.isEmpty)
            Text(strings.emptyState, style: theme.textTheme.bodySmall)
          else
            for (final editor in registry.editors)
              _EditorListRow(
                editor: editor,
                strings: strings,
                onEdit: () => unawaited(_editEditor(context, editor)),
                onRemove: () => unawaited(_removeEditor(context, editor)),
              ),
          const SizedBox(height: 8),
          if (desktop)
            TextButton.icon(
              key: const ValueKey('editors.add'),
              onPressed: () => unawaited(_addEditor(context)),
              icon: const Icon(Icons.add),
              label: Text(strings.addLabel),
            )
          else
            Text(strings.desktopOnly, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          Text(strings.bindingsLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          if (bindings.isEmpty)
            Text(strings.bindingsEmpty, style: theme.textTheme.bodySmall)
          else
            for (final MapEntry(key: extension, value: target) in bindings)
              Padding(
                key: ValueKey('editors.binding.$extension'),
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Chip(
                      label: Text('*.$extension'),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _targetName(registry, target),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      key: ValueKey('editors.binding.remove.$extension'),
                      onPressed: () => unawaited(
                        _guarded(
                          context,
                          () => model.setExtensionDefault(extension, null),
                        ),
                      ),
                      child: Text(strings.removeLabel),
                    ),
                  ],
                ),
              ),
          if (desktop) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('editors.binding.add'),
              onPressed: () => unawaited(_addBinding(context)),
              icon: const Icon(Icons.add),
              label: Text(strings.bindingAddLabel),
            ),
          ],
        ],
      );
    },
  );
}

/// The selectors and editors as dropdown items. System default is always
/// listed, so a synced value still matches an item, and disabled where it
/// cannot launch.
List<DropdownMenuItem<String>> _editorChoiceItems(
  EditorRegistry registry,
  GhostEditorsStrings strings, {
  required String keyPrefix,
  required bool includeOtherPlatform,
}) => [
  DropdownMenuItem(
    key: ValueKey('$keyPrefix.builtin'),
    value: EditorRegistry.builtInId,
    child: Text(strings.builtInOption, overflow: TextOverflow.ellipsis),
  ),
  DropdownMenuItem(
    key: ValueKey('$keyPrefix.system'),
    value: EditorRegistry.systemDefaultId,
    enabled: currentEditorHostPlatform != null,
    child: Text(strings.systemDefaultOption, overflow: TextOverflow.ellipsis),
  ),
  for (final editor in registry.editors)
    if (includeOtherPlatform || editor.isAvailableOnCurrentPlatform)
      DropdownMenuItem(
        key: ValueKey('$keyPrefix.${editor.id}'),
        value: editor.id,
        enabled: editor.isAvailableOnCurrentPlatform,
        child: Text(
          editor.isAvailableOnCurrentPlatform
              ? editor.displayName
              : strings.otherPlatformName(editor.displayName),
          overflow: TextOverflow.ellipsis,
        ),
      ),
];

/// A configured editor: display name, launch target, accepted extensions
/// as `*.ext` chips, and Edit and Remove. Other-platform definitions
/// render disabled; they are real entries, just not launchable here.
class _EditorListRow extends StatelessWidget {
  const _EditorListRow({
    required this.editor,
    required this.strings,
    required this.onEdit,
    required this.onRemove,
  });

  final ExternalEditorDefinition editor;
  final GhostEditorsStrings strings;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final available = editor.isAvailableOnCurrentPlatform;
    final theme = Theme.of(context);
    final name = available
        ? editor.displayName
        : strings.otherPlatformName(editor.displayName);
    return Padding(
      key: ValueKey('editors.row.${editor.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: available
                      ? null
                      : theme.textTheme.bodyMedium?.copyWith(
                          color: theme.disabledColor,
                        ),
                ),
                Text(
                  editor.launchTarget,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (editor.acceptedExtensions.isNotEmpty)
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final extension in editor.acceptedExtensions)
                        Chip(
                          label: Text('*.$extension'),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
              ],
            ),
          ),
          TextButton(
            key: ValueKey('editors.edit.${editor.id}'),
            onPressed: available ? onEdit : null,
            child: Text(strings.editLabel),
          ),
          TextButton(
            key: ValueKey('editors.remove.${editor.id}'),
            onPressed: onRemove,
            child: Text(strings.removeLabel),
          ),
        ],
      ),
    );
  }
}

Future<ExternalEditorDefinition?> _editEditorDialog(
  BuildContext context, {
  required ExternalEditorDefinition editor,
  required GhostEditorsStrings strings,
  bool adding = false,
}) => showDialog<ExternalEditorDefinition>(
  context: context,
  builder: (_) =>
      _EditEditorDialog(editor: editor, strings: strings, adding: adding),
);

/// The edit dialog: display name plus the comma-separated extensions. The
/// controllers live in the State so they outlive the route's exit
/// animation. Validation failures render inline under the name field, and
/// only a valid result pops.
final class _EditEditorDialog extends StatefulWidget {
  const _EditEditorDialog({
    required this.editor,
    required this.strings,
    required this.adding,
  });

  final ExternalEditorDefinition editor;
  final GhostEditorsStrings strings;
  final bool adding;

  @override
  State<_EditEditorDialog> createState() => _EditEditorDialogState();
}

final class _EditEditorDialogState extends State<_EditEditorDialog> {
  late final _name = TextEditingController(text: widget.editor.displayName);
  late final _extensions = TextEditingController(
    text: widget.editor.acceptedExtensions.join(', '),
  );
  String? _nameError;
  String? _extensionsError;

  @override
  void dispose() {
    _name.dispose();
    _extensions.dispose();
    super.dispose();
  }

  void _clearErrors() {
    if (_nameError == null && _extensionsError == null) return;
    setState(() {
      _nameError = null;
      _extensionsError = null;
    });
  }

  /// The Save button and Return in the last field share one action, so
  /// both validate identically.
  /// Each field reports its own error, so an invalid extension is not
  /// shown as a problem with the name.
  void _save() {
    final String displayName;
    try {
      displayName = validateEditorDisplayName(_name.text);
    } on FormatException catch (error) {
      setState(() => _nameError = error.message);
      return;
    }
    final List<String> extensions;
    try {
      extensions = normalizeEditorExtensions(_extensions.text.split(','));
    } on FormatException catch (error) {
      setState(() => _extensionsError = error.message);
      return;
    }
    Navigator.of(context).pop(
      widget.editor.copyWith(
        displayName: displayName,
        acceptedExtensions: extensions,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      title: Text(widget.adding ? strings.addTitle : strings.editTitle),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                onChanged: (_) => _clearErrors(),
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: strings.nameFieldLabel,
                  errorText: _nameError,
                ),
              ),
              TextField(
                controller: _extensions,
                onChanged: (_) => _clearErrors(),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  labelText: strings.extensionsFieldLabel,
                  hintText: strings.extensionsFieldHint,
                  helperText: strings.extensionsFieldHelper,
                  errorText: _extensionsError,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.editor.launchTarget,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('editors.edit.save'),
          onPressed: _save,
          child: Text(strings.save),
        ),
      ],
    );
  }
}

/// The add-binding dialog: one extension and the editor it opens in.
/// Pops `(extension, editorId)` with the extension normalized.
final class _BindingDialog extends StatefulWidget {
  const _BindingDialog({required this.registry, required this.strings});

  final EditorRegistry registry;
  final GhostEditorsStrings strings;

  @override
  State<_BindingDialog> createState() => _BindingDialogState();
}

final class _BindingDialogState extends State<_BindingDialog> {
  final _extension = TextEditingController();
  late String _editorId = widget.registry.defaultEditorId;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    // Start on a choice the dropdown offers.
    final editor = widget.registry.byId(_editorId);
    if (editor != null && !editor.isAvailableOnCurrentPlatform) {
      _editorId = widget.registry.scheme.defaultSelector;
    }
  }

  @override
  void dispose() {
    _extension.dispose();
    super.dispose();
  }

  void _save() {
    final strings = widget.strings;
    final text = _extension.text;
    if (text.contains(',') || RegExp(r'\s').hasMatch(text.trim())) {
      setState(() => _validationError = strings.bindingExtensionInvalid);
      return;
    }
    final List<String> normalized;
    try {
      normalized = normalizeEditorExtensions([text]);
    } on FormatException catch (error) {
      setState(() => _validationError = error.message);
      return;
    }
    if (normalized.isEmpty) {
      setState(() => _validationError = strings.bindingExtensionInvalid);
      return;
    }
    final extension = normalized.single;
    final editor = widget.registry.byId(_editorId);
    if (editor != null && !editor.acceptsPath('file.$extension')) {
      setState(
        () => _validationError = strings.bindingEditorRejects(
          editor.displayName,
          extension,
        ),
      );
      return;
    }
    Navigator.of(context).pop((extension, _editorId));
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const ValueKey('editors.binding.dialog'),
      title: Text(strings.bindingAddTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('editors.binding.extension'),
              controller: _extension,
              autofocus: true,
              onChanged: (_) {
                if (_validationError != null) {
                  setState(() => _validationError = null);
                }
              },
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: strings.bindingExtensionLabel,
                hintText: strings.bindingExtensionHint,
                errorText: _validationError,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('editors.binding.editor'),
              initialValue: _editorId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: strings.bindingEditorLabel,
              ),
              items: _editorChoiceItems(
                widget.registry,
                strings,
                keyPrefix: 'editors.binding.choice',
                includeOtherPlatform: false,
              ),
              onChanged: (id) {
                if (id == null) return;
                setState(() {
                  _editorId = id;
                  _validationError = null;
                });
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('editors.binding.save'),
          onPressed: _save,
          child: Text(strings.save),
        ),
      ],
    );
  }
}
