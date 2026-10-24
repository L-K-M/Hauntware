import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// Saves one server's folders, or removes them when empty:
/// `DeviceSettingsStore.setStackFolders`.
typedef SaveStackFolders =
    Future<void> Function(String serverId, List<String> folders);

/// The folders STK-08's scan searches on each server, chosen on this
/// device (03 §7.16): none until the user names some in the Stacks
/// sub-tab. The composition root restores them from `settings.json` and
/// saves each change there; without [save], as in tests, they are held
/// in memory only. Device-local until the `pref` record carries them
/// (M5 plan M05). Like the endpoint choices, they outlive an engine run.
final class StackFolders extends ChangeNotifier {
  StackFolders({Map<String, List<String>> stored = const {}, this._save})
    : _folders = {
        for (final MapEntry(:key, :value) in stored.entries)
          key: List.unmodifiable(value),
      };

  final Map<String, List<String>> _folders;
  final SaveStackFolders? _save;

  /// [serverId]'s folders, in the order the user gave them.
  List<String> foldersFor(String serverId) => _folders[serverId] ?? const [];

  /// Makes [folders] [serverId]'s, at once, and saves them. A save that
  /// fails rethrows, and the folders hold until the app quits, so the
  /// caller can say they were not kept.
  Future<void> setFolders(String serverId, List<String> folders) async {
    if (folders.isEmpty) {
      _folders.remove(serverId);
    } else {
      _folders[serverId] = List.unmodifiable(folders);
    }
    notifyListeners();
    await _save?.call(serverId, folders);
  }
}

/// [text]'s folders, one per line, blank lines dropped and repeats kept
/// once; or why they cannot be scanned: a folder that is not an
/// absolute path, or more than [kStackScanDirectoriesMax].
({List<String> folders, StackFoldersProblem? problem}) parseStackFolders(
  String text,
) {
  final folders = <String>[];
  for (final line in text.split('\n')) {
    final folder = line.trim();
    if (folder.isEmpty || folders.contains(folder)) continue;
    if (!folder.startsWith('/') ||
        folder.split('/').contains('..') ||
        folder.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      return (folders: const [], problem: StackFoldersProblem.notAbsolute);
    }
    folders.add(folder);
  }
  if (folders.length > kStackScanDirectoriesMax) {
    return (folders: const [], problem: StackFoldersProblem.tooMany);
  }
  return (folders: folders, problem: null);
}

/// Why [parseStackFolders] took no folders.
enum StackFoldersProblem { notAbsolute, tooMany }
