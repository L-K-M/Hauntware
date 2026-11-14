import 'dart:convert';
import 'dart:io';

import 'adapters.dart';
import 'snapshot.dart';

/// Replaces [file]'s contents with [json] atomically, in the host's own
/// encoding. Each host passes the writer its settings file uses.
typedef GhostWindowStateWriter =
    Future<void> Function(File file, Map<String, dynamic> json);

/// The window state as a JSON file of its own, `window_state.json` beside
/// the host's settings file, in [GhostWindowSnapshot.toJson]'s shape (`x`,
/// `y`, `width`, `height`, `isMaximized`, `isFullScreen`).
///
/// Kept out of the settings file on purpose: a dragged resize saves on a
/// debounce, and those writes have no business rewriting the file that
/// carries the user's settings or the device's sync identity each time.
/// The file is device-local and never synced; its coordinate space is the
/// lifecycle's (see [GhostCoordinateSpace]), never recorded here.
final class GhostWindowStateFile implements GhostWindowPersistence {
  /// [write] replaces the file atomically, so a crash mid-write leaves the
  /// previous state rather than a truncated file.
  GhostWindowStateFile(this.file, {required this._write});

  final File file;
  final GhostWindowStateWriter _write;
  Future<void> _saveTail = Future<void>.value();

  /// The stored state, or null when there is none. This runs before the
  /// window is shown, so a file that is missing, unreadable or not a
  /// snapshot reads as nothing saved rather than keeping the window from
  /// opening; the next save overwrites it. Window geometry is cheap to
  /// lose, so there is no corrupt copy as a settings file keeps.
  @override
  Future<GhostWindowSnapshot?> load() async {
    try {
      if (!await file.exists()) return null;
      return GhostWindowSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
      // Not `on Exception`: nothing this code runs may leave the app
      // unable to open.
    } on Object {
      return null;
    }
  }

  /// One save at a time, in the order they were asked for, so the last
  /// frame asked for is the one that lands. A failed save reports its
  /// error and does not hold up the next one.
  @override
  Future<void> save(GhostWindowSnapshot snapshot) {
    final json = snapshot.toJson();
    final saved = _saveTail.then((_) => _write(file, json));
    _saveTail = saved.then<void>((_) {}, onError: (Object _) {});
    return saved;
  }
}
