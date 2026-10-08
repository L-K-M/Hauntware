import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show normalizeEditorExtensions, validateEditorDisplayName;
import 'package:seance_core/seance_core.dart';

import 'editor_document.dart';

enum EditorHostPlatform { macos, linux, windows }

class ExternalEditorDefinition {
  final String id;
  final String displayName;
  final EditorHostPlatform platform;

  /// Bundle identifier on macOS; absolute executable path elsewhere.
  final String launchTarget;
  final List<String> acceptedExtensions;

  const ExternalEditorDefinition({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.launchTarget,
    this.acceptedExtensions = const [],
  });

  factory ExternalEditorDefinition.fromJson(Map<String, dynamic> json) {
    final platformName = json['platform'];
    final platform = EditorHostPlatform.values.where(
      (value) => value.name == platformName,
    );
    if (platform.isEmpty) {
      throw const FormatException('Unknown editor platform');
    }
    final parsedPlatform = platform.first;
    return ExternalEditorDefinition(
      id: _validatedId(json['id']),
      displayName: validateEditorDisplayName(json['displayName']),
      platform: parsedPlatform,
      launchTarget: _validatedTarget(json['launchTarget'], parsedPlatform),
      acceptedExtensions: normalizeEditorExtensions(
        json['acceptedExtensions'] is List
            ? (json['acceptedExtensions'] as List).whereType<String>()
            : const [],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'platform': platform.name,
    'launchTarget': launchTarget,
    'acceptedExtensions': acceptedExtensions,
  };

  ExternalEditorDefinition copyWith({
    String? displayName,
    List<String>? acceptedExtensions,
  }) => ExternalEditorDefinition(
    id: id,
    displayName: validateEditorDisplayName(displayName ?? this.displayName),
    platform: platform,
    launchTarget: launchTarget,
    acceptedExtensions: acceptedExtensions ?? this.acceptedExtensions,
  );

  bool acceptsPath(String path) {
    if (acceptedExtensions.isEmpty) return true;
    final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
    return acceptedExtensions.any((extension) => name.endsWith('.$extension'));
  }

  bool get isAvailableOnCurrentPlatform =>
      platform == currentEditorHostPlatform;
}

class EditorRegistry {
  static const systemDefaultId = 'seance.system';
  static const builtInId = 'seance.builtin';
  static const migratedBbeditId = 'macos.com.barebones.bbedit';

  /// The serialized format.
  static const _version = 2;

  /// The first format that stores System default only once it is picked.
  /// Version 1 stored it for a setting nobody had touched, so that value
  /// cannot be told apart from a choice. Fixed, unlike [_version], so a
  /// later format bump does not reset a System default chosen since.
  static const _explicitSystemDefaultVersion = 2;

  String defaultEditorId;
  final List<ExternalEditorDefinition> editors;

  EditorRegistry({
    this.defaultEditorId = builtInId,
    Iterable<ExternalEditorDefinition> editors = const [],
  }) : editors = List.of(editors) {
    _repairDefault();
  }

  factory EditorRegistry.fromJson(Object? value, {Object? legacyEditor}) {
    if (value is Map) {
      final json = value.cast<Object?, Object?>();
      final editors = <ExternalEditorDefinition>[];
      final ids = <String>{};
      final entries = json['editors'];
      if (entries is List) {
        for (final entry in entries.take(64)) {
          if (entry is! Map) continue;
          try {
            final editor = ExternalEditorDefinition.fromJson(
              entry.cast<String, dynamic>(),
            );
            if (_isReservedEditorId(editor.id)) continue;
            if (ids.add(editor.id)) editors.add(editor);
          } catch (_) {
            // Keep other valid entries when one persisted app is malformed.
          }
        }
      }
      var defaultEditorId = json['defaultEditorId'] is String
          ? json['defaultEditorId'] as String
          : builtInId;

      // Move a version 1 System default to the built-in editor once, e.g.
      // `{'version': 1, 'defaultEditorId': 'seance.system'}`. Most of those
      // were never chosen; the rest can pick System default again.
      final version = json['version'] is int ? json['version'] as int : 1;
      if (version < _explicitSystemDefaultVersion &&
          defaultEditorId == systemDefaultId) {
        defaultEditorId = builtInId;
      }

      return EditorRegistry(defaultEditorId: defaultEditorId, editors: editors);
    }
    if (legacyEditor == 'bbedit') {
      return EditorRegistry(
        defaultEditorId: migratedBbeditId,
        editors: const [
          ExternalEditorDefinition(
            id: migratedBbeditId,
            displayName: 'BBEdit',
            platform: EditorHostPlatform.macos,
            launchTarget: 'com.barebones.bbedit',
          ),
        ],
      );
    }
    return EditorRegistry();
  }

  Map<String, dynamic> toJson() => {
    'version': _version,
    'defaultEditorId': defaultEditorId,
    'editors': editors.map((editor) => editor.toJson()).toList(),
  };

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

  String effectiveDefaultFor(String path) {
    if (defaultEditorId == builtInId) {
      return defaultEditorId;
    }
    // Mobile open/share APIs generally hand another app a copy rather than an
    // in-place editable checkout. Keep remote editing reliable there.
    if (defaultEditorId == systemDefaultId) {
      return currentEditorHostPlatform == null ? builtInId : systemDefaultId;
    }
    final editor = byId(defaultEditorId);
    if (editor == null ||
        !editor.isAvailableOnCurrentPlatform ||
        !editor.acceptsPath(path)) {
      return builtInId;
    }
    return editor.id;
  }

  /// The editor a default open uses for [local], the checkout of [path]:
  /// [effectiveDefaultFor], except that on desktop a file the built-in editor
  /// cannot open, e.g. a PNG or a 6 MB log, goes to the system's default app.
  Future<String> effectiveDefaultForCheckout(String path, File local) async {
    final selected = effectiveDefaultFor(path);
    final fallback = _builtInFallbackId;
    if (selected != builtInId || fallback == null) return selected;
    return await _builtInEditorCanOpen(local) ? selected : fallback;
  }

  /// The editor a default open will use for [path], as far as its listed
  /// [size] tells before anything downloads: [effectiveDefaultFor], except
  /// that on desktop a file over the built-in editor's limit can only go
  /// to the system's default app. Smaller files still depend on content,
  /// which [effectiveDefaultForCheckout] reads.
  String effectiveDefaultForListing(String path, int? size) {
    final selected = effectiveDefaultFor(path);
    final fallback = _builtInFallbackId;
    if (selected != builtInId || fallback == null) return selected;
    if (size == null || size <= builtInEditorMaximumBytes) return selected;
    return fallback;
  }

  /// The most a checkout opened in [editorId], or in the default editor when
  /// null, may download: the built-in editor's limit, unless a default open
  /// can still hand a larger file to the system's default app.
  int? checkoutMaximumBytes(String path, {String? editorId}) {
    final selected = editorId ?? effectiveDefaultFor(path);
    if (selected != builtInId) return null;
    if (editorId == null && _builtInFallbackId != null) return null;
    return builtInEditorMaximumBytes;
  }

  /// Where a default open sends a file the built-in editor refuses. Mobile
  /// has nowhere: see [effectiveDefaultFor].
  static String? get _builtInFallbackId =>
      currentEditorHostPlatform == null ? null : systemDefaultId;

  void put(ExternalEditorDefinition editor) {
    _validatedId(editor.id);
    if (_isReservedEditorId(editor.id)) {
      throw const FormatException('Editor id is reserved');
    }
    validateEditorDisplayName(editor.displayName);
    _validatedTarget(editor.launchTarget, editor.platform);
    normalizeEditorExtensions(editor.acceptedExtensions);
    final index = editors.indexWhere((item) => item.id == editor.id);
    if (index < 0) {
      if (editors.length >= 64) {
        throw StateError('At most 64 external editors can be configured.');
      }
      editors.add(editor);
    } else {
      editors[index] = editor;
    }
  }

  void remove(String id) {
    editors.removeWhere((editor) => editor.id == id);
    if (defaultEditorId == id) defaultEditorId = builtInId;
  }

  void _repairDefault() {
    if (defaultEditorId == systemDefaultId || defaultEditorId == builtInId) {
      return;
    }
    if (byId(defaultEditorId) == null) defaultEditorId = builtInId;
  }
}

/// Whether the built-in editor accepts [file]'s content: UTF-8 text without
/// NULs, up to [builtInEditorMaximumBytes], by the same rules its tab
/// applies. A checkout that is missing or not a regular file counts as
/// accepted, so the tab names that problem instead of the system app.
Future<bool> _builtInEditorCanOpen(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) return true;

  try {
    await loadBuiltInTextDocumentDetails(file);
    return true;
  } on BuiltInEditorException {
    return false;
  }
}

bool _isReservedEditorId(String id) =>
    id == EditorRegistry.systemDefaultId || id == EditorRegistry.builtInId;

EditorHostPlatform? get currentEditorHostPlatform {
  if (Platform.isMacOS) return EditorHostPlatform.macos;
  if (Platform.isLinux) return EditorHostPlatform.linux;
  if (Platform.isWindows) return EditorHostPlatform.windows;
  return null;
}

/// A file the system's default app would run as a program, refused before
/// the OS saw it: `payload.exe` on Windows, `run.command` on macOS.
final class ExecutableLaunchRefused implements Exception {
  const ExecutableLaunchRefused(this.path);

