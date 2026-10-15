// `journalctl -o json` line parser tests (03 §7.6): cursor, time,
// priority, unit and message, with byte-array messages decoded leniently
// and malformed lines warned, never thrown.
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
}
