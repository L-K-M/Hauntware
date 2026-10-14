import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

const _mib = 1024 * 1024;

List<String> _texts(LogBuffer buffer) => [
  for (var i = 0; i < buffer.length; i++)
    switch (buffer[i]) {
      LogLine(:final text) => text,
      LogDroppedLines(:final count) => '<dropped $count>',
    },
];

void main() {
  group('LogBuffer (03 §10.8)', () {
    test('the caps are the plan\'s: 50,000 lines, 32 MiB, 16 KiB a line', () {
      expect(logBufferMaxLines, 50000);
      expect(logBufferMaxBytes, 32 * _mib);
      expect(logLineMaxBytes, 16 * 1024);
      expect(logBytesPerCodeUnit, 2);

      final buffer = LogBuffer();
      expect(buffer.maxLines, logBufferMaxLines);
      expect(buffer.maxBytes, logBufferMaxBytes);
      expect(buffer.maxLineBytes, logLineMaxBytes);
    });

    test('appends in order and numbers entries from 0', () {
      final buffer = LogBuffer()..add(['a', 'b']);

      expect(_texts(buffer), ['a', 'b']);
      expect([buffer[0].seq, buffer[1].seq], [0, 1]);
      expect(buffer.firstSeq, 0);
      expect(() => buffer[2], throwsRangeError);
    });

    group('line cap', () {
      test('evicts the oldest entries and advances firstSeq', () {
        final buffer = LogBuffer(maxLines: 3)..add(['a', 'b', 'c', 'd', 'e']);

        expect(_texts(buffer), ['c', 'd', 'e']);
        expect(buffer.firstSeq, 2);
        expect(buffer.bytes, 3 * logBytesPerCodeUnit);
      });

      test('holds exactly 50,000 lines by default', () {
        final buffer = LogBuffer()
          ..add([for (var i = 0; i <= logBufferMaxLines; i++) '$i']);

        expect(buffer.length, logBufferMaxLines);
        expect((buffer[0] as LogLine).text, '1');
        expect(buffer.firstSeq, 1);
      });
    });

    group('byte cap and accounting', () {
      test('counts two bytes per UTF-16 code unit, whatever the text', () {
        final buffer = LogBuffer()..add(['abc', 'Жж', '😀', '']);

        // 3 + 2 + 2 (one surrogate pair) + 0 code units.
        expect(buffer.bytes, 7 * logBytesPerCodeUnit);
      });

      test('evicts the oldest lines until the bytes fit', () {
        final buffer = LogBuffer(maxBytes: 20, maxLineBytes: 8)
          ..add(['aaaa', 'bbbb']);
        expect(buffer.bytes, 16);

        buffer.add(['ccc']);
        expect(_texts(buffer), ['bbbb', 'ccc']);
        expect(buffer.bytes, 14);

        // Exactly at the cap fits.
        buffer.add(['ddd']);
        expect(_texts(buffer), ['bbbb', 'ccc', 'ddd']);
        expect(buffer.bytes, 20);
      });

      test('holds exactly 32 MiB of full-length lines by default', () {
        const unitsPerLine = logLineMaxBytes ~/ logBytesPerCodeUnit;
        const fitting = logBufferMaxBytes ~/ logLineMaxBytes;
        final line = 'x' * unitsPerLine;
        final buffer = LogBuffer()..add(List.filled(fitting, line));

        expect(buffer.length, fitting);
        expect(buffer.bytes, logBufferMaxBytes);

        buffer.add([line]);
        expect(buffer.length, fitting);
        expect(buffer.bytes, logBufferMaxBytes);
        expect(buffer.firstSeq, 1);
      });

      test('clear empties the buffer and keeps numbering', () {
        final buffer = LogBuffer()
          ..add(['a', 'b'])
          ..clear();

        expect(buffer.length, 0);
        expect(buffer.isEmpty, isTrue);
        expect(buffer.bytes, 0);
        expect(buffer.firstSeq, 2);

        buffer.add(['c']);
        expect(buffer[0].seq, 2);
      });
    });

    group('line-length cap', () {
      test('cuts a long line and records its full length', () {
        final buffer = LogBuffer(maxLineBytes: 8)..add(['abcd', 'abcdef']);

        final whole = buffer[0] as LogLine;
        expect(whole.text, 'abcd');
        expect(whole.truncated, isFalse);
        expect(whole.originalLength, isNull);

        final cut = buffer[1] as LogLine;
        expect(cut.text, 'abcd');
        expect(cut.truncated, isTrue);
        expect(cut.originalLength, 6);
        expect(buffer.bytes, 16);
      });

      test('never splits a surrogate pair', () {
        // a b c <high> <low> d: a cut after four units would keep half
        // of the emoji.
        final buffer = LogBuffer(maxLineBytes: 8)..add(['abc😀d']);

        final cut = buffer[0] as LogLine;
        expect(cut.text, 'abc');
        expect(cut.originalLength, 6);
      });

      test('keeps 8,192 code units by default', () {
        const units = logLineMaxBytes ~/ logBytesPerCodeUnit;
        final buffer = LogBuffer()..add(['y' * units, 'z' * (units + 1)]);

        expect((buffer[0] as LogLine).truncated, isFalse);
        final cut = buffer[1] as LogLine;
        expect(cut.text.length, units);
        expect(cut.originalLength, units + 1);
        expect(buffer.bytes, 2 * logLineMaxBytes);
      });
    });

    group('dropped lines', () {
      test('a batch\'s drops come before its lines', () {
        final buffer = LogBuffer()
          ..add(['a'])
          ..add(['b', 'c'], dropped: 3);

        expect(_texts(buffer), ['a', '<dropped 3>', 'b', 'c']);
        expect(buffer.bytes, 3 * logBytesPerCodeUnit);
      });

      test('drops with no line between them merge into one record', () {
        final buffer = LogBuffer()
          ..add(['a'])
          ..add([], dropped: 2)
          ..add([], dropped: 5)
          ..add(['b'], dropped: 1);

        expect(_texts(buffer), ['a', '<dropped 8>', 'b']);
        // The merged record keeps its place in the numbering.
        expect(buffer[1].seq, 1);
        expect(buffer[2].seq, 2);
      });

      test('no drops, no record', () {
        final buffer = LogBuffer()..add(['a'], dropped: 0);

        expect(_texts(buffer), ['a']);
      });

      test('a record counts against the line cap but holds no bytes', () {
        final buffer = LogBuffer(maxLines: 2)
          ..add(['a'])
          ..add(['b'], dropped: 4);

        expect(_texts(buffer), ['<dropped 4>', 'b']);
        expect(buffer.bytes, logBytesPerCodeUnit);
      });

      test('a negative count is a programming error', () {
        expect(() => LogBuffer().add([], dropped: -1), throwsRangeError);
      });
    });

    test('rejects caps that cannot hold a line', () {
      expect(() => LogBuffer(maxLines: 0), throwsArgumentError);
      expect(() => LogBuffer(maxLineBytes: 1), throwsArgumentError);
      expect(
        () => LogBuffer(maxBytes: 1024, maxLineBytes: 2048),
        throwsArgumentError,
      );
    });
  });
}