  final String path;

  @override
  String toString() =>
      '“${path.split(_pathSeparators).last}” could run as a program on this '
      "computer, so it wasn't opened with the system default app.";
}

final _pathSeparators = RegExp(r'[/\\]');

/// Opens managed checkouts without ever constructing a shell command.
class ExternalFileOpener {
  static const channel = MethodChannel('seance/files');

  const ExternalFileOpener();

  /// Hands a checkout of a remote file to the system's default app,
  /// unless that app would run it as a program (finding P1-03). There is
  /// no "run anyway"; an editor picked under Open with ([openWith]) still
  /// opens the file as a document.
  Future<void> openSystemDefault(String path) async {
    if (launchWouldExecute(path)) throw ExecutableLaunchRefused(path);

    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) throw StateError(result.message);
  }

  /// Whether the system's default app would run [path] as a program on
  /// this host. A host with no desktop launch rules (mobile) answers for
  /// every desktop host, the conservative reading.
  bool launchWouldExecute(String path) {
    final host = switch (currentEditorHostPlatform) {
      EditorHostPlatform.macos => LaunchHost.macos,
      EditorHostPlatform.linux => LaunchHost.linux,
      EditorHostPlatform.windows => LaunchHost.windows,
      null => null,
    };
    if (host != null) return isExecutableLaunchName(path, host: host);

    return LaunchHost.values.any(
      (each) => isExecutableLaunchName(path, host: each),
    );
  }

