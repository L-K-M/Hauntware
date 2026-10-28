import 'dart:async';
import 'dart:io';

import 'package:open_file/open_file.dart';

/// Shows a file on this machine in the desktop's file manager, for a path a
/// local shell printed. Every launch passes its arguments as a list, never
/// through a shell, and only an absolute path, so no file name can read as
/// an option.
class LocalFileReveal {
  const LocalFileReveal();

  /// What the action is called on this desktop.
  static String get actionLabel =>
      Platform.isMacOS ? 'Show in Finder' : 'Show in Folder';

  /// Selects [path] in Finder on macOS. Elsewhere asks the freedesktop file
  /// manager to select it, and opens the folder holding it when no file
  /// manager takes that call (a Flatpak without `dbus-send`, a desktop
  /// without the service). A bus that takes the call and stays silent is
  /// reported instead, since its answer may still come.
  Future<void> reveal(String path) async {
    if (!path.startsWith('/')) throw ArgumentError.value(path, 'path');
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      throw StateError('$path does not exist on this computer.');
    }

    if (Platform.isMacOS) {
      final result = await Process.run('/usr/bin/open', ['-R', path]);
      if (result.exitCode == 0) return;
      final detail = '${result.stderr}'.trim();
      throw StateError(
        detail.isEmpty
            ? 'Finder could not show it.'
            : 'Finder could not show it: $detail',
      );
    }

    switch (await _showItems(path)) {
      case _BusAnswer.shown:
        return;
      case _BusAnswer.silent:
        // The call is out on the bus and may still be answered: opening
        // the folder as well could show it twice.
        throw StateError('The file manager did not answer.');
      case _BusAnswer.unavailable:
        break;
    }
    final folder = type == FileSystemEntityType.directory
        ? path
        : File(path).parent.path;
    final opened = await OpenFile.open(folder);
    if (opened.type != ResultType.done) throw StateError(opened.message);
  }

  /// How long the session bus may take to answer: a bus that accepts the
  /// call and never replies (after a resume, a wedged file manager) must
  /// not hang the action.
  static const _busTimeout = Duration(seconds: 5);

  /// The freedesktop `ShowItems` call, which selects the item in its folder.
  static Future<_BusAnswer> _showItems(String path) async {
    final Process call;
    try {
      call = await Process.start('dbus-send', [
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.FileManager1',
        '--type=method_call',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        // dbus-send splits an array argument at commas; a URI may carry
        // one escaped instead.
        "array:string:${Uri.file(path).toString().replaceAll(',', '%2C')}",
        'string:',
      ]);
    } on ProcessException {
      return _BusAnswer.unavailable;
    }
    unawaited(call.stdout.drain<void>());
    unawaited(call.stderr.drain<void>());
    try {
      final status = await call.exitCode.timeout(_busTimeout);
      return status == 0 ? _BusAnswer.shown : _BusAnswer.unavailable;
    } on TimeoutException {
      call.kill();
      return _BusAnswer.silent;
    }
  }
}

/// How the session bus answered `ShowItems`.
enum _BusAnswer {
  /// The file manager selected the item.
  shown,

  /// No file manager took the call (no `dbus-send`, no service, an error
  /// reply): the folder is opened instead.
  unavailable,

  /// No reply in time.
  silent,
}
