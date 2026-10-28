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
  /// manager answers that call (a Flatpak without `dbus-send`, a desktop
  /// without the service).
  Future<void> reveal(String path) async {
    if (!path.startsWith('/')) throw ArgumentError.value(path, 'path');
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      throw StateError('$path does not exist on this computer.');
    }

    if (Platform.isMacOS) {
      final result = await Process.run('/usr/bin/open', ['-R', path]);
      if (result.exitCode != 0) throw StateError('Finder could not show it.');
      return;
    }

    if (await _showItems(path)) return;
    final folder = type == FileSystemEntityType.directory
        ? path
        : File(path).parent.path;
    final opened = await OpenFile.open(folder);
    if (opened.type != ResultType.done) throw StateError(opened.message);
  }

  /// The freedesktop `ShowItems` call, which selects the item in its folder.
  static Future<bool> _showItems(String path) async {
    try {
      final result = await Process.run('dbus-send', [
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
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