  Future<void> openWith(String path, ExternalEditorDefinition editor) async {
    if (!editor.isAvailableOnCurrentPlatform) {
      throw UnsupportedError(
        '${editor.displayName} is configured for another platform.',
      );
    }
    if (editor.platform == EditorHostPlatform.macos) {
      await channel.invokeMethod<void>('openWithApplication', {
        'path': path,
        'bundleIdentifier': editor.launchTarget,
      });
      return;
    }
    final executable = File(editor.launchTarget);
    final type = await FileSystemEntity.type(editor.launchTarget);
    if (!executable.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError(
        '${editor.displayName} is no longer installed at ${editor.launchTarget}.',
      );
    }
    if (editor.platform == EditorHostPlatform.linux &&
        ((await executable.stat()).mode & 0x49) == 0) {
      throw StateError('${editor.displayName} is not executable.');
    }
    await Process.start(
      editor.launchTarget,
      [path],
      runInShell: false,
      mode: ProcessStartMode.detached,
    );
  }

  Future<ExternalEditorDefinition?> pickEditor() async {
    final platform = currentEditorHostPlatform;
    if (platform == null) return null;
    if (platform == EditorHostPlatform.macos) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'pickApplication',
      );
      if (result == null) return null;
      final bundleIdentifier = result['bundleIdentifier'] as String?;
      if (bundleIdentifier == null || bundleIdentifier.isEmpty) {
        throw StateError('The selected application has no bundle identifier.');
      }
      return ExternalEditorDefinition(
        id: uuidV4(),
        displayName: validateEditorDisplayName(result['displayName']),
        platform: platform,
        launchTarget: bundleIdentifier,
      );
    }
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose an editor application',
      allowMultiple: false,
      type: platform == EditorHostPlatform.windows
          ? FileType.custom
          : FileType.any,
      allowedExtensions: platform == EditorHostPlatform.windows
          ? const ['exe']
          : null,
      lockParentWindow: platform == EditorHostPlatform.windows,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    final file = File(path);
    final type = await FileSystemEntity.type(path);
    if (!file.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError('Choose a regular executable file.');
    }
    if (platform == EditorHostPlatform.windows &&
        !path.toLowerCase().endsWith('.exe')) {
      throw StateError('Windows editors must be .exe applications.');
    }
    if (platform == EditorHostPlatform.linux &&
        ((await file.stat()).mode & 0x49) == 0) {
      throw StateError('The selected file is not executable.');
    }
    final name = path.split(Platform.pathSeparator).last;
    return ExternalEditorDefinition(
      id: uuidV4(),
      displayName: validateEditorDisplayName(
        platform == EditorHostPlatform.windows &&
                name.toLowerCase().endsWith('.exe')
            ? name.substring(0, name.length - 4)
            : name,
      ),
      platform: platform,
      launchTarget: path,
    );
  }
}

String _validatedId(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value)) {
    throw const FormatException('Invalid editor id');
  }
  return value;
}

String _validatedTarget(Object? value, EditorHostPlatform platform) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 4096 ||
      value.contains('\u0000')) {
    throw const FormatException('Invalid editor target');
  }
  if (platform != EditorHostPlatform.macos && !File(value).isAbsolute) {
    throw const FormatException('Editor executable paths must be absolute');
  }
  if (platform == EditorHostPlatform.windows &&
      !value.toLowerCase().endsWith('.exe')) {
    throw const FormatException('Windows editors must be .exe applications');
  }
  return value;
}
