// The external editor registry, launcher and Settings section live in
// ghost_editors, shared with Séance (docs/PORTS.md). Poltergeist keeps its
// scheme (the `poltergeist.` namespace, reserved whole: bookmark-backup
// sync can ship a hand-edited definition, and it must never shadow a
// selector), the `poltergeist/files` runner channel, and the System
// default seam: the engine's LocalFileOpener rather than Séance's
// open_file plugin, behind the never-execute refusal (06 §5.3).
import 'package:flutter/services.dart';
import 'package:ghost_editors/ghost_editors.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

export 'package:ghost_editors/ghost_editors.dart'
    show
        EditorExecutablePicker,
        EditorHostPlatform,
        EditorProcessStarter,
        EditorRegistry,
        ExternalEditorDefinition,
        currentEditorHostPlatform,
        debugEditorHostPlatform;

/// Poltergeist's registry document in settings.json: version 1, System
/// default, the whole `poltergeist.` namespace reserved, no migrations
/// (every Poltergeist build wrote this format).
const poltergeistEditors = EditorRegistryScheme(
  namespace: 'poltergeist',
  formatVersion: 1,
  defaultSelector: EditorRegistry.systemDefaultId,
  idPolicy: ReservedEditorIds.wholeNamespace,
);

/// An OS default-handler launch [ExternalFileOpener.openSystemDefault]
/// declined because the handler would run the file as a program (06
/// §5.3's "never executed" open boundary). Typed so the shell answers
/// with the localized refusal and its Open With router, never an error
/// report.
final class ExecutableLaunchRefused implements Exception {
  const ExecutableLaunchRefused(this.path);

  /// The file that was not launched.
  final String path;

  @override
  String toString() => 'ExecutableLaunchRefused: $path';
}

/// Opens managed checkouts without ever constructing a shell command.
final class ExternalFileOpener {
  static const channel = MethodChannel('poltergeist/files');

  const ExternalFileOpener({
    this.systemOpener,
    this.processStarter,
    this.executablePicker,
  });

  /// The OS-default launch seam — the engine's LocalFileOpener (typed
  /// RemoteFileException errors, no shell) rather than Séance's
  /// open_file plugin: same hand-off, one fewer plugin (PORTS-noted).
  final LocalFileOpener? systemOpener;
  final EditorProcessStarter? processStarter;
  final EditorExecutablePicker? executablePicker;

  GhostEditorLauncher get _launcher => GhostEditorLauncher(
    channel: channel,
    processStarter: processStarter,
    executablePicker: executablePicker,
  );

  /// Hands a remote-derived copy (a managed checkout or a recovered
  /// payload; the user's own local files open through the engine, never
  /// here) to the OS default handler, unless that handler would run it
  /// as a program (06 §5.3). There is no "run anyway": the refusal is
  /// final, and an explicit editor choice ([openWith]) still opens the
  /// file as a document.
  Future<void> openSystemDefault(String path) async {
    if (launchWouldExecute(path)) throw ExecutableLaunchRefused(path);
    await (systemOpener ?? LocalFileOpener.platform()).open(path);
  }

  /// Whether the OS default handler would run [path] as a program on
  /// this host. A host with no desktop launch rules (mobile) answers for
  /// every desktop host, the conservative reading. The shell also asks
  /// this about a listing name to refuse before anything downloads.
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

  /// Picks an application and returns its definition — null on
  /// cancellation. [dialogTitle] is the caller's ARB string (D20): the
  /// native executable picker takes it verbatim, and it crosses the
  /// macOS channel as the panel's prompt.
  Future<ExternalEditorDefinition?> pickEditor({required String dialogTitle}) =>
      _launcher.pickEditor(dialogTitle: dialogTitle);
}
