import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/external_file_opener.dart';

void main() {
  test('normalizes extension filters and matches compound extensions', () {
    final extensions = normalizeEditorExtensions([
      ' .DART ',
      '*.tar.gz',
      'json',
      '.dart',
    ]);
    final editor = ExternalEditorDefinition(
      id: 'editor.test',
      displayName: 'Test Editor',
      platform: currentEditorHostPlatform!,
      launchTarget: '/test/editor',
      acceptedExtensions: extensions,
    );

    expect(extensions, ['dart', 'json', 'tar.gz']);
    expect(editor.acceptsPath('/tmp/FILE.DART'), isTrue);
    expect(editor.acceptsPath('/tmp/archive.TAR.GZ'), isTrue);
    expect(editor.acceptsPath('/tmp/no-extension'), isFalse);
  });

  test('empty extension filters accept every file', () {
    final editor = ExternalEditorDefinition(
      id: 'editor.all',
      displayName: 'Everything',
      platform: currentEditorHostPlatform!,
      launchTarget: '/test/editor',
    );

    expect(editor.acceptsPath('/tmp/.bashrc'), isTrue);
    expect(editor.acceptsPath('/tmp/no-extension'), isTrue);
  });

  test('registry round-trips and filters incompatible defaults', () {
    final editor = ExternalEditorDefinition(
      id: 'editor.test',
      displayName: 'Test Editor',
      platform: currentEditorHostPlatform!,
      launchTarget: '/test/editor',
      acceptedExtensions: const ['txt'],
    );
    final registry = EditorRegistry(
      defaultEditorId: editor.id,
      editors: [editor],
    );

    final restored = EditorRegistry.fromJson(registry.toJson());

    expect(restored.defaultEditorId, editor.id);
    expect(restored.effectiveDefaultFor('/tmp/readme.txt'), editor.id);
    expect(
      restored.effectiveDefaultFor('/tmp/image.png'),
      EditorRegistry.builtInId,
    );
  });

  test('the built-in editor is the default on every platform', () {
    final registry = EditorRegistry();

    expect(registry.defaultEditorId, EditorRegistry.builtInId);
    expect(
      registry.effectiveDefaultFor('/tmp/readme.txt'),
      EditorRegistry.builtInId,
    );
  });

  test('a version 1 System default moves to the built-in editor', () {
    for (final json in [
      {'version': 1, 'defaultEditorId': EditorRegistry.systemDefaultId},
      {'defaultEditorId': EditorRegistry.systemDefaultId},
    ]) {
      expect(
        EditorRegistry.fromJson(json).defaultEditorId,
        EditorRegistry.builtInId,
      );
    }
  });

  test('a System default chosen since version 2 survives a round trip', () {
    final registry = EditorRegistry(
      defaultEditorId: EditorRegistry.systemDefaultId,
    );

    final restored = EditorRegistry.fromJson(registry.toJson());

    expect(restored.defaultEditorId, EditorRegistry.systemDefaultId);
    expect(
      restored.effectiveDefaultFor('/tmp/readme.txt'),
      EditorRegistry.systemDefaultId,
    );
  });

  test('removing the default editor falls back to the built-in editor', () {
    final editor = ExternalEditorDefinition(
      id: 'editor.test',
      displayName: 'Test Editor',
      platform: currentEditorHostPlatform!,
      launchTarget: '/test/editor',
    );
    final registry = EditorRegistry(
      defaultEditorId: editor.id,
      editors: [editor],
    )..remove(editor.id);

    expect(registry.defaultEditorId, EditorRegistry.builtInId);
  });

  test('malformed editor entries do not discard valid entries', () {
    final registry = EditorRegistry.fromJson({
      'version': 1,
      'defaultEditorId': 'valid.editor',
      'editors': [
        {'id': 4},
        {
          'id': 'valid.editor',
          'displayName': 'Valid',
          'platform': currentEditorHostPlatform!.name,
          'launchTarget': '/test/editor',
          'acceptedExtensions': ['txt'],
        },
      ],
    });

    expect(registry.editors.single.id, 'valid.editor');
    expect(registry.defaultEditorId, 'valid.editor');
  });

  test('legacy BBEdit selection migrates without platform data loss', () {
    final registry = EditorRegistry.fromJson(null, legacyEditor: 'bbedit');

    expect(registry.defaultEditorId, EditorRegistry.migratedBbeditId);
    expect(registry.editors.single.launchTarget, 'com.barebones.bbedit');
  });

  test('invalid extension syntax is rejected', () {
    expect(
      () => normalizeEditorExtensions(['txt', '../sh']),
      throwsFormatException,
    );
  });

  test('registry rejects editor values that cannot round-trip', () {
    final registry = EditorRegistry();
    expect(
      () => registry.put(
        ExternalEditorDefinition(
          id: 'editor.invalid',
          displayName: List.filled(101, 'x').join(),
          platform: currentEditorHostPlatform!,
          launchTarget: '/test/editor',
        ),
      ),
      throwsFormatException,
    );
  });

  test('reserved built-in ids cannot be registered as external editors', () {
    for (final id in [
      EditorRegistry.builtInId,
      EditorRegistry.systemDefaultId,
    ]) {
      expect(
        () => EditorRegistry().put(
          ExternalEditorDefinition(
            id: id,
            displayName: 'Collision',
            platform: currentEditorHostPlatform!,
            launchTarget: '/test/editor',
          ),
        ),
        throwsFormatException,
      );
    }
  });
}
