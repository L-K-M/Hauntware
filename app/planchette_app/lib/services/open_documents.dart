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

  Future<void> start(List<String> arguments, {required bool macOS}) async {
    if (macOS) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open') await accept(call.arguments);
      });
      final pending = await channel.invokeMethod<Object?>('ready');
      await accept(pending);
    }
    await accept(
      arguments.where((argument) => !argument.startsWith('-')).toList(),
    );
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
