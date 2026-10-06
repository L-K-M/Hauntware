import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/editor_document.dart';
import 'package:seance_app/services/external_file_opener.dart';

import 'support/system_open_recorder.dart';

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

  test('a default open on desktop downloads a file of any size', () {
    final registry = EditorRegistry();

    expect(registry.checkoutMaximumBytes('/srv/big.log'), isNull);
    expect(
      registry.checkoutMaximumBytes(
        '/srv/big.log',
        editorId: EditorRegistry.builtInId,
      ),
      builtInEditorMaximumBytes,
    );
  });

  test('a default open on desktop gives the system app what the built-in '
      'editor refuses', () async {
    final directory = await Directory.systemTemp.createTemp('seance-open-');
    addTearDown(() => directory.delete(recursive: true));
    final text = File('${directory.path}/notes.txt')
      ..writeAsStringSync('hello\n');
    final binary = File('${directory.path}/photo.png')
      ..writeAsBytesSync([0, 1, 2]);
    final registry = EditorRegistry();

    expect(
      await registry.effectiveDefaultForCheckout('/srv/notes.txt', text),
      EditorRegistry.builtInId,
    );
    expect(
      await registry.effectiveDefaultForCheckout('/srv/photo.png', binary),
      EditorRegistry.systemDefaultId,
    );
  });

  test('a missing checkout stays with the built-in editor', () async {
    final directory = await Directory.systemTemp.createTemp('seance-open-');
    addTearDown(() => directory.delete(recursive: true));
    final missing = File('${directory.path}/gone.txt');

    expect(
      await EditorRegistry().effectiveDefaultForCheckout(
        '/srv/gone.txt',
        missing,
      ),
      EditorRegistry.builtInId,
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

  group('the system default app never runs a remote program', () {
    // What runs is decided by the host: each one gets its own launcher.
    final program = switch (currentEditorHostPlatform!) {
      EditorHostPlatform.linux => 'app.desktop',
      EditorHostPlatform.macos => 'run.command',
      EditorHostPlatform.windows => 'payload.exe',
    };

    test('a program this host would run never reaches the OS', () async {
      final opened = recordSystemOpens();

      await expectLater(
        const ExternalFileOpener().openSystemDefault('/srv/checkout/$program'),
        throwsA(isA<ExecutableLaunchRefused>()),
      );
      expect(opened, isEmpty);
      expect(const ExternalFileOpener().launchWouldExecute(program), isTrue);
    });

    test('a document still opens', () async {
      final opened = recordSystemOpens();

      await const ExternalFileOpener().openSystemDefault('/srv/report.pdf');

      expect(opened, ['/srv/report.pdf']);
    });

    test('the refusal names the file in a plain sentence', () {
      expect(
        '${const ExecutableLaunchRefused('/srv/checkout/app.desktop')}',
        '“app.desktop” could run as a program on this computer, so it '
            "wasn't opened with the system default app.",
      );
    });
  });
}
