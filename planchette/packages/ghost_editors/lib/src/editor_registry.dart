import 'package:flutter/foundation.dart';

import 'editor_definition.dart';
import 'editor_fields.dart';

/// Rewrites a persisted registry document before it is decoded: the
/// stored value as read (any JSON value, or null when nothing is stored)
/// in, the value to decode out. A migration returns [stored] unchanged
/// when it does not apply.
typedef EditorRegistryMigration = Object? Function(Object? stored);

/// What makes one app's registry its own: the id namespace its reserved
/// selectors persist under, the format version it writes, the selector a
/// fresh or repaired registry defaults to, and the migrations that keep
/// every document it ever wrote readable.
///
/// Example: Poltergeist persists `poltergeist.system` and Séance
/// `seance.system`; both decode to [EditorRegistry.systemDefaultId].
@immutable
final class EditorRegistryScheme {
  const EditorRegistryScheme({
    required this.namespace,
    required this.formatVersion,
    required this.defaultSelector,
    this.idPolicy = ReservedEditorIds.selectorsOnly,
    this.migrations = const [],
  }) : assert(
         defaultSelector == EditorRegistry.systemDefaultId ||
             defaultSelector == EditorRegistry.builtInId,
       );

  /// The prefix of the persisted reserved selectors, without the dot.
  final String namespace;

  /// The `version` the registry document is written with.
  final int formatVersion;

  /// [EditorRegistry.systemDefaultId] or [EditorRegistry.builtInId]: the
  /// default of a fresh registry, and where a default that names a missing
  /// or unusable editor resolves.
  final String defaultSelector;

  /// Which stored editor ids the namespace takes away from editors.
  final ReservedEditorIds idPolicy;

  /// Applied in order to every document before it is decoded.
  final List<EditorRegistryMigration> migrations;

  String get _persistedSystemDefaultId => '$namespace.system';
  String get _persistedBuiltInId => '$namespace.builtin';

  /// Whether an editor may not use [id]: it names a reserved selector, or
  /// falls in the namespace an [ReservedEditorIds.wholeNamespace] app keeps.
  bool isReservedEditorId(String id) =>
      id == _persistedSystemDefaultId ||
      id == _persistedBuiltInId ||
      (idPolicy == ReservedEditorIds.wholeNamespace &&
          id.startsWith('$namespace.'));

  /// The in-memory form of a persisted editor id or selector.
  String _decodeTarget(String stored) {
    if (stored == _persistedSystemDefaultId) {
      return EditorRegistry.systemDefaultId;
    }
    if (stored == _persistedBuiltInId) return EditorRegistry.builtInId;
    return stored;
  }

  String _encodeTarget(String id) => switch (id) {
    EditorRegistry.systemDefaultId => _persistedSystemDefaultId,
    EditorRegistry.builtInId => _persistedBuiltInId,
    _ => id,
  };
}

/// How much of an app's id namespace is reserved for its selectors.
enum ReservedEditorIds {
  /// Only `<namespace>.system` and `<namespace>.builtin`.
  selectorsOnly,

  /// Every `<namespace>.*` id, so a synced or hand-edited definition can
  /// never shadow a selector the app adds later.
  wholeNamespace,
}

/// The configured external editors, the global default and the
/// per-extension defaults of one app.
///
/// Selectors are app-neutral in memory ([systemDefaultId], [builtInId]);
/// the [scheme] maps them to the app's persisted ids in [toJson] and
/// [EditorRegistry.fromJson].
class EditorRegistry {
  /// The OS default application. Not a valid editor id, so no stored
  /// editor can collide with it.
  static const systemDefaultId = '<system>';

  /// The app's built-in text editor.
  static const builtInId = '<builtin>';

  static const _maximumEditors = 64;

  final EditorRegistryScheme scheme;
  String defaultEditorId;
  final List<ExternalEditorDefinition> editors;

  /// Per-extension defaults: normalized extension (`txt`, or a compound
  /// `tar.gz`) to an editor id or a selector. A binding resolves in
  /// [effectiveDefaultFor] only while its target still exists, is
  /// available on this platform and accepts the extension; [put] and
  /// [remove] strip bindings an edit or removal orphans.
  final Map<String, String> extensionDefaults;

