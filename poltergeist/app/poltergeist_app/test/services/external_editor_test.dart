// Poltergeist's side of the shared ghost_editors registry (whose own
// suite covers validation, bindings and resolution): the stored format
// stays readable, persistence rides the shared settings.json through
// EditorRegistryController, and the System default never executes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/editor_registry_controller.dart';
import 'package:poltergeist_app/services/external_file_opener.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Records what would reach `open`/`xdg-open`/`explorer.exe`.
final class _RecordingSystemOpener implements LocalFileOpener {
  final opens = <String>[];

  @override
  Future<void> open(String path) async => opens.add(path);
}

EditorRegistry _decode(Object? json) =>
    EditorRegistry.fromJson(json, scheme: poltergeistEditors);

ExternalEditorDefinition _editor({
  String id = 'editor.test',
  String displayName = 'Test Editor',
  EditorHostPlatform? platform,
  String launchTarget = '/test/editor',
  List<String> acceptedExtensions = const [],
}) => ExternalEditorDefinition(
  id: id,
  displayName: displayName,
  platform: platform ?? currentEditorHostPlatform!,
  launchTarget: launchTarget,
  acceptedExtensions: acceptedExtensions,
);

void main() {
  // Every Poltergeist build wrote this one format (version 1, the
  // `poltergeist.` selectors, extensionDefaults beside the editors); the
  // samples are documents as settings.json held them.
  group('stored registries stay readable', () {
    test('an untouched install has no document and boots System '
        'default', () {
      final registry = _decode(null);
      expect(registry.defaultEditorId, EditorRegistry.systemDefaultId);
      expect(registry.editors, isEmpty);
      expect(registry.extensionDefaults, isEmpty);
    });

    test('a version 1 document with editors, a selector default and '
        'bindings decodes and re-encodes byte for byte', () {
      final stored = {
        'version': 1,
        'defaultEditorId': 'poltergeist.builtin',
        'extensionDefaults': {
          'md': '3f2c1a9e-5b7d-4e2f-9a1c-0d8e7f6a5b4c',
          'log': 'poltergeist.system',
        },
        'editors': [
          {
            'id': '3f2c1a9e-5b7d-4e2f-9a1c-0d8e7f6a5b4c',
            'displayName': 'Typora',
            'platform': 'macos',
            'launchTarget': 'abnerworks.Typora',
            'acceptedExtensions': ['markdown', 'md'],
          },
          {
            'id': '8a7b6c5d-4e3f-4a2b-8c1d-0e9f8a7b6c5d',
            'displayName': 'Notepad++',
            'platform': 'windows',
            'launchTarget': r'C:\Program Files\Notepad++\notepad++.exe',
            'acceptedExtensions': <String>[],
          },
        ],
      };

      final registry = _decode(stored);

      expect(registry.defaultEditorId, EditorRegistry.builtInId);
      expect(registry.editors.map((editor) => editor.displayName), [
        'Typora',
        'Notepad++',
      ]);
      expect(registry.extensionDefaults, {
        'md': '3f2c1a9e-5b7d-4e2f-9a1c-0d8e7f6a5b4c',
        'log': EditorRegistry.systemDefaultId,
      });
      expect(jsonEncode(registry.toJson()), jsonEncode(stored));
    });

    test('a version 1 document with an editor default keeps it', () {
      final registry = _decode({
        'version': 1,
        'defaultEditorId': 'editor.code',
        'extensionDefaults': <String, String>{},
        'editors': [
          {
            'id': 'editor.code',
            'displayName': 'Code',
            'platform': 'linux',
            'launchTarget': '/usr/bin/code',
            'acceptedExtensions': <String>[],
          },
        ],
      });
      expect(registry.defaultEditorId, 'editor.code');
      expect(registry.toJson()['defaultEditorId'], 'editor.code');
    });
  });

  group('EditorRegistryController persistence (06 §4.1)', () {
    late Directory tempDir;
    late SettingsStore store;
    late EditorRegistryController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pg-editors-');
      store = SettingsStore(path: p.join(tempDir.path, 'settings.json'));
      controller = EditorRegistryController(store: store);
      await controller.load();
    });

    tearDown(() async {
      await store.flush();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('a picked editor and a remember-choice binding survive a '
        'fresh load', () async {
      final picked = _editor(
        id: 'editor.picked',
        displayName: 'Picked',
        launchTarget: '/usr/bin/picked',
      );
      await controller.register(picked);
      await controller.setExtensionDefault('txt', picked.id);
      await store.flush();

      // A fresh store instance forces the read through disk — reusing
      // the writer's in-memory values would not prove the round-trip.
      final reloaded = EditorRegistryController(
        store: SettingsStore(path: p.join(tempDir.path, 'settings.json')),
      );
      await reloaded.load();

      expect(reloaded.registry.byId('editor.picked'), isNotNull);
      expect(
        reloaded.registry.effectiveDefaultFor('/tmp/a.txt'),
        'editor.picked',
      );
      // The document lives under its own settings.json key — the same
      // file every other settings slice shares, never a second file.
      expect(
        File(p.join(tempDir.path, 'settings.json')).readAsStringSync(),
        contains('editorRegistry'),
      );
    });

    test('a malformed persisted document boots the default registry', () {
      expect(
        _decode('not a map').defaultEditorId,
        EditorRegistry.systemDefaultId,
      );
      expect(_decode(42).editors, isEmpty);
    });

    test('a malformed extensionDefaults key drops instead of '
        'failing the load', () {
      final registry = _decode({
        'extensionDefaults': {
          'bad/key': 'poltergeist.system',
          'txt': 'poltergeist.builtin',
        },
      });
      expect(registry.extensionDefaults, {'txt': EditorRegistry.builtInId});
    });

    test('register normalizes stored extensions so matching and the '
        'binding strip work in-session', () async {
      final editor = _editor(id: 'editor.upper', acceptedExtensions: ['.TXT']);
      await controller.register(editor);

      final stored = controller.registry.byId('editor.upper')!;
      expect(stored.acceptsPath('note.txt'), isTrue);

      await controller.setExtensionDefault('txt', 'editor.upper');
      // Re-put (the §8 edit path) must not strip the binding it honors.
      await controller.register(stored);
      expect(controller.registry.extensionDefaults['txt'], 'editor.upper');
    });

    test('setDefault refuses an unresolvable id', () async {
      await expectLater(
        controller.setDefault('poltergeist.bogus'),
        throwsFormatException,
      );
      await expectLater(
        controller.setDefault('editor.missing'),
        throwsFormatException,
      );
      expect(
        controller.registry.defaultEditorId,
        EditorRegistry.systemDefaultId,
      );
    });

    test('a failed write notifies listeners of the rollback', () async {
      final failing = SettingsStore(
        path: p.join(tempDir.path, 'notify.json'),
        atomicWriter: (target, contents, {restrictToOwner = false}) =>
            Future.error(StateError('disk full')),
      );
      final failingController = EditorRegistryController(store: failing);
      await failingController.load();
      var notified = 0;
      failingController.addListener(() => notified++);

      await expectLater(
        failingController.register(_editor(id: 'editor.rolled')),
        throwsStateError,
      );

      expect(notified, greaterThan(0));
      expect(failingController.registry.byId('editor.rolled'), isNull);
    });

    test(
      'a failed settings write restores the pre-mutation registry',
      () async {
        final failing = SettingsStore(
          path: p.join(tempDir.path, 'other.json'),
          atomicWriter: (target, contents, {restrictToOwner = false}) =>
              Future.error(StateError('disk full')),
        );
        final failingController = EditorRegistryController(store: failing);
        await failingController.load();

        await expectLater(
          failingController.register(_editor(id: 'editor.lost')),
          throwsStateError,
        );
        // The in-memory registry rolled back with the write — no surface
        // resolves a default the disk does not hold (06 §8's discipline).
        expect(failingController.registry.byId('editor.lost'), isNull);
      },
    );

    test('an older failed write cannot roll back a newer mutation', () async {
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      var writeCount = 0;
      final racingStore = SettingsStore(
        path: p.join(tempDir.path, 'racing.json'),
        atomicWriter: (target, contents, {restrictToOwner = false}) async {
          writeCount++;
          if (writeCount != 1) return;

          firstWriteStarted.complete();
          await releaseFirstWrite.future;
          throw StateError('first write failed');
        },
      );
      final racingController = EditorRegistryController(store: racingStore);
      await racingController.load();
      final editor = _editor(id: 'editor.concurrent');

      final register = racingController.register(editor);
      await firstWriteStarted.future;
      final setDefault = racingController.setDefault(editor.id);
      releaseFirstWrite.complete();

      await expectLater(register, throwsStateError);
      await setDefault;

      expect(racingController.registry.byId(editor.id), same(editor));
      expect(racingController.registry.defaultEditorId, editor.id);
    });

    test('removing an editor persists the stripped bindings', () async {
      final editor = _editor(id: 'editor.gone', acceptedExtensions: ['txt']);
      await controller.register(editor);
      await controller.setExtensionDefault('txt', editor.id);
      await controller.remove(editor.id);
      await store.flush();

      final reloaded = EditorRegistryController(
        store: SettingsStore(path: p.join(tempDir.path, 'settings.json')),
      );
      await reloaded.load();

      expect(reloaded.registry.editors, isEmpty);
      expect(reloaded.registry.extensionDefaults, isEmpty);
    });
  });

  group('openSystemDefault never executes (06 §5.3)', () {
    late _RecordingSystemOpener systemOpener;
    late ExternalFileOpener opener;

    setUp(() {
      systemOpener = _RecordingSystemOpener();
      opener = ExternalFileOpener(systemOpener: systemOpener);
      addTearDown(() => debugEditorHostPlatform = null);
    });

    Future<void> expectRefused(String path) async {
      await expectLater(
        opener.openSystemDefault(path),
        throwsA(
          isA<ExecutableLaunchRefused>().having((e) => e.path, 'path', path),
        ),
      );
    }

    test('Windows refuses Script Host and program types', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.windows;
      await expectRefused(r'C:\checkouts\0a\app.js');
      await expectRefused(r'C:\checkouts\0b\setup.EXE');
      await expectRefused(r'C:\checkouts\0c\invoice.pdf.lnk');
      expect(systemOpener.opens, isEmpty);

      await opener.openSystemDefault(r'C:\checkouts\0d\notes.txt');
      await opener.openSystemDefault(r'C:\checkouts\0e\report.pdf');
      expect(systemOpener.opens, hasLength(2));
    });

    test('macOS refuses its launch types and opens documents', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.macos;
      await expectRefused('/checkouts/0a/run.command');
      await expectRefused('/checkouts/0b/Evil.app');
      await opener.openSystemDefault('/checkouts/0c/app.js');
      expect(systemOpener.opens, ['/checkouts/0c/app.js']);
    });

    test('a host without launch rules refuses every desktop type', () async {
      debugEditorHostPlatform = () => null;
      await expectRefused('/checkouts/0a/app.js');
      await expectRefused('/checkouts/0b/run.command');
      await expectRefused('/checkouts/0c/app.desktop');
      expect(systemOpener.opens, isEmpty);
    });
  });
}
