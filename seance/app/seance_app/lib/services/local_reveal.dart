import 'dart:io';

import 'package:ghost_desktop/ghost_desktop.dart'
    show GhostFileRevealer, GhostRevealOutcome;

/// Shows a file on this machine in the desktop's file manager, for a path a
/// local shell printed, through the suite's shared [GhostFileRevealer].
/// Only an absolute path that exists is passed on, so no file name can read
/// as an option, and every failure is reported as a [StateError] whose
/// message the context pane shows.
class LocalFileReveal {
  const LocalFileReveal([this._revealer = const GhostFileRevealer()]);

  final GhostFileRevealer _revealer;

  /// What the action is called on this desktop.
  static String get actionLabel =>
      Platform.isMacOS ? 'Show in Finder' : 'Show in Folder';

  /// Selects [path] in Finder, Explorer or the freedesktop file manager,
  /// opening the folder holding it when no file manager takes the call. A
  /// bus that takes the call and stays silent is reported instead, since
  /// its answer may still come.
  Future<void> reveal(String path) async {
    if (!File(path).isAbsolute) throw ArgumentError.value(path, 'path');
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      throw StateError('$path does not exist on this computer.');
    }

    final result = await _revealer.reveal(path);
    switch (result.outcome) {
      case GhostRevealOutcome.shown:
        return;
      case GhostRevealOutcome.unanswered:
        throw StateError('The file manager did not answer.');
      case GhostRevealOutcome.failed:
        if (!Platform.isMacOS) {
          throw StateError('No file manager could show it.');
        }
        final detail = result.detail;
        throw StateError(
          detail == null
              ? 'Finder could not show it.'
              : 'Finder could not show it: $detail',
        );
    }
  }
}
