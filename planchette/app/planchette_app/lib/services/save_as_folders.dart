import 'package:path/path.dart' as paths;

/// The folders Save As last used, for where its dialog opens on a document
/// that has no folder of its own (A3).
///
/// A document saved before opens in its own folder; that rule lives with
/// the caller, which knows the document. An untitled one opens in the last
/// folder a file with its extension was saved to, then in the last folder
/// any Save As used, then wherever the system's dialog starts
/// ([initialFolderFor] answers null).
final class SaveAsFolders {
  const SaveAsFolders({this.byExtension = const {}, this.last});

  /// The last folder per extension, as [extensionOf] spells it, least
  /// recently used first. Bounded by [maximumExtensions].
  final Map<String, String> byExtension;

  /// The folder the last Save As went to, whatever its extension.
  final String? last;

  /// How many extensions are remembered; the least recently used goes.
  static const int maximumExtensions = 50;

  bool get isEmpty => byExtension.isEmpty && last == null;

  /// The key [name] is remembered under: its extension lowercased with the
  /// dot (`.md`), or empty for a name without one ("Untitled").
  static String extensionOf(String name) => paths.extension(name).toLowerCase();

  /// Where Save As opens for a document called [name] with no folder of
  /// its own, or null for the system's default.
  String? initialFolderFor(String name) =>
      byExtension[extensionOf(name)] ?? last;

  /// These folders after a save to the absolute [path].
  SaveAsFolders recorded(String path) {
    final folder = paths.dirname(path);
    final extension = extensionOf(path);
    final updated = {
      for (final entry in byExtension.entries)
        if (entry.key != extension) entry.key: entry.value,
      extension: folder,
    };
    while (updated.length > maximumExtensions) {
      updated.remove(updated.keys.first);
    }
    return SaveAsFolders(byExtension: Map.unmodifiable(updated), last: folder);
  }

  Map<String, Object?> toJson() => {
    if (byExtension.isNotEmpty) 'byExtension': byExtension,
    'last': ?last,
  };

  /// Reads what [toJson] wrote, keeping only absolute folders: a relative
  /// one from a hand edit would depend on the working directory.
  static SaveAsFolders fromJson(Object? json) {
    if (json is! Map) return const SaveAsFolders();
    final byExtension = <String, String>{};
    final stored = json['byExtension'];
    if (stored is Map) {
      for (final MapEntry(:key, :value) in stored.entries) {
        if (key is! String || value is! String || !paths.isAbsolute(value)) {
          continue;
        }
        byExtension[key] = value;
      }
    }
    while (byExtension.length > maximumExtensions) {
      byExtension.remove(byExtension.keys.first);
    }
    final last = json['last'];
    return SaveAsFolders(
      byExtension: Map.unmodifiable(byExtension),
      last: last is String && paths.isAbsolute(last) ? last : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SaveAsFolders &&
      other.last == last &&
      other.byExtension.length == byExtension.length &&
      byExtension.entries.every(
        (entry) => other.byExtension[entry.key] == entry.value,
      ) &&
      // The order is the eviction order, so it is part of the value.
      _sameOrder(other.byExtension.keys, byExtension.keys);

  static bool _sameOrder(Iterable<String> a, Iterable<String> b) {
    final left = a.toList();
    final right = b.toList();
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    last,
    Object.hashAll([
      for (final entry in byExtension.entries) ...[entry.key, entry.value],
    ]),
  );
}
