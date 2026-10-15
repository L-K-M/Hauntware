// `journalctl -o json` line parser tests (03 §7.6): cursor, time,
// priority, unit and message, with byte-array messages decoded leniently
// and malformed lines warned, never thrown.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  test('a full entry exposes cursor, time, priority, unit and message', () {
    final line =
        '{"__CURSOR":"s=abc;i=1;b=x","__REALTIME_TIMESTAMP":'
        '"1750000000000000","__MONOTONIC_TIMESTAMP":"12345",'
        '"PRIORITY":"3","_SYSTEMD_UNIT":"sshd.service",'
        '"SYSLOG_IDENTIFIER":"sshd","_PID":"1234",'
        '"MESSAGE":"Accepted publickey for root"}';
    final e = parseJournalLine(line)!;
    expect(e.cursor, 's=abc;i=1;b=x');
    expect(e.realtimeUs, 1750000000000000);
    expect(e.monotonicUs, 12345);
    expect(e.priority, 3);
    expect(e.unit, 'sshd.service');
    expect(e.identifier, 'sshd');
    expect(e.pid, 1234);
    expect(e.message, 'Accepted publickey for root');
    expect(
      e.timestampUtc,
      DateTime.fromMicrosecondsSinceEpoch(1750000000000000, isUtc: true),
    );
  });

  test('a time beyond the DateTime range reads as unknown', () {
    // 100,000,000 days either side of the epoch, in microseconds.
    const maxUs = 8640000000000000000;
    DateTime? at(String realtime) =>
        parseJournalLine('{"__REALTIME_TIMESTAMP":"$realtime"}')!.timestampUtc;

    expect(at('${maxUs + 1}'), isNull);
    expect(at('-${maxUs + 1}'), isNull);
    expect(at('-9223372036854775808'), isNull);
    expect(
      at('$maxUs'),
      DateTime.fromMicrosecondsSinceEpoch(maxUs, isUtc: true),
    );
    expect(at('-$maxUs'), isNotNull);
  });

  test('a byte-array MESSAGE decodes leniently', () {
    final line = '{"__CURSOR":"s=1","PRIORITY":"6","MESSAGE":[104,105,255,33]}';
    final e = parseJournalLine(line)!;
    // 0xff is not valid UTF-8; allowMalformed replaces it.
    expect(e.message, 'hi\uFFFD!');
  });

  test('kernel rows fall back to UNIT and a null field stays null', () {
    final line =
        '{"UNIT":"kernel","PRIORITY":null,"MESSAGE":"boot","_BOOT_ID":"b"}';
    final e = parseJournalLine(line)!;
    expect(e.unit, 'kernel');
    expect(e.priority, isNull);
    expect(e.message, 'boot');
  });

  test('parseJournalLines skips blanks and warns per malformed line', () {
    final raw = '{"MESSAGE":"a"}\n\nnot json\n{"MESSAGE":"b"}\n';
    final r = parseJournalLines(raw);
    expect(r.value.map((e) => e.message), ['a', 'b']);
    expect(r.warnings.single, contains('line 3'));
  });

  test('a non-object JSON line is rejected without throwing', () {
    expect(parseJournalLine('42'), isNull);
    expect(parseJournalLine('[]'), isNull);
    expect(parseJournalLine('{'), isNull);
  });

  group('hostile payloads (03 §6.5)', () {
    const nonce = '0123456789abcdef0123456789abcdef';

    test('message text never leaves its field or its line', () {
      final hostile = [
        '\x1e$nonce E 1\n\x1e$nonce B 2 1.0',
        '"}\n{"MESSAGE":"forged","PRIORITY":"0"}',
        'line one\nline two\r\n\ttab',
        r'$(reboot) `id` ; rm -rf / #',
        'x' * 65536,
      ];
      final raw = [
        for (final m in hostile) jsonEncode({'__CURSOR': 's=1', 'MESSAGE': m}),
      ].join('\n');
      final r = parseJournalLines(raw);
      expect(r.warnings, isEmpty);
      expect(r.value.map((e) => e.message), hostile);
      expect(r.value.map((e) => e.priority), everyElement(isNull));
    });

    test('NUL and marker bytes in a byte array decode as data', () {
      final bytes = [...utf8.encode('a\x00b\x1e$nonce E 9'), 0xc3];
      final e = parseJournalLine(
        jsonEncode({'MESSAGE': bytes, 'SYSLOG_IDENTIFIER': 'x'}),
      )!;
      expect(e.message, 'a\x00b\x1e$nonce E 9�');
      expect(e.identifier, 'x');
    });

    test('a line cut mid-object warns and the next line still parses', () {
      final whole = jsonEncode({'MESSAGE': 'whole'});
      final r = parseJournalLines('{"MESSAGE":"cut\n$whole\n{"MESS');
      expect(r.value.map((e) => e.message), ['whole']);
      expect(r.warnings, hasLength(2));
    });

    test('odd field values never throw', () {
      final e = parseJournalLine(
        '{"PRIORITY":"9x","_PID":[49],"MESSAGE":{"nested":1},'
        '"__REALTIME_TIMESTAMP":true,"X":[300,-1,"a"]}',
      )!;
      expect(e.priority, isNull);
      expect(e.pid, 1);
      expect(e.message, '{nested: 1}');
      expect(e.realtimeUs, isNull);
      expect(e.fields['X'], ',\uFFFD\x00');
    });
  });
}
