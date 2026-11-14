import 'dart:io';

import 'package:ghost_desktop/ghost_desktop.dart';

import 'app_settings.dart';
import 'json_file.dart';

/// The desktop window's remembered frame and presentation flags, in
/// `window_state.json` of their own beside `settings.json`
/// ([GhostWindowStateFile]: Séance's schema, kept out of [SettingsStore]
/// so a dragged resize never rewrites the user's settings).
///
/// Written beside the file and renamed over it, so a crash mid-write
/// leaves the previous state rather than a truncated file that would read
/// as none at all: the same contract and encoding settings.json keeps.
GhostWindowStateFile windowStateFile(File file) =>
    GhostWindowStateFile(file, write: writeJsonFileAtomically);

/// `window_state.json` in the platform's per-user configuration directory.
/// With no such directory to be found, the state lasts for this session
/// only, the same fallback settings take.
GhostWindowPersistence defaultWindowStatePersistence() =>
    switch (LocalSettingsStore.defaultFilePath('window_state.json')) {
      final path? => windowStateFile(File(path)),
      null => _SessionWindowStateStore(),
    };

/// Window state kept in memory, for a system with nowhere to store it.
final class _SessionWindowStateStore implements GhostWindowPersistence {
  GhostWindowSnapshot? _snapshot;

  @override
  Future<GhostWindowSnapshot?> load() async => _snapshot;

  @override
  Future<void> save(GhostWindowSnapshot snapshot) async => _snapshot = snapshot;
}
