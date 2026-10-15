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

/// The isolate group's live heap after a full collection: the VM service's
/// private `_collectAllGarbage`, then `getMemoryUsage`. Plain JSON-RPC over
/// a WebSocket keeps `package:vm_service` out of the dependencies.
///
/// Both replies are small on purpose. `getAllocationProfile` (`gc: true`)
/// answers with about 3 MB of per-class JSON, and under load the socket
/// can still hold one or two earlier replies at the next collection, so a
/// reading could be 3 or 6 MB high. That is more than the margin the cut
/// tests below leave between the heap and the text.
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

    test('a buffer full of journal entries stays under 64 MiB', () async {
      // A typical service entry, every value its own: the fields cost a
      // few objects an entry, whatever their number.
      JournalEntry entry(int i, String fill) => JournalEntry({
        '__CURSOR': 's=${'a' * 32};i=${i.toRadixString(16)};b=${'b' * 32}',
        '__REALTIME_TIMESTAMP': '${1760000000000000 + i}',
        '__MONOTONIC_TIMESTAMP': '${9000000 + i}',
        '_BOOT_ID': 'c' * 32,
        'PRIORITY': '6',
        '_UID': '33',
        '_GID': '33',
        '_COMM': 'nginx',
        '_EXE': '/usr/sbin/nginx',
        '_CMDLINE': 'nginx: worker process',
        '_PID': '$i',
        '_SYSTEMD_UNIT': 'app-$i.service',
        'SYSLOG_IDENTIFIER': 'nginx',
        '_TRANSPORT': 'stdout',
        'MESSAGE': '${_prefix(i)}$fill',
      });
      // 671 bytes for the entries that stay, so both caps bind as for
      // lines above.
      final last = entry(logBufferMaxLines, '');
      final unpadded = (LogBuffer()..addJournal([last])).bytes;
      final fill = 'x' * (671 - unpadded);

      final before = await probe.liveHeapBytes();
      final buffer = LogBuffer();
      for (var i = 0; i < logBufferMaxLines + 100; i++) {
        buffer.addJournal([entry(i, fill)]);
      }
      final retained = await probe.liveHeapBytes() - before;

      expect((buffer[0] as LogLine).journal!.fieldsLeftOut, 0);
      expect(buffer.length, greaterThan(logBufferMaxLines * 0.99));
      expect(buffer.bytes, greaterThan(logBufferMaxBytes * 0.99));
      expect(retained, greaterThanOrEqualTo(buffer.bytes));
      expect(retained, lessThan(_budgetBytes));
    });

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
