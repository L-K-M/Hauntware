import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/editor_document.dart';
import 'package:seance_app/services/external_file_opener.dart';

import 'support/system_open_recorder.dart';

EditorRegistry _registry() => EditorRegistry(scheme: seanceEditors);

/// What settings.json held, decoded the way AppSettings decodes it.
EditorRegistry _stored(Object? editorRegistry, {Object? remoteFileEditor}) =>
    EditorRegistry.fromJson(
      editorRegistry,
      scheme: seanceEditors,
      migrations: [seanceLegacyEditorMigration(remoteFileEditor)],
    );

Map<String, Object?> _code({List<String> extensions = const []}) => {
  'id': '0b5c3f9e-2a41-4d7e-9c55-6f1e8a2d3b70',
  'displayName': 'Visual Studio Code',
  'platform': currentEditorHostPlatform!.name,
  'launchTarget': currentEditorHostPlatform == EditorHostPlatform.macos
      ? 'com.microsoft.VSCode'
      : currentEditorHostPlatform == EditorHostPlatform.windows
      ? r'C:\Program Files\Microsoft VS Code\Code.exe'
      : '/usr/bin/code',
  'acceptedExtensions': extensions,
};

void main() {
  // Every format Séance ever stored, as settings.json held it.
  group('stored registries stay readable', () {
    test('before the registry: remoteFileEditor bbedit becomes BBEdit as '
        'the default', () {
      final registry = _stored(null, remoteFileEditor: 'bbedit');

      expect(registry.defaultEditorId, seanceMigratedBbeditId);
      expect(registry.editors.single.displayName, 'BBEdit');
      expect(registry.editors.single.platform, EditorHostPlatform.macos);
      expect(registry.editors.single.launchTarget, 'com.barebones.bbedit');
      expect(registry.toJson()['version'], 2);
    });

    test('before the registry: remoteFileEditor systemDefault, or nothing, '
        'is the built-in editor', () {
      for (final legacy in ['systemDefault', null]) {
        final registry = _stored(null, remoteFileEditor: legacy);
        expect(registry.defaultEditorId, EditorRegistry.builtInId);
        expect(registry.editors, isEmpty);
      }
    });

    test('version 1: an untouched System default moves to the built-in '
        'editor, with or without its version key', () {
      for (final json in [
        {'version': 1, 'defaultEditorId': 'seance.system', 'editors': []},
        {'defaultEditorId': 'seance.system', 'editors': []},
      ]) {
        expect(_stored(json).defaultEditorId, EditorRegistry.builtInId);
      }
    });

    test('version 1: an editor default and its editors are kept', () {
      final registry = _stored({
        'version': 1,
        'defaultEditorId': _code()['id'],
        'editors': [
          _code(extensions: ['json', 'md']),
        ],
      }, remoteFileEditor: 'systemDefault');

      expect(registry.defaultEditorId, _code()['id']);
      expect(registry.editors.single.acceptedExtensions, ['json', 'md']);
    });

    test('version 2: a chosen System default is kept and the document '
        're-encodes with empty per-extension defaults', () {
      final stored = {
        'version': 2,
        'defaultEditorId': 'seance.system',
        'editors': [_code()],
      };

      final registry = _stored(stored, remoteFileEditor: 'systemDefault');

      expect(registry.defaultEditorId, EditorRegistry.systemDefaultId);
      expect(registry.extensionDefaults, isEmpty);
      expect(
        jsonEncode(registry.toJson()),
        jsonEncode({
          'version': 2,
          'defaultEditorId': 'seance.system',
          'extensionDefaults': <String, String>{},
          'editors': [_code()],
        }),
      );
    });

    test('version 2: the current editor stays the default for every '
        'extension', () {
      final registry = _stored({
        'version': 2,
        'defaultEditorId': _code()['id'],
        'editors': [_code()],
      });

      for (final path in ['/srv/a.txt', '/srv/b.json', '/srv/Makefile']) {
        expect(registry.effectiveDefaultFor(path), _code()['id']);
      }
    });
  });

  group('per-extension defaults', () {
    test('a binding wins over the default and survives a round trip', () {
      final registry = _stored({
        'version': 2,
        'defaultEditorId': 'seance.builtin',
        'editors': [_code()],
      })..setDefaultForExtension('md', _code()['id']! as String);

      final restored = _stored(registry.toJson());

      expect(restored.toJson()['extensionDefaults'], {'md': _code()['id']});
      expect(restored.effectiveDefaultFor('/srv/README.md'), _code()['id']);
      expect(
        restored.effectiveDefaultFor('/srv/notes.txt'),
        EditorRegistry.builtInId,
      );
    });

    test('a System default binding sends a listing straight to the system '
        'app, and limits nothing', () {
      final registry = _registry()
        ..setDefaultForExtension('log', EditorRegistry.systemDefaultId);

      expect(
        registry.effectiveDefaultForListing('/srv/app.log', 10),
        EditorRegistry.systemDefaultId,
      );
      expect(registry.checkoutMaximumBytes('/srv/app.log'), isNull);
      expect(registry.toJson()['extensionDefaults'], {'log': 'seance.system'});
    });
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
      scheme: seanceEditors,
      defaultEditorId: editor.id,
      editors: [editor],
    );

    final restored = registry.copy();

    expect(restored.defaultEditorId, editor.id);
    expect(restored.effectiveDefaultFor('/tmp/readme.txt'), editor.id);
    expect(
      restored.effectiveDefaultFor('/tmp/image.png'),
      EditorRegistry.builtInId,
    );
  });

  test('the built-in editor is the default on every platform', () {
    final registry = _registry();

    expect(registry.defaultEditorId, EditorRegistry.builtInId);
    expect(
      registry.effectiveDefaultFor('/tmp/readme.txt'),
      EditorRegistry.builtInId,
    );
  });

  test('a System default chosen since version 2 survives a round trip', () {
    final registry = EditorRegistry(
      scheme: seanceEditors,
      defaultEditorId: EditorRegistry.systemDefaultId,
    );

    final restored = registry.copy();

    expect(restored.defaultEditorId, EditorRegistry.systemDefaultId);
    expect(
      restored.effectiveDefaultFor('/tmp/readme.txt'),
      EditorRegistry.systemDefaultId,
    );
  });

  test('a listing over 4 MB already tells a default open where it goes', () {
    final registry = _registry();

    // Too big for the built-in editor, so on desktop the system app gets it.
    expect(
      registry.effectiveDefaultForListing(
        '/srv/big.log',
        builtInEditorMaximumBytes + 1,
      ),
      EditorRegistry.systemDefaultId,
    );
    expect(
      registry.effectiveDefaultForListing(
        '/srv/notes.txt',
        builtInEditorMaximumBytes,
      ),
      EditorRegistry.builtInId,
    );
    expect(
      registry.effectiveDefaultForListing('/srv/notes.txt', null),
      EditorRegistry.builtInId,
    );
  });

  test('a default open on desktop downloads a file of any size', () {
    final registry = _registry();

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
    final registry = _registry();

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
      await _registry().effectiveDefaultForCheckout('/srv/gone.txt', missing),
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
      scheme: seanceEditors,
      defaultEditorId: editor.id,
      editors: [editor],
    )..remove(editor.id);

    expect(registry.defaultEditorId, EditorRegistry.builtInId);
  });

  test('reserved built-in ids cannot be registered as external editors', () {
    for (final id in ['seance.builtin', 'seance.system']) {
      expect(
        () => _registry().put(
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
