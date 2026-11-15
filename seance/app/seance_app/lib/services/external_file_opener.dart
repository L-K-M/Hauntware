import 'dart:io';

import 'package:flutter/services.dart';
import 'package:ghost_editors/ghost_editors.dart';
import 'package:open_file/open_file.dart';
import 'package:planchette_core/planchette_core.dart'
    show TextNormalization, loadTextDocument;
import 'package:seance_core/seance_core.dart';

import 'editor_document.dart';

export 'package:ghost_editors/ghost_editors.dart'
    show
        EditorHostPlatform,
        EditorRegistry,
        ExternalEditorDefinition,
        currentEditorHostPlatform,
        debugEditorHostPlatform;

// The registry, its codec, the launcher and the Settings section live in
// ghost_editors, shared with Poltergeist. Séance keeps its scheme and
// migrations below, the `seance/files` runner channel, the open_file
// System default behind the never-execute refusal, and the built-in
// editor's limits.

/// The editor the legacy `remoteFileEditor: bbedit` setting migrates to.
const seanceMigratedBbeditId = 'macos.com.barebones.bbedit';

/// The first format that stores System default only once it is picked.
/// Version 1 stored it for a setting nobody had touched, so that value
/// cannot be told apart from a choice. Fixed, unlike the written version,
/// so a later format bump does not reset a System default chosen since.
const _explicitSystemDefaultVersion = 2;

/// Séance's registry document in settings.json: version 2, the built-in
/// editor by default, only the two `seance.` selectors reserved.
/// Per-extension defaults ride in `extensionDefaults`, which a build that
/// predates them ignores.
const seanceEditors = EditorRegistryScheme(
  namespace: 'seance',
  formatVersion: 2,
  defaultSelector: EditorRegistry.builtInId,
  migrations: [_versionOneSystemDefault],
);

/// Moves a version 1 System default to the built-in editor once, e.g.
/// `{'version': 1, 'defaultEditorId': 'seance.system'}`. Most of those were
/// never chosen; the rest can pick System default again.
Object? _versionOneSystemDefault(Object? stored) {
  if (stored is! Map) return stored;
  final version = stored['version'] is int ? stored['version'] as int : 1;
  if (version >= _explicitSystemDefaultVersion) return stored;
  if (stored['defaultEditorId'] != 'seance.system') return stored;
  return {...stored, 'defaultEditorId': 'seance.builtin'};
}

/// The pre-registry setting: with no registry document, a
/// `remoteFileEditor` of `bbedit` becomes a registry holding BBEdit as the
/// default. [legacyEditor] is that sibling settings value.
EditorRegistryMigration seanceLegacyEditorMigration(Object? legacyEditor) =>
    (stored) {
      if (stored is Map || legacyEditor != 'bbedit') return stored;
      return {
        'version': seanceEditors.formatVersion,
        'defaultEditorId': seanceMigratedBbeditId,
        'editors': [
          const ExternalEditorDefinition(
            id: seanceMigratedBbeditId,
            displayName: 'BBEdit',
            platform: EditorHostPlatform.macos,
            launchTarget: 'com.barebones.bbedit',
          ).toJson(),
        ],
      };
    };

/// Séance's built-in editor routing on top of the shared resolution.
extension SeanceEditorRouting on EditorRegistry {
  /// The editor a default open uses for [local], the checkout of [path]:
  /// [effectiveDefaultFor], except that on desktop a file the built-in editor
  /// cannot open, e.g. a PNG or a 6 MB log, goes to the system's default app.
  Future<String> effectiveDefaultForCheckout(String path, File local) async {
    final selected = effectiveDefaultFor(path);
    final fallback = _builtInFallbackId;
    if (selected != EditorRegistry.builtInId || fallback == null) {
      return selected;
    }
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
    if (selected != EditorRegistry.builtInId || fallback == null) {
      return selected;
    }
    if (size == null || size <= builtInEditorMaximumBytes) return selected;
    return fallback;
  }

  /// The most a checkout opened in [editorId], or in the default editor when
  /// null, may download: the built-in editor's limit, unless a default open
  /// can still hand a larger file to the system's default app.
  int? checkoutMaximumBytes(String path, {String? editorId}) {
    final selected = editorId ?? effectiveDefaultFor(path);
    if (selected != EditorRegistry.builtInId) return null;
    if (editorId == null && _builtInFallbackId != null) return null;
    return builtInEditorMaximumBytes;
  }

  /// Where a default open sends a file the built-in editor refuses. Mobile
  /// has nowhere: see [effectiveDefaultFor].
  String? get _builtInFallbackId =>
      currentEditorHostPlatform == null ? null : EditorRegistry.systemDefaultId;
}

/// Whether the built-in editor accepts [file]'s content: UTF-8 text without
/// NULs, up to [builtInEditorMaximumBytes], by the same rules its tab
/// applies. A checkout that is missing or not a regular file counts as
/// accepted, so the tab names that problem instead of the system app.
Future<bool> _builtInEditorCanOpen(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) return true;

  try {
    await loadTextDocument(file, normalization: TextNormalization.preserve);
    return true;
  } on BuiltInEditorException {
    return false;
  }
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

  GhostEditorLauncher get _launcher =>
      const GhostEditorLauncher(channel: channel);

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

  Future<void> openWith(String path, ExternalEditorDefinition editor) =>
      _launcher.openWith(path, editor);

  /// Picks an application and returns its definition; null on
  /// cancellation.
  Future<ExternalEditorDefinition?> pickEditor() =>
      _launcher.pickEditor(dialogTitle: 'Choose an editor application');
}
