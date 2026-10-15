import 'dart:async';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/journal_record.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show parseJournalLine;
import 'package:test/test.dart';

/// Echoes every message back, so a record crosses a real isolate boundary
/// as a LogBatch will (03 D18).
void _echo(SendPort replies) {
  final inbox = ReceivePort();
  replies.send(inbox.sendPort);
  inbox.listen(replies.send);
}

void main() {
  late Isolate echo;
  late ReceivePort port;
  late StreamIterator<Object?> replies;
  late SendPort toEcho;

  setUp(() async {
    port = ReceivePort();
    replies = StreamIterator<Object?>(port);
    echo = await Isolate.spawn(_echo, port.sendPort);
    await replies.moveNext();
    toEcho = replies.current as SendPort;
  });

  tearDown(() {
    echo.kill();
    port.close();
  });

  /// [line] parsed as the engine parses `journalctl -o json`, resolved,
  /// and sent across the boundary in a LogBatch.
  Future<JournalRecord> crossed(String line) async {
    final entry = parseJournalLine(line);
    expect(entry, isNotNull, reason: line);
    final batch = LogBatch(
      streamId: 'logs-1',
      records: [journalRecordFrom(entry!)],
    );

    toEcho.send(batch);
    await replies.moveNext();
    return (replies.current as LogBatch).records.single as JournalRecord;
  }

  test('an entry crosses with its columns read once (LOG-01)', () async {
    final record = await crossed(
      '{"__CURSOR":"s=ab;i=1f","__REALTIME_TIMESTAMP":"1750000000000007",'
      '"PRIORITY":"3","_SYSTEMD_UNIT":"sshd.service",'
      '"SYSLOG_IDENTIFIER":"sshd","_PID":"1234",'
      '"MESSAGE":[104,105,255,33],"CODE_LINE":null}',
    );

    expect(record.cursor, 's=ab;i=1f');
    expect(
      record.at,
      DateTime.fromMicrosecondsSinceEpoch(1750000000000007, isUtc: true),
    );
    expect(record.priority, LogPriority.error);
    expect(record.unit, 'sshd.service');
    expect(record.identifier, 'sshd');
    expect(record.pid, 1234);
    // The parser decoded the byte array leniently; 0xff is not UTF-8.
    expect(record.message, 'hi�!');
    expect(record.fields['_PID'], '1234');
    expect(record.fields['MESSAGE'], 'hi�!');
    expect(record.fields.containsKey('CODE_LINE'), isTrue);
    expect(record.fields['CODE_LINE'], isNull);
    expect(() => record.fields['x'] = 'y', throwsUnsupportedError);
  });

  test('a value beyond its column reads as unknown instead of '
      'throwing', () async {
    // DateTime holds 100,000,000 days either side of the epoch; journald's
    // field is any 64-bit number the host sends.
    final record = await crossed(
      '{"__REALTIME_TIMESTAMP":"9000000000000000000","PRIORITY":"8",'
      '"_PID":"-3","MESSAGE":null}',
    );

    expect(record.at, isNull);
    expect(record.priority, isNull);
    expect(record.pid, isNull);
    expect(record.message, isNull);
    // The raw values still show in the row's fields.
    expect(record.fields['__REALTIME_TIMESTAMP'], '9000000000000000000');
    expect(record.fields['PRIORITY'], '8');
    expect(record.fields.containsKey('MESSAGE'), isTrue);

    final earliest = await crossed(
      '{"__REALTIME_TIMESTAMP":"-9223372036854775808","PRIORITY":"-1",'
      '"_PID":"0"}',
    );
    expect(earliest.at, isNull);
    expect(earliest.priority, isNull);
    expect(earliest.pid, isNull);
    expect(earliest.message, isNull);
    expect(earliest.fields.containsKey('MESSAGE'), isFalse);
  });

  test('each syslog severity maps to its priority', () async {
    for (final priority in LogPriority.values) {
      final record = await crossed('{"PRIORITY":"${priority.index}"}');
      expect(record.priority, priority);
    }
    expect((await crossed('{"PRIORITY":"warning"}')).priority, isNull);
  });
}
