import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_editors/ghost_editors.dart';
import 'package:ghost_editors/src/editor_fields.dart'
    show normalizeEditorExtensions;

/// Poltergeist's shape: System default, whole namespace reserved.
const _wholeNamespace = EditorRegistryScheme(
  namespace: 'poltergeist',
  formatVersion: 1,
  defaultSelector: EditorRegistry.systemDefaultId,
  idPolicy: ReservedEditorIds.wholeNamespace,
);

/// Séance's shape: built-in default, only the selectors reserved.
const _selectorsOnly = EditorRegistryScheme(
  namespace: 'seance',
  formatVersion: 2,
  defaultSelector: EditorRegistry.builtInId,
);

EditorRegistry _decode(Object? json) =>
    EditorRegistry.fromJson(json, scheme: _wholeNamespace);

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
  group('EditorRegistry', () {
    test('normalizes extension filters and matches compound extensions', () {
      final extensions = normalizeEditorExtensions([
        ' .DART ',
        '*.tar.gz',
        'json',
        '.dart',
      ]);
      final editor = _editor(acceptedExtensions: extensions);

      expect(extensions, ['dart', 'json', 'tar.gz']);
      expect(editor.acceptsPath('/tmp/FILE.DART'), isTrue);
      expect(editor.acceptsPath('/tmp/archive.TAR.GZ'), isTrue);
      expect(editor.acceptsPath('/tmp/no-extension'), isFalse);
    });

    test('empty extension filters accept every file', () {
      final editor = _editor(id: 'editor.all');

      expect(editor.acceptsPath('/tmp/.bashrc'), isTrue);
      expect(editor.acceptsPath('/tmp/no-extension'), isTrue);
    });

    test('registry round-trips and filters incompatible defaults', () {
      final editor = _editor(acceptedExtensions: const ['txt']);
      final registry = EditorRegistry(
        scheme: _wholeNamespace,
        defaultEditorId: editor.id,
        editors: [editor],
      );

      final restored = _decode(registry.toJson());

      expect(restored.defaultEditorId, editor.id);
      expect(restored.effectiveDefaultFor('/tmp/readme.txt'), editor.id);
      expect(
        restored.effectiveDefaultFor('/tmp/image.png'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('malformed editor entries do not discard valid entries', () {
      final registry = _decode({
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

    test('registry rejects editor values that cannot round-trip', () {
      final registry = EditorRegistry(scheme: _wholeNamespace);
      expect(
        () => registry.put(_editor(displayName: List.filled(101, 'x').join())),
        throwsFormatException,
      );
    });
  });

  group('reserved ids', () {
    test('the reserved selectors cannot be registered', () {
      for (final id in ['poltergeist.builtin', 'poltergeist.system']) {
        expect(
          () => EditorRegistry(scheme: _wholeNamespace).put(_editor(id: id)),
          throwsFormatException,
        );
      }
    });

    test('a whole-namespace scheme rejects every id in its namespace, '
        'so a synced definition cannot shadow a selector', () {
      expect(
        () => EditorRegistry(
          scheme: _wholeNamespace,
        ).put(_editor(id: 'poltergeist.notepad')),
        throwsFormatException,
      );
      // …and a persisted one is dropped at load, not honored.
      final registry = _decode({
        'editors': [
          {
            'id': 'poltergeist.shadow',
            'displayName': 'Shadow',
            'platform': currentEditorHostPlatform!.name,
            'launchTarget': '/test/editor',
          },
        ],
      });
      expect(registry.editors, isEmpty);
    });

    test('a persisted reserved-prefix default repairs to system', () {
      final registry = _decode({'defaultEditorId': 'poltergeist.anything'});
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
    });
  });

  group('per-extension bindings', () {
    test('a binding resolves ahead of the global default', () {
      final editor = _editor(acceptedExtensions: const ['txt']);
      final registry = EditorRegistry(
        scheme: _wholeNamespace,
        editors: [editor],
      )..setDefaultForExtension('txt', editor.id);

      expect(registry.effectiveDefaultFor('/tmp/readme.txt'), editor.id);
      expect(
        registry.effectiveDefaultFor('/tmp/other.md'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('the longest matching binding wins: tar.gz beats gz', () {
      final gzip = _editor(id: 'editor.gz', acceptedExtensions: ['gz']);
      final tar = _editor(id: 'editor.tar', acceptedExtensions: ['tar.gz']);
      final registry =
          EditorRegistry(scheme: _wholeNamespace, editors: [gzip, tar])
            ..setDefaultForExtension('gz', gzip.id)
            ..setDefaultForExtension('tar.gz', tar.id);

      expect(registry.effectiveDefaultFor('/tmp/archive.tar.gz'), tar.id);
      expect(registry.effectiveDefaultFor('/tmp/blob.gz'), gzip.id);
    });

    test('binding to an unknown editor refuses rather than dangling', () {
      expect(
        () => EditorRegistry(
          scheme: _wholeNamespace,
        ).setDefaultForExtension('txt', 'editor.missing'),
        throwsFormatException,
      );
    });

    test('bindings normalize like registry input', () {
      final editor = _editor();
      final registry = EditorRegistry(
        scheme: _wholeNamespace,
        editors: [editor],
      )..setDefaultForExtension(' .TXT ', editor.id);
      expect(registry.extensionDefaults, {'txt': editor.id});
      expect(registry.effectiveDefaultFor('/tmp/A.TXT'), editor.id);
    });

    test('reserved selectors are legal binding targets', () {
      final registry = EditorRegistry(scheme: _wholeNamespace)
        ..setDefaultForExtension('txt', EditorRegistry.builtInId);
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.builtInId,
      );
    });

    test('a bound system selector takes the same host fallback as the '
        'global default', () {
      final registry = EditorRegistry(scheme: _wholeNamespace)
        ..setDefaultForExtension('txt', EditorRegistry.systemDefaultId);
      addTearDown(() => debugEditorHostPlatform = null);

      // No desktop host (Android/iOS): the binding must degrade to the
      // built-in editor exactly like a system global default does —
      // an OS open hands another app a copy, not the checkout.
      debugEditorHostPlatform = () => null;
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.builtInId,
      );

      debugEditorHostPlatform = () => EditorHostPlatform.linux;
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('removing an editor strips its bindings and resets a default', () {
      final editor = _editor(acceptedExtensions: const ['txt']);
      final registry = EditorRegistry(
        scheme: _wholeNamespace,
        defaultEditorId: editor.id,
        editors: [editor],
      )..setDefaultForExtension('txt', editor.id);

      registry.remove(editor.id);

      expect(registry.defaultEditorId, EditorRegistry.systemDefaultId);
      expect(registry.extensionDefaults, isEmpty);
    });

    test('editing an editor’s extensions strips bindings it disclaimed', () {
      final editor = _editor(acceptedExtensions: const ['txt', 'md']);
      final registry =
          EditorRegistry(scheme: _wholeNamespace, editors: [editor])
            ..setDefaultForExtension('txt', editor.id)
            ..setDefaultForExtension('md', editor.id);

      registry.put(editor.copyWith(acceptedExtensions: const ['md']));

      expect(registry.extensionDefaults, {'md': editor.id});
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('a stale persisted binding drops at load instead of dangling', () {
      final registry = _decode({
        'extensionDefaults': {'txt': 'editor.gone'},
        'editors': const [],
      });
      expect(registry.extensionDefaults, isEmpty);
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('a binding to an other-platform editor falls back, and a '
        'persisted one still decodes for its own platform', () {
      final other = currentEditorHostPlatform == EditorHostPlatform.linux
          ? EditorHostPlatform.windows
          : EditorHostPlatform.linux;
      final target = other == EditorHostPlatform.windows
          ? 'C:\\Tools\\editor.exe'
          : '/test/editor';
      final registry = _decode({
        'extensionDefaults': {'txt': 'editor.other'},
        'editors': [
          {
            'id': 'editor.other',
            'displayName': 'Other OS',
            'platform': other.name,
            'launchTarget': target,
            'acceptedExtensions': ['txt'],
          },
        ],
      });
      // The binding decodes (the row exists for its platform), but
      // resolution here falls back — an unavailable editor never wins.
      expect(registry.extensionDefaults, {'txt': 'editor.other'});
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
      expect(registry.compatibleEditors('/tmp/a.txt'), isEmpty);
    });
  });

  group('caps', () {
    test('at most 64 editors register', () {
      final registry = EditorRegistry(
        scheme: _wholeNamespace,
        editors: [for (var i = 0; i < 64; i++) _editor(id: 'editor.$i')],
      );
      expect(() => registry.put(_editor(id: 'editor.65')), throwsStateError);
      // Replacing an existing id is not an add — still allowed at cap.
      registry.put(_editor(id: 'editor.0', displayName: 'Renamed'));
      expect(registry.editors, hasLength(64));
    });
  });

  group('compatibleEditors', () {
    test('filters by platform availability and declared extensions', () {
      final other = currentEditorHostPlatform == EditorHostPlatform.linux
          ? EditorHostPlatform.windows
          : EditorHostPlatform.linux;
      final registry = EditorRegistry(
        scheme: _wholeNamespace,
        editors: [
          _editor(id: 'editor.txt', acceptedExtensions: ['txt']),
          _editor(id: 'editor.all'),
          _editor(id: 'editor.md', acceptedExtensions: ['md']),
          _editor(
            id: 'editor.other',
            platform: other,
            launchTarget: other == EditorHostPlatform.windows
                ? 'C:\\Tools\\editor.exe'
                : '/test/editor',
          ),
        ],
      );

      expect(registry.compatibleEditors('/tmp/a.txt').map((e) => e.id), [
        'editor.txt',
        'editor.all',
      ]);
    });
  });

  group('schemes', () {
    test('selectors persist under the namespace and decode back', () {
      final editor = _editor(acceptedExtensions: const ['md']);
      final registry =
          EditorRegistry(scheme: _wholeNamespace, editors: [editor])
            ..setDefaultForExtension('txt', EditorRegistry.builtInId)
            ..setDefaultForExtension('md', editor.id);

      final json = registry.toJson();

      expect(json['version'], 1);
      expect(json['defaultEditorId'], 'poltergeist.system');
      expect(json['extensionDefaults'], {
        'txt': 'poltergeist.builtin',
        'md': editor.id,
      });
      final restored = _decode(json);
      expect(restored.defaultEditorId, EditorRegistry.systemDefaultId);
      expect(restored.extensionDefaults, {
        'txt': EditorRegistry.builtInId,
        'md': editor.id,
      });
    });

    test('a built-in scheme defaults to and falls back on the built-in '
        'editor', () {
      final editor = _editor(acceptedExtensions: const ['txt']);
      final registry = EditorRegistry(
        scheme: _selectorsOnly,
        defaultEditorId: editor.id,
        editors: [editor],
      );

      expect(
        EditorRegistry(scheme: _selectorsOnly).defaultEditorId,
        EditorRegistry.builtInId,
      );
      expect(
        registry.effectiveDefaultFor('/tmp/image.png'),
        EditorRegistry.builtInId,
      );
      registry.remove(editor.id);
      expect(registry.defaultEditorId, EditorRegistry.builtInId);
      expect(registry.toJson()['defaultEditorId'], 'seance.builtin');
    });

    test('a selectors-only scheme keeps other ids in its namespace', () {
      final registry = EditorRegistry(scheme: _selectorsOnly)
        ..put(_editor(id: 'seance.notepad'));
      expect(registry.editors.single.id, 'seance.notepad');
      expect(
        () => registry.put(_editor(id: 'seance.system')),
        throwsFormatException,
      );
    });

    test('another app’s selector ids are ordinary editor ids', () {
      final registry = EditorRegistry.fromJson({
        'defaultEditorId': 'poltergeist.system',
      }, scheme: _selectorsOnly);
      expect(registry.defaultEditorId, EditorRegistry.builtInId);
    });

    test('scheme migrations run in order, then call-site migrations', () {
      final calls = <String>[];
      final scheme = EditorRegistryScheme(
        namespace: 'app',
        formatVersion: 3,
        defaultSelector: EditorRegistry.builtInId,
        migrations: [
          (stored) {
            calls.add('scheme');
            return stored ?? {'defaultEditorId': 'app.system'};
          },
        ],
      );

      final registry = EditorRegistry.fromJson(
        null,
        scheme: scheme,
        migrations: [
          (stored) {
            calls.add('site:${(stored as Map)['defaultEditorId']}');
            return stored;
          },
        ],
      );

      expect(calls, ['scheme', 'site:app.system']);
      expect(registry.defaultEditorId, EditorRegistry.systemDefaultId);
      expect(registry.toJson()['version'], 3);
    });

    test('setDefault refuses an unresolvable id', () {
      final registry = EditorRegistry(scheme: _selectorsOnly);
      expect(
        () => registry.setDefault('editor.missing'),
        throwsFormatException,
      );
      registry.setDefault(EditorRegistry.systemDefaultId);
      expect(registry.defaultEditorId, EditorRegistry.systemDefaultId);
    });

    test('a null editor clears a binding', () {
      final registry = EditorRegistry(scheme: _selectorsOnly)
        ..setDefaultForExtension('txt', EditorRegistry.systemDefaultId)
        ..setDefaultForExtension('.TXT', null);
      expect(registry.extensionDefaults, isEmpty);
    });

    test('copy is independent', () {
      final registry = EditorRegistry(scheme: _selectorsOnly);
      final copy = registry.copy()..setDefault(EditorRegistry.systemDefaultId);
      expect(registry.defaultEditorId, EditorRegistry.builtInId);
      expect(copy.scheme, same(_selectorsOnly));
    });
  });
}
