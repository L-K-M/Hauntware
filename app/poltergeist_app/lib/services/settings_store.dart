import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

abstract interface class SettingsFileSystem implements AtomicFileSystem {
  Future<String?> read(String path);

  Future<void> createDirectory(String path);
}

final class SettingsStore {
  SettingsStore({
    required String path,
    SettingsFileSystem? fileSystem,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
  }) : // Keep the filesystem path immutable and private.
       // ignore: prefer_initializing_formals
       _path = path,
       _fileSystem = fileSystem ?? const _IoSettingsFileSystem(),
       _now = now ?? DateTime.now,
       // Keep the callback private while allowing test-only error injection.
       // ignore: prefer_initializing_formals
       _onError = onError;

  final String _path;
  final SettingsFileSystem _fileSystem;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? _onError;
  final _values = <String, Object?>{};

  Future<void>? _loadFuture;
  Future<void> _writeTail = Future.value();

  Future<T?> get<T>(String key) async {
    await _ensureLoaded();
    final value = _values[key];
    return value is T ? value : null;
  }

  Future<void> set(String key, Object? value) async {
    await setAll({key: value});
  }

  Future<void> setAll(Map<String, Object?> updates) async {
    await _ensureLoaded();

    final operation = _writeTail.then((_) async {
      final previous = <String, Object?>{
        for (final key in updates.keys)
          if (_values.containsKey(key)) key: _values[key],
      };
      _values.addAll(updates);

      try {
        await _write();
      } catch (_) {
        for (final entry in updates.entries) {
          if (!identical(_values[entry.key], entry.value)) continue;
          if (previous.containsKey(entry.key)) {
            _values[entry.key] = previous[entry.key];
          } else {
            _values.remove(entry.key);
          }
        }
        rethrow;
      }
    });
    // The calling service owns write-error reporting; this only heals the queue.
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }

  Future<void> flush() async {
    await _ensureLoaded();
    await _writeTail;
  }

  Future<void> _ensureLoaded() {
    final activeLoad = _loadFuture;
    if (activeLoad != null) return activeLoad;

    final load = _load();
    _loadFuture = load;
    unawaited(
      load.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A transient filesystem failure must not poison later reads.
          if (identical(_loadFuture, load)) _loadFuture = null;
        },
      ),
    );
    return load;
  }

  Future<void> _load() async {
    late final String? contents;
    try {
      await _fileSystem.createDirectory(_parentDirectory(_path));
      contents = await _fileSystem.read(_path);
    } catch (error, stack) {
      _report(error, stack);
      rethrow;
    }

    if (contents == null) return;

    try {
      final decoded = jsonDecode(contents);
      if (decoded is! Map) throw const FormatException('settings root');
      for (final entry in decoded.entries) {
        if (entry.key is! String) throw const FormatException('settings key');
        _values[entry.key as String] = entry.value;
      }
    } catch (error, stack) {
      _values.clear();
      try {
        await _fileSystem.rename(_path, _corruptPath(_path));
      } catch (quarantineError, quarantineStack) {
        _report(quarantineError, quarantineStack);
      }
      _report(error, stack);
    }
  }

  Future<void> _write() async {
    await writeStringAtomically(
      fileSystem: _fileSystem,
      targetPath: _path,
      contents: jsonEncode(_values),
    );
  }

  String _corruptPath(String path) {
    final stamp = _formatTimestamp(_now().toUtc());
    return '$path.corrupt-$stamp';
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }
}

String _parentDirectory(String path) {
  final separator = Platform.pathSeparator;
  final index = path.lastIndexOf(separator);
  return index <= 0 ? '.' : path.substring(0, index);
}

String _formatTimestamp(DateTime value) => value
    .toIso8601String()
    .replaceAll('-', '')
    .replaceAll(':', '')
    .replaceAll('.', '');

final class _IoSettingsFileSystem implements SettingsFileSystem {
  const _IoSettingsFileSystem();

  @override
  Future<void> createDirectory(String path) =>
      Directory(path).create(recursive: true);

  @override
  Future<String?> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String path, String contents) =>
      File(path).writeAsString(contents, flush: true);

  @override
  Future<void> rename(String source, String destination) =>
      File(source).rename(destination);

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> exists(String path) => File(path).exists();
}
