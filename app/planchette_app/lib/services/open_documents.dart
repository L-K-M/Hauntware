import 'dart:async';

import 'package:flutter/services.dart';

/// Serializes native file-open batches, including events sent during startup.
/// macOS Finder has its own ready handshake; other runners supply argv.
final class OpenDocuments {
  OpenDocuments({
    required this.open,
    this.channel = const MethodChannel('planchette/documents'),
  });

  final Future<void> Function(String path) open;
  final MethodChannel channel;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// Launch Services' process-serial argument, e.g. `-psn_0_12345`. The
  /// exact shape is required so a file actually named `-psn_notes.txt`
  /// still opens.
  static final _psnArgument = RegExp(r'^-psn_\d+_\d+$');

  /// Flags Xcode's "Document Versions" run option and legacy state
  /// restoration inject into argv, each followed by a YES/NO value token.
  static const _injectedFlags = {
    '-NSDocumentRevisionsDebugMode',
    '-ApplePersistenceIgnoreState',
  };

  Future<void> start(List<String> arguments, {required bool macOS}) async {
    if (macOS) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open') await accept(call.arguments);
      });
      final pending = await channel.invokeMethod<Object?>('ready');
      await accept(pending);
    }
    await accept(_userArguments(arguments, macOS: macOS));
  }

  /// argv entries that are not documents are macOS-only injections:
  /// Launch Services' `-psn_*` serial and the debug/restoration flag
  /// pairs in [_injectedFlags]. Everything else is a user-supplied path —
  /// a file may legitimately be named "-draft.txt".
  static List<String> _userArguments(
    List<String> arguments, {
    required bool macOS,
  }) {
    if (!macOS) return arguments;
    final files = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (_psnArgument.hasMatch(argument)) continue;
      if (_injectedFlags.contains(argument)) {
        if (i + 1 < arguments.length &&
            (arguments[i + 1] == 'YES' || arguments[i + 1] == 'NO')) {
          i++;
        }
        continue;
      }
      files.add(argument);
    }
    return files;
  }

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
