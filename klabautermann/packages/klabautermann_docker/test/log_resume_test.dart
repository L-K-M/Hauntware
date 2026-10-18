import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

StdcopyFrame _frame(StdcopyKind stream, String text) =>
    StdcopyFrame(stream, Uint8List.fromList(utf8.encode(text)));

Future<List<TimestampedLogLine>> _join(
  List<StdcopyFrame> frames, {
  LogFraming framing = LogFraming.multiplexed,
  int maxLineBytes = defaultMaxLogLineChars,
}) => joinTimestampedLogLines(
  Stream.fromIterable(frames),
  framing: framing,
  maxLineBytes: maxLineBytes,
).toList();

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

  group('joined timestamped lines (03 §5.6)', () {
    const ts1 = '2026-10-17T10:00:00.000000001Z';
    const ts2 = '2026-10-17T10:00:00.000000002Z';
    const ts3 = '2026-10-17T10:00:00.000000003Z';

    test('Podman\'s line split over two frames, each with a timestamp, '
        'arrives whole at the first one (D01)', () async {
      final lines = await _join([
        _frame(StdcopyKind.stdout, '$ts1 stdout lin'),
        _frame(StdcopyKind.stderr, '$ts2 an error\n'),
        _frame(StdcopyKind.stdout, '$ts3 e 520\n'),
      ]);

      expect(
        [for (final l in lines) (l.stream, l.message)],
        [
          (StdcopyKind.stderr, 'an error'),
          (StdcopyKind.stdout, 'stdout line 520'),
        ],
      );
      expect(lines.last.timestamp!.nanos, 1);
    });

    test('a frame of several lines yields each, and a continuation '
        'without a timestamp is joined as it is', () async {
      final lines = await _join([
        _frame(StdcopyKind.stdout, '$ts1 one\n$ts2 two\n$ts3 thr'),
        _frame(StdcopyKind.stdout, 'ee\r\n'),
      ]);

      expect([for (final l in lines) l.message], ['one', 'two', 'three']);
      expect([for (final l in lines) l.timestamp!.nanos], [1, 2, 3]);
    });

    test('a raw stream splits on newlines only, wherever its chunks '
        'end, and drops no timestamp inside a line', () async {
      final lines = await _join([
        _frame(StdcopyKind.stdout, '$ts1 prompt> '),
        _frame(StdcopyKind.stdout, '$ts2 typed\r\n${ts3.substring(0, 9)}'),
        _frame(StdcopyKind.stdout, '${ts3.substring(9)} last'),
      ], framing: LogFraming.raw);

      expect(
        [for (final l in lines) l.message],
        ['prompt> $ts2 typed', 'last'],
      );
      expect(lines.last.timestamp!.nanos, 3);
    });

    test('an overlong line keeps its first bytes, and a multibyte '
        'character split across frames survives', () async {
      final lines = await _join([
        _frame(StdcopyKind.stdout, '$ts1 abcdefghij'),
        _frame(StdcopyKind.stdout, '$ts2 klmnop\n'),
        StdcopyFrame(
          StdcopyKind.stdout,
          Uint8List.fromList([...utf8.encode('$ts3 \u00e4'), 0xc3]),
        ),
        StdcopyFrame(StdcopyKind.stdout, Uint8List.fromList([0xb6, 0x0a])),
      ], maxLineBytes: ts1.length + 6);

      expect([for (final l in lines) l.message], ['abcde', '\u00e4\u00f6']);
    });
  });
}
