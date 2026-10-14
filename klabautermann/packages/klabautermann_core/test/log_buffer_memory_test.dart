import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

/// 03 §11.4: log viewer memory under 64 MiB at the line cap.
const _budgetBytes = 64 * 1024 * 1024;

/// A line's index, so every line is its own string, then a space.
String _prefix(int i) => '${i.toString().padLeft(6, '0')} ';

/// The isolate group's live heap after a full collection, read with the VM
/// service's `getAllocationProfile` (`gc: true`). Plain JSON-RPC over a
/// WebSocket keeps `package:vm_service` out of the dependencies.
final class _HeapProbe {
  _HeapProbe._(this._socket, this._isolateId, this._stopServiceOnClose)
    : _replies = StreamIterator<dynamic>(_socket);

  final WebSocket _socket;
  final String _isolateId;
  final bool _stopServiceOnClose;
  final StreamIterator<dynamic> _replies;
  int _nextId = 0;

  static Future<_HeapProbe> open() async {
    var info = await Service.getInfo();
    final startedHere = info.serverUri == null;
    if (startedHere) {
      info = await Service.controlWebServer(enable: true, silenceOutput: true);
    }
    final uri = info.serverWebSocketUri;
    final isolateId = Service.getIsolateId(Isolate.current);
    if (uri == null || isolateId == null) {
      throw StateError('No VM service: the budget needs the Dart VM (JIT).');
    }
    final socket = await WebSocket.connect(uri.toString());
    return _HeapProbe._(socket, isolateId, startedHere);
  }

  Future<int> liveHeapBytes() async {
    final id = '${_nextId++}';
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': 'getAllocationProfile',
        'params': {'isolateId': _isolateId, 'gc': true},
      }),
    );
    while (await _replies.moveNext()) {
      final reply =
          jsonDecode(_replies.current as String) as Map<String, Object?>;
      if (reply['id'] != id) continue;

      final result = reply['result'];
      if (result is! Map<String, Object?>) {
        throw StateError('getAllocationProfile failed: ${reply['error']}');
      }
      final usage = result['memoryUsage']! as Map<String, Object?>;
      return usage['heapUsage']! as int;
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

void main() {
  late _HeapProbe probe;

  setUpAll(() async => probe = await _HeapProbe.open());
  tearDownAll(() => probe.close());

  group('LogBuffer memory (03 §11.4)', () {
    // Each line is all one kind of text, so every byte the buffer counts
    // is a byte the VM holds. The Latin-1 cases also check that the VM
    // stores such text in one byte a unit, as the count assumes; two
    // bytes a unit would put the full buffer over the budget.
    for (final (kind, fill) in [
      // 335 code units a line: 50,000 lines fill the byte cap to within
      // 0.2 %, so both caps bind and the per-entry overhead is largest.
      ('two-byte (Cyrillic)', 'Ж' * 328),
      // 670 code units, the same 670 bytes a line.
      ('Latin-1 (ASCII)', 'x' * 663),
    ]) {
      test('a buffer full at the 50,000-entry cap of $kind text stays under '
          '64 MiB', () async {
        final before = await probe.liveHeapBytes();

        final buffer = LogBuffer();
        for (var i = 0; i < logBufferMaxLines + 100; i++) {
          buffer.add(['${_prefix(i)}$fill']);
        }
        final retained = await probe.liveHeapBytes() - before;

        expect(buffer.length, logBufferMaxLines);
        expect(buffer.bytes, greaterThan(logBufferMaxBytes * 0.99));
        expect(
          retained,
          greaterThanOrEqualTo(buffer.bytes),
          reason: 'the probe must see the text the buffer holds',
        );
        expect(retained, lessThan(_budgetBytes));
      });
    }

    for (final (kind, fill) in [
      // 20,000 code units a line, each cut to 8,192: 2,048 fill 32 MiB.
      ('two-byte', 'Ж' * 19993),
      // Cut to its first 16,384 units, all Latin-1: the VM copies them
      // out of the two-byte line into a one-byte string.
      ('Latin-1 kept from two-byte', '${'x' * 16377}${'Ж' * 3616}'),
    ]) {
      test('$kind lines cut at 16 KiB hold only what they keep', () async {
        final before = await probe.liveHeapBytes();

        final buffer = LogBuffer();
        for (var i = 0; i < 2100; i++) {
          buffer.add(['${_prefix(i)}$fill']);
        }
        final retained = await probe.liveHeapBytes() - before;

        expect(buffer.length, logBufferMaxBytes ~/ logLineMaxBytes);
        expect(buffer.bytes, logBufferMaxBytes);
        expect((buffer[0] as LogLine).originalLength, 20000);
        expect(retained, greaterThanOrEqualTo(buffer.bytes));
        expect(retained, lessThan(_budgetBytes));
      });
    }
  });
}
