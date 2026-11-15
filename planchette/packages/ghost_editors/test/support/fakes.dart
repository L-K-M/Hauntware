import 'package:flutter/foundation.dart';
import 'package:ghost_editors/ghost_editors.dart';

const testScheme = EditorRegistryScheme(
  namespace: 'test',
  formatVersion: 1,
  defaultSelector: EditorRegistry.systemDefaultId,
);

final testStrings = GhostEditorsStrings(
  defaultLabel: 'Default editor',
  builtInOption: 'Built-in text editor',
  systemDefaultOption: 'System default',
  otherPlatformName: (name) => '$name (another platform)',
  listLabel: 'External editors',
  emptyState: 'No external editors',
  desktopOnly: 'Desktop only',
  addLabel: 'Add editor',
  pickDialogTitle: 'Choose an editor application',
  addTitle: 'Add external editor',
  editTitle: 'Edit external editor',
  editLabel: 'Edit…',
  removeLabel: 'Remove',
  removeTitle: (name) => 'Remove $name?',
  removeBody: 'Removed from settings only.',
  removeDefaultBody: 'Resets the default.',
  nameFieldLabel: 'Display name',
  extensionsFieldLabel: 'Accepted file extensions (optional)',
  extensionsFieldHint: 'dart, json',
  extensionsFieldHelper: 'Blank accepts every file.',
  cancel: 'Cancel',
  save: 'Save',
  bindingsLabel: 'Per-extension defaults',
  bindingsEmpty: 'No per-extension defaults',
  bindingAddLabel: 'Add extension default',
  bindingAddTitle: 'Open an extension with',
  bindingExtensionLabel: 'Extension',
  bindingExtensionHint: 'txt',
  bindingEditorLabel: 'Open with',
  bindingExtensionInvalid: 'Enter one extension',
  bindingEditorRejects: (name, extension) => '$name does not open .$extension',
);

/// A registry model whose mutations land in memory and are recorded.
final class FakeEditors extends ChangeNotifier implements EditorRegistryModel {
  FakeEditors([Iterable<ExternalEditorDefinition> editors = const []])
    : registry = EditorRegistry(scheme: testScheme, editors: editors);

  @override
  EditorRegistry registry;

  final calls = <String>[];

  /// Makes the next mutation throw this instead.
  Object? failNext;

  void _check() {
    final failure = failNext;
    failNext = null;
    if (failure != null) throw failure;
  }

  @override
  Future<void> register(ExternalEditorDefinition editor) async {
    _check();
    calls.add('register');
    registry.put(editor);
    notifyListeners();
  }

  @override
  Future<void> remove(String id) async {
    _check();
    calls.add('remove');
    registry.remove(id);
    notifyListeners();
  }

  @override
  Future<void> setDefault(String id) async {
    _check();
    calls.add('setDefault');
    registry.setDefault(id);
    notifyListeners();
  }

  @override
  Future<void> setExtensionDefault(String extension, String? editorId) async {
    _check();
    calls.add('setExtensionDefault:$extension=$editorId');
    registry.setDefaultForExtension(extension, editorId);
    notifyListeners();
  }
}

ExternalEditorDefinition testEditor({
  String id = 'editor.test',
  String displayName = 'Test Editor',
  EditorHostPlatform? platform,
  String launchTarget = '/test/editor',
  List<String> acceptedExtensions = const ['dart'],
}) => ExternalEditorDefinition(
  id: id,
  displayName: displayName,
  platform: platform ?? currentEditorHostPlatform!,
  launchTarget: launchTarget,
  acceptedExtensions: acceptedExtensions,
);