  EditorRegistry({
    required this.scheme,
    String? defaultEditorId,
    Iterable<ExternalEditorDefinition> editors = const [],
    Map<String, String> extensionDefaults = const {},
  }) : defaultEditorId = defaultEditorId ?? scheme.defaultSelector,
       editors = List.of(editors),
       extensionDefaults = Map.of(extensionDefaults) {
    _repairDefault();
  }

  /// Decodes a persisted document after [scheme]'s migrations and then
  /// [migrations] (call-site ones, such as a migration from a sibling
  /// settings key). Tolerant: a malformed document is the default
  /// registry, a malformed editor or binding drops alone.
  factory EditorRegistry.fromJson(
    Object? value, {
    required EditorRegistryScheme scheme,
    Iterable<EditorRegistryMigration> migrations = const [],
  }) {
    for (final migrate in [...scheme.migrations, ...migrations]) {
      value = migrate(value);
    }
    if (value is! Map) return EditorRegistry(scheme: scheme);

    final json = value.cast<Object?, Object?>();
    final editors = <ExternalEditorDefinition>[];
    final ids = <String>{};
    final entries = json['editors'];
    if (entries is List) {
      for (final entry in entries) {
        if (editors.length >= _maximumEditors) break;
        if (entry is! Map) continue;
        try {
          final editor = ExternalEditorDefinition.fromJson(
            entry.cast<String, dynamic>(),
          );
          if (scheme.isReservedEditorId(editor.id)) continue;
          if (ids.add(editor.id)) editors.add(editor);
        } on Object {
          // Keep other valid entries when one persisted app is malformed.
        }
      }
    }

    // Keys normalize like any extension input; values must name a loaded
    // editor or a selector, so a binding whose target vanished between
    // writes drops rather than dangles.
    final extensionDefaults = <String, String>{};
    final storedDefaults = json['extensionDefaults'];
    if (storedDefaults is Map) {
      for (final entry in storedDefaults.entries) {
        final key = entry.key;
        final stored = entry.value;
        if (key is! String || stored is! String) continue;
        final target = scheme._decodeTarget(stored);
        if (!_isSelector(target) && !ids.contains(target)) continue;
        final List<String> normalized;
        try {
          normalized = normalizeEditorExtensions([key]);
        } on FormatException {
          continue;
        }
        if (normalized.isEmpty) continue;
        extensionDefaults[normalized.single] = target;
      }
    }

    final storedDefault = json['defaultEditorId'];
    return EditorRegistry(
      scheme: scheme,
      defaultEditorId: storedDefault is String
          ? scheme._decodeTarget(storedDefault)
          : null,
      editors: editors,
      extensionDefaults: extensionDefaults,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': scheme.formatVersion,
    'defaultEditorId': scheme._encodeTarget(defaultEditorId),
    'extensionDefaults': {
      for (final MapEntry(:key, :value) in extensionDefaults.entries)
        key: scheme._encodeTarget(value),
    },
    'editors': editors.map((editor) => editor.toJson()).toList(),
  };

  /// An independent copy, as a decoded round trip of this registry.
  EditorRegistry copy() => EditorRegistry.fromJson(toJson(), scheme: scheme);

  ExternalEditorDefinition? byId(String id) {
    for (final editor in editors) {
      if (editor.id == id) return editor;
    }
    return null;
  }

  List<ExternalEditorDefinition> compatibleEditors(String path) => [
    for (final editor in editors)
      if (editor.isAvailableOnCurrentPlatform && editor.acceptsPath(path))
        editor,
  ];

  /// Sets the global default to [id], a selector or a registered editor.
  /// Throws a [FormatException] for an id that names neither, rather than
  /// persisting a dangling default.
  void setDefault(String id) {
    if (!_isSelector(id) && byId(id) == null) {
      throw FormatException('Unknown editor id: $id');
    }
    defaultEditorId = id;
  }

  /// Binds [extension] to [editorId], an editor id or a selector; a null
  /// [editorId], or an extension that normalizes to nothing, clears the
  /// binding. `.TXT`, `*.txt` and `txt` are one binding. Binding to a
  /// missing editor throws a [FormatException] rather than persisting a
  /// dangling id.
  void setDefaultForExtension(String extension, String? editorId) {
    final normalized = normalizeEditorExtensions([extension]);
    if (normalized.isEmpty) {
      extensionDefaults.remove(extension.trim().toLowerCase());
      return;
    }
    if (editorId == null) {
      extensionDefaults.remove(normalized.single);
      return;
    }
    if (!_isSelector(editorId) && byId(editorId) == null) {
      throw FormatException('Unknown editor id: $editorId');
    }
    extensionDefaults[normalized.single] = editorId;
  }

  /// The editor id a default open launches for [path]: the per-extension
  /// binding first, validated at read so a binding whose editor vanished
  /// or disclaimed the extension falls through, then the global default,
  /// then the scheme's [EditorRegistryScheme.defaultSelector].
  String effectiveDefaultFor(String path) {
    final bound = _extensionDefaultFor(path);
    if (bound != null) return bound;
    return _resolvedSelectorFor(path, defaultEditorId);
  }

  /// The longest matching binding wins (`tar.gz` beats `gz`), matching
  /// [ExternalEditorDefinition.acceptsPath]'s compound extensions.
  String? _extensionDefaultFor(String path) {
    if (extensionDefaults.isEmpty) return null;
    final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
    String? match;
    var matchLength = 0;
    for (final extension in extensionDefaults.keys) {
      if (extension.length <= matchLength) continue;
      if (!name.endsWith('.$extension')) continue;
      match = extension;
      matchLength = extension.length;
    }
    if (match == null) return null;

    final target = extensionDefaults[match]!;
    // Selectors resolve like the global default, so a synced System
    // default binding still degrades to the built-in editor on mobile.
    if (_isSelector(target)) return _resolvedSelectorFor(path, target);
    final editor = byId(target);
    if (editor == null ||
        !editor.isAvailableOnCurrentPlatform ||
        !editor.acceptsPath(path)) {
      return null;
    }
    return target;
  }

  String _resolvedSelectorFor(String path, String selected) {
    if (selected == builtInId) return selected;
    // Mobile open/share APIs generally hand another app a copy rather
    // than an in-place editable checkout. Keep remote editing reliable
    // there.
    if (selected == systemDefaultId) {
      return currentEditorHostPlatform == null ? builtInId : systemDefaultId;
    }
    final editor = byId(selected);
    if (editor == null ||
        !editor.isAvailableOnCurrentPlatform ||
        !editor.acceptsPath(path)) {
      return _resolvedSelectorFor(path, scheme.defaultSelector);
    }
    return editor.id;
  }

  /// Adds or replaces [editor]. Throws a [FormatException] for an invalid
  /// or reserved definition and a [StateError] past 64 editors.
  void put(ExternalEditorDefinition editor) {
    validateEditorId(editor.id);
    if (scheme.isReservedEditorId(editor.id)) {
      throw const FormatException('Editor id is reserved');
    }
    validateEditorDisplayName(editor.displayName);
    validateEditorTarget(editor.launchTarget, editor.platform);
    // Store the normalized form: acceptsPath suffix-matches lowercase, so
    // an unnormalized list ('.TXT', '*.txt') would never match and the
    // strip below would drop the editor's valid bindings. The copy is
    // skipped when already normalized, so callers keep their instance.
    final normalizedExtensions = normalizeEditorExtensions(
      editor.acceptedExtensions,
    );
    if (!listEquals(normalizedExtensions, editor.acceptedExtensions)) {
      editor = editor.copyWith(acceptedExtensions: normalizedExtensions);
    }
    final index = editors.indexWhere((item) => item.id == editor.id);
    if (index < 0) {
      if (editors.length >= _maximumEditors) {
        throw StateError(
          'At most $_maximumEditors external editors can be configured.',
        );
      }
      editors.add(editor);
    } else {
      editors[index] = editor;
    }
    // An edit that narrows the accepted extensions strips the bindings the
    // editor no longer honors.
    extensionDefaults.removeWhere(
      (extension, target) =>
          target == editor.id && !editor.acceptsPath('file.$extension'),
    );
  }

  /// Removes the editor [id], resetting a default and stripping bindings
  /// that named it.
  void remove(String id) {
    editors.removeWhere((editor) => editor.id == id);
    if (defaultEditorId == id) defaultEditorId = scheme.defaultSelector;
    extensionDefaults.removeWhere((_, target) => target == id);
  }

  void _repairDefault() {
    if (_isSelector(defaultEditorId)) return;
    if (byId(defaultEditorId) == null) {
      defaultEditorId = scheme.defaultSelector;
    }
  }
}

bool _isSelector(String id) =>
    id == EditorRegistry.systemDefaultId || id == EditorRegistry.builtInId;
