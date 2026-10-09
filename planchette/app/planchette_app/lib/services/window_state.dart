import 'dart:convert';
import 'dart:io';

import 'package:ghost_desktop/ghost_desktop.dart';

import 'app_settings.dart';
import 'json_file.dart';

/// The desktop window's remembered frame and presentation flags, in a file
/// of their own beside `settings.json`. Kept out of [SettingsStore] on
/// purpose: a dragged resize saves on a debounce, and those writes have no
/// business rewriting the user's settings each time (Séance's rationale,
/// which this schema shares: `x`, `y`, `width`, `height`, `isMaximized`,
/// `isFullScreen`).
///
/// The file is device-local — on Windows [GhostWindowSnapshot.bounds] are
/// physical pixels (see [GhostCoordinateSpace.physicalOnWindows]) — so its
/// units never travel and its meaning is fixed by the lifecycle that reads
/// it, not by anything here.
final class WindowStateStore implements GhostWindowPersistence {
  WindowStateStore(this.file);

  /// `window_state.json` in the platform's per-user configuration directory.
  /// With no such directory to be found, the state lasts for this session
  /// only — the same fallback settings take.
  static GhostWindowPersistence defaultLocation() =>
      switch (LocalSettingsStore.defaultFilePath('window_state.json')) {
        final path? => WindowStateStore(File(path)),
        null => _SessionWindowStateStore(),
      };

  final File file;

  /// The stored window state, or null when there is none. `load` runs before
  /// the window is shown, so anything it lets escape is the reason the
  /// application refuses to open; a file that is missing, unreadable, or not
  /// a snapshot is worth starting over from rather than refusing to start.
  @override
  Future<GhostWindowSnapshot?> load() async {
    try {
      if (!await file.exists()) return null;
      return GhostWindowSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
      // Not `on Exception`: nothing this code runs — present or future —
      // may leave the app unable to open. A malformed file starts over.
    } catch (_) {
      return null;
    }
  }

  /// Writes beside the file and renames over it, so a crash mid-write leaves
  /// the previous state rather than a truncated file that would read as none
  /// at all — the same contract settings.json keeps.
  @override
  Future<void> save(GhostWindowSnapshot snapshot) =>
      writeJsonFileAtomically(file, snapshot.toJson());
}

/// Window state kept in memory, for a system with nowhere to store it.
final class _SessionWindowStateStore implements GhostWindowPersistence {
  GhostWindowSnapshot? _snapshot;

  @override
  Future<GhostWindowSnapshot?> load() async => _snapshot;

  @override
  Future<void> save(GhostWindowSnapshot snapshot) async => _snapshot = snapshot;
}
