import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Serializes native file-open batches, including events sent during startup.
/// macOS Finder has its own ready handshake; other runners supply argv.
final class OpenDocuments {
  OpenDocuments({
    required this.open,
    this.channel = const MethodChannel('planchette/documents'),
    this.pathExists = _existsOnDisk,
  });

  final Future<void> Function(String path) open;
  final MethodChannel channel;

  /// Whether a launch argument names an existing file or folder, which is
  /// what tells a dash-named document from an option. Injectable for tests.
  final bool Function(String path) pathExists;

  static bool _existsOnDisk(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  Future<void> start(List<String> arguments, {required bool macOS}) async {
    if (macOS) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open') await accept(call.arguments);
      });
      final pending = await channel.invokeMethod<Object?>('ready');
      await accept(pending);
    }
    await accept(_documentArguments(arguments, macOS: macOS));
  }

  /// The launch arguments that name documents.
  ///
  /// Everything after a bare `--` does. Before it, a dash-led entry is an
  /// option unless a file by that name exists: `--help` is not a document,
  /// but `planchette -draft.txt` opens one. On macOS, Launch Services and
  /// Xcode inject user-defaults options such as `-psn_0_12345`,
  /// `-NSDocumentRevisionsDebugMode YES` or `-AppleLanguages (de)`; such an
  /// option takes the next entry as its value unless that entry is itself
  /// dash-led or an existing file.
  List<String> _documentArguments(
    List<String> arguments, {
    required bool macOS,
  }) {
    final documents = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == '--') {
        documents.addAll(arguments.skip(i + 1));
        break;
      }
      if (!argument.startsWith('-') || pathExists(argument)) {
        documents.add(argument);
        continue;
      }
      if (macOS && _takesDefaultsValue(argument) && i + 1 < arguments.length) {
        final value = arguments[i + 1];
        if (value != '--' && !value.startsWith('-') && !pathExists(value)) i++;
      }
    }
    return documents;
  }

  /// A macOS user-defaults option is `-Name value`; the process serial
  /// `-psn_…` and GNU-style `--long` options carry no separate value.
  static bool _takesDefaultsValue(String option) =>
      !option.startsWith('--') && !option.startsWith('-psn_');

  Future<void> accept(Object? paths) {
    if (_disposed || paths is! List) return Future.value();
    final valid = paths
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toList();
    final operation = _tail.then((_) async {
      for (final path in valid) {
        if (_disposed) return;
        await open(path);
      }
    });
    // The caller still receives this batch's failure, while the next native
    // event gets a fresh chance to open its documents.
    _tail = operation.catchError((Object _) {});
    return operation;
  }

  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
  }
}
