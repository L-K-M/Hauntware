/// Reads the isolate group's live heap for the log buffer memory test and
/// the engine budget harness (03 §11.4).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Service;
import 'dart:io';
import 'dart:isolate';

/// The isolate group's live heap after a full collection: the VM service's
/// private `_collectAllGarbage`, then `getMemoryUsage`. Plain JSON-RPC over
/// a WebSocket keeps `package:vm_service` out of the dependencies.
///
/// Both replies are small on purpose. `getAllocationProfile` (`gc: true`)
/// answers with about 3 MB of per-class JSON, and under load the socket
/// can still hold one or two earlier replies at the next collection, so a
/// reading could be 3 or 6 MB high. That is more than the margin the log
/// buffer memory test leaves between the heap and the text.
final class HeapProbe {
  HeapProbe._(this._socket, this._isolateId, this._stopServiceOnClose)
    : _replies = StreamIterator<dynamic>(_socket);

  final WebSocket _socket;
  final String _isolateId;
  final bool _stopServiceOnClose;
  final StreamIterator<dynamic> _replies;
  int _nextId = 0;

  /// Connects to the VM service, starting it when it is not running.
  /// Only the JIT VM (`dart run`, `dart test`) has one.
  static Future<HeapProbe> open() async {
    var info = await Service.getInfo();
    final startedHere = info.serverUri == null;
    if (startedHere) {
      info = await Service.controlWebServer(enable: true, silenceOutput: true);
    }
    final uri = info.serverWebSocketUri;
    final isolateId = Service.getIsolateId(Isolate.current);
    if (uri == null || isolateId == null) {
      throw StateError('No VM service: reading the heap needs the JIT VM.');
    }
    final socket = await WebSocket.connect(uri.toString());
    return HeapProbe._(socket, isolateId, startedHere);
  }

  Future<int> liveHeapBytes() async {
    await _call('_collectAllGarbage');
    final usage = await _call('getMemoryUsage');
    return usage['heapUsage']! as int;
  }

  Future<Map<String, Object?>> _call(String method) async {
    final id = '${_nextId++}';
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': {'isolateId': _isolateId},
      }),
    );
    while (await _replies.moveNext()) {
      final reply =
          jsonDecode(_replies.current as String) as Map<String, Object?>;
      if (reply['id'] != id) continue;

      final result = reply['result'];
      if (result is! Map<String, Object?>) {
        throw StateError('$method failed: ${reply['error']}');
      }
      return result;
    }
    throw StateError('The VM service closed the connection.');
  }

  Future<void> close() async {
    await _socket.close();
    if (_stopServiceOnClose) {
      await Service.controlWebServer(enable: false, silenceOutput: true);
    }
  }
}
