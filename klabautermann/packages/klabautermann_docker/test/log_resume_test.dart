import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

void main() {
  group('LogTimestamp (03 §5.6)', () {
    test('parses RFC3339Nano keeping nanoseconds', () {
      final ts = LogTimestamp.tryParse('2026-05-01T10:20:30.123456789Z')!;
      final expectedSeconds =
          DateTime.utc(2026, 5, 1, 10, 20, 30).millisecondsSinceEpoch ~/ 1000;
      expect(ts.seconds, expectedSeconds);
      expect(ts.nanos, 123456789);
      expect(ts.sinceQuery, '$expectedSeconds.123456789');
    });

    test('normalizes an offset to UTC', () {
      final ts = LogTimestamp.tryParse('2026-05-01T12:20:30.5+02:00')!;
      expect(
        ts.seconds,
        DateTime.utc(2026, 5, 1, 10, 20, 30).millisecondsSinceEpoch ~/ 1000,
      );
      expect(ts.nanos, 500000000);
    });

    test('handles a missing fraction and rejects junk', () {
      final ts = LogTimestamp.tryParse('2026-05-01T10:20:30Z')!;
      expect(ts.nanos, 0);
      expect(ts.sinceQuery.endsWith('.000000000'), isTrue);
      expect(LogTimestamp.tryParse('nope'), isNull);
      expect(LogTimestamp.tryParse(null), isNull);
    });

    test('orders by seconds then nanos', () {
      const a = LogTimestamp(10, 5);
      const b = LogTimestamp(10, 6);
      const c = LogTimestamp(11, 0);
      expect(a < b, isTrue);
      expect(b < c, isTrue);
      expect(c > a, isTrue);
      expect(a == const LogTimestamp(10, 5), isTrue);
    });
  });

  group('timestamped log lines (03 §5.6)', () {
    test('splits the timestamp from the message', () {
      final line = LogLine(
        StdcopyKind.stdout,
        '2026-05-01T10:20:30.000000001Z hello world',
      );
      final parsed = parseTimestampedLogLine(line).value;
      expect(parsed.timestamp!.nanos, 1);
      expect(parsed.message, 'hello world');
      expect(parsed.stream, StdcopyKind.stdout);
    });

    test('a line without a timestamp is all message', () {
      final parsed = parseTimestampedLogLine(
        const LogLine(StdcopyKind.stderr, 'plain text'),
      ).value;
      expect(parsed.timestamp, isNull);
      expect(parsed.message, 'plain text');
    });
  });

  group('inclusive-since de-duplication (03 §5.6)', () {
    TimestampedLogLine at(int second) => TimestampedLogLine(
      timestamp: LogTimestamp(second, 0),
      message: 'line $second',
      stream: StdcopyKind.stdout,
    );

    test('drops the re-sent boundary line and everything before it', () async {
      final out = await dropInclusiveSince(
        Stream.fromIterable([at(1), at(2), at(3), at(4)]),
        const LogTimestamp(2, 0),
      ).toList();
      expect(out.map((l) => l.message), ['line 3', 'line 4']);
    });

    test('a line without a timestamp ends the drop', () async {
      final out = await dropInclusiveSince(
        Stream.fromIterable([
          const TimestampedLogLine(
            message: 'no timestamp',
            stream: StdcopyKind.stdout,
          ),
          at(1),
        ]),
        const LogTimestamp(2, 0),
      ).toList();
      expect(out.map((l) => l.message), ['no timestamp', 'line 1']);
    });

    test('lastDeliveredTimestamp finds the newest timestamp', () {
      expect(lastDeliveredTimestamp([at(1), at(5), at(3)])!.seconds, 5);
      expect(lastDeliveredTimestamp(const []), isNull);
    });
  });
}
