import 'dart:async';

import 'package:poltergeist_app/services/settings_store.dart';

final class MemorySettingsFileSystem implements SettingsFileSystem {
  final contents = <String, String>{};
  final writes = <String>[];
  final renames = <(String, String)>[];
  final deletes = <String>[];
  final firstWriteStarted = Completer<void>();

  bool blockWrites = false;
  bool failWrites = false;
  bool failFirstWrite = false;
  Object? firstReadError;
  int readCount = 0;
  Object? deleteError;
  Object? renameError;
  Completer<void>? _release;

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> delete(String path) async {
    deletes.add(path);
    if (deleteError case final error?) throw error;
    contents.remove(path);
  }

  @override
  Future<bool> exists(String path) async => contents.containsKey(path);

  @override
  Future<String?> read(String path) async {
    readCount++;
    if (firstReadError case final error? when readCount == 1) {
      throw error;
    }

    return contents[path];
  }

  @override
  Future<void> rename(String source, String destination) async {
    renames.add((source, destination));
    if (renameError case final error?) throw error;
    final value = contents.remove(source);
    if (value != null) contents[destination] = value;
  }

  @override
  Future<void> write(String path, String value) async {
    writes.add(path);
    contents[path] = value;
    if (!firstWriteStarted.isCompleted) firstWriteStarted.complete();
    if (!blockWrites) {
      if (failWrites || (failFirstWrite && writes.length == 1)) {
        throw StateError('write failed');
      }
      return;
    }
    _release ??= Completer<void>();
    await _release!.future;
    if (failWrites || (failFirstWrite && writes.length == 1)) {
      throw StateError('write failed');
    }
  }

  void releaseWrites() => _release?.complete();
}
