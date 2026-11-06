import 'dart:math';

import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm/src/utils/debugger.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('remote window operations cannot resize the local terminal', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[8;24;80t');
      parser.write('\x1b[18t');

      expect(handler.resizes, isEmpty);
      expect(handler.sizeQueries, 1);
    });

    test('keeps omitted leading CSI parameters in their positions', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[;5H');
      parser.write('\x1b[;8r');
      verifyInOrder([
        parser.handler.setCursor(4, 0),
        parser.handler.setMargins(0, 7),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });

    test('normalizes zero and omitted margin defaults before dispatch', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[0;0r');
      parser.write('\x1b[3;r');
      verifyInOrder([
        parser.handler.setMargins(0, null),
        parser.handler.setMargins(2, null),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });
  });

  /// [seance fork] A private marker or an intermediate byte names a different
  /// control function than the bare final byte. See PATCHES.md.
  group('EscapeParser CSI function identity', () {
    final m = 'm'.codeUnitAt(0);

    test('ignores private-marker functions it does not implement', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[>4;2m'); // XTMODKEYS: set modifyOtherKeys
      parser.write('\x1b[>4m'); // XTMODKEYS: reset modifyOtherKeys
      parser.write('\x1b[?4m'); // XTQMODKEYS
      parser.write('\x1b[<0;10;5m'); // an echoed SGR mouse report
      parser.write('\x1b[?1;1S'); // XTSMGRAPHICS
      parser.write('\x1b[>1T'); // XTRMTITLE
      parser.write('\x1b[?1r'); // XTRESTORE
      parser.write('\x1b[>6n'); // key modifier options: disable
      parser.write('\x1b[?62;22c'); // an echoed primary DA reply

      verifyInOrder([
        parser.handler.unknownCSI(m),
        parser.handler.unknownCSI(m),
        parser.handler.unknownCSI(m),
        parser.handler.unknownCSI(m),
        parser.handler.unknownCSI('S'.codeUnitAt(0)),
        parser.handler.unknownCSI('T'.codeUnitAt(0)),
        parser.handler.unknownCSI('r'.codeUnitAt(0)),
        parser.handler.unknownCSI('n'.codeUnitAt(0)),
        parser.handler.unknownCSI('c'.codeUnitAt(0)),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });

    test('ignores functions with intermediate bytes', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[2 A'); // SR: scroll right
      parser.write('\x1b[3 @'); // SL: scroll left
      parser.write('\x1b[#P'); // XTPUSHCOLORS

      verifyInOrder([
        parser.handler.unknownCSI('A'.codeUnitAt(0)),
        parser.handler.unknownCSI('@'.codeUnitAt(0)),
        parser.handler.unknownCSI('P'.codeUnitAt(0)),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });

    test('still dispatches the private-marker functions it implements', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[?7l'); // DECAWM
      parser.write('\x1b[?6n'); // DECXCPR
      parser.write('\x1b[?2J'); // DECSED
      parser.write('\x1b[?2K'); // DECSEL
      parser.write('\x1b[>c'); // secondary DA
      parser.write('\x1b[=c'); // tertiary DA

      verifyInOrder([
        parser.handler.setAutoWrapMode(false),
        parser.handler.sendCursorPosition(),
        parser.handler.eraseDisplay(),
        parser.handler.eraseLine(),
        parser.handler.sendSecondaryDeviceAttributes(),
        parser.handler.sendTertiaryDeviceAttributes(),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });

    test('forgets the previous sequence\'s marker and intermediates', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[>4m\x1b[4m');
      parser.write('\x1b[2 A\x1b[2A');

      verifyInOrder([
        parser.handler.unknownCSI(m),
        parser.handler.setCursorUnderline(),
        parser.handler.unknownCSI('A'.codeUnitAt(0)),
        parser.handler.moveCursorY(-2),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });

    test('identifies a sequence split across writes', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[');
      parser.write('>4');
      parser.write(';2m');
      parser.write('\x1b[2');
      parser.write(' A');

      verifyInOrder([
        parser.handler.unknownCSI(m),
        parser.handler.unknownCSI('A'.codeUnitAt(0)),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });

    test('still applies SGR without a marker', () {
      final parser = EscapeParser(MockEscapeHandler());

      parser.write('\x1b[4;2m');

      verifyInOrder([
        parser.handler.setCursorUnderline(),
        parser.handler.setCursorFaint(),
      ]);
      verifyNoMoreInteractions(parser.handler);
    });
  });

  group('EscapeParser incremental parsing', () {
    const sample = 'A\x1b[;5HB\x1b[?7lC\x1b]0;my title\x1b\\D\x1b(0E\u{1f47b}'
        'F\x1b]2;bell title\x07G';

    test('valid sequences are identical at every split point', () {
      final runes = sample.runes.toList();
      final expected = _trace([sample]);

      for (var split = 0; split <= runes.length; split++) {
        final chunks = [
          String.fromCharCodes(runes.take(split)),
          String.fromCharCodes(runes.skip(split)),
        ];
        expect(_trace(chunks), expected, reason: 'split at rune $split');
      }
    });

    test('valid sequences are identical one rune at a time', () {
      final chunks = sample.runes.map(String.fromCharCode).toList();
      expect(_trace(chunks), _trace([sample]));
    });

    test('over-cap OSC is identical whole or one rune at a time', () {
      final input = '\x1b]0;${'a' * 100}\x07ok';
      final chunks = input.runes.map(String.fromCharCode).toList();

      expect(
        _trace(chunks, maxPendingSequenceLength: 64),
        _trace([input], maxPendingSequenceLength: 64),
      );
      expect(
        _trace([input], maxPendingSequenceLength: 64),
        _trace(['ok'], maxPendingSequenceLength: 64),
      );
    });

    test('randomized streams are independent of chunk boundaries', () {
      for (var seed = 0; seed < 32; seed++) {
        final random = Random(seed);
        const fragments = [
          'plain',
          '\x1b[2A',
          '\x1b[>4m',
          '\x1b]2;title\x07',
          '\x1b]8;;https://example.test/a;b\x1b\\',
          '\x1bPdiscarded\x1b\\',
          '\x1b(0',
          '\r\n',
          '\u{1f47b}',
        ];
        final input = StringBuffer();
        for (var i = 0; i < 80; i++) {
          input.write(fragments[random.nextInt(fragments.length)]);
        }

        final value = input.toString();
        final runes = value.runes.toList();
        final chunks = <String>[];
        for (var offset = 0; offset < runes.length;) {
          final length = min(1 + random.nextInt(9), runes.length - offset);
          chunks.add(
            String.fromCharCodes(runes.sublist(offset, offset + length)),
          );
          offset += length;
        }

        expect(_trace(chunks), _trace([value]), reason: 'seed $seed');
      }
    });
  });

  /// [seance fork] Control strings are parsed once across writes and bounded.
  /// Overflow stays quarantined until the sequence's terminator instead of
  /// becoming terminal text. See PATCHES.md.
  group('EscapeParser sequence bounds', () {
    /// The bytes an OSC 0 sequence with a payload of [length] occupies on the
    /// queue, including the `ESC ] 0 ;` introducer.
    String osc0(int length) => '\x1b]0;${'a' * length}';

    test('still waits for a sequence split across writes', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b]0;my ti');
      expect(handler.titles, isEmpty);

      parser.write('tle\x07');
      expect(handler.titles, ['my title']);
    });

    test('keeps waiting while the run is still within the cap', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler, maxPendingSequenceLength: 64);

      // 4 introducer bytes + 60 payload == exactly the cap.
      parser.write(osc0(60));
      expect(handler.text, isEmpty);

      parser.write('\x07');
      expect(handler.titles, ['a' * 60]);
    });

    test('abandons a run that outgrows the cap', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler, maxPendingSequenceLength: 64);

      parser.write(osc0(61)); // one byte past the cap
      parser.write('still discarded');
      expect(handler.text, isEmpty);

      parser.write('\x07ok');

      expect(handler.titles, isEmpty);
      expect(handler.bells, 0);
      expect(handler.text, 'ok');
    });

    test('oversized OSC stays bounded under one-rune writes', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler, maxPendingSequenceLength: 64);

      for (final rune in osc0(100000).runes) {
        parser.write(String.fromCharCode(rune));
      }
      parser.write('\x1b');
      parser.write('\\done');

      expect(handler.titles, isEmpty);
      expect(handler.text, 'done');
    });

    test(
      'default-cap OSC remains linear under one-rune writes',
      () {
        final handler = _RecordingHandler();
        final parser = EscapeParser(handler);

        parser.write('\x1b]0;');
        for (var i = 0; i < kMaxPendingSequenceLength + 1024; i++) {
          parser.write('a');
        }
        parser.write('\x07done');

        expect(handler.titles, isEmpty);
        expect(handler.text, 'done');
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('ignores an oversized CSI through its final byte', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[');
      for (var i = 0; i <= kMaxCsiSequenceLength; i++) {
        parser.write('1');
      }
      parser.write('m');
      expect(handler.text, isEmpty);

      parser.write('ok');
      expect(handler.text, 'ok');
    });

    test('accepts a CSI exactly at the length limit', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b[${'9' * (kMaxCsiSequenceLength - 3)}A',
      );

      verify(handler.moveCursorY(-kMaxCsiParameterValue)).called(1);
      verifyNoMoreInteractions(handler);
    });

    test('ignores a CSI one rune beyond the length limit', () {
      final handler = _TraceHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b[${'9' * (kMaxCsiSequenceLength - 2)}A',
      );

      expect(handler.events, isEmpty);
    });

    test('accepts exactly the parameter limit', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b[${List.filled(kMaxCsiParameters, '1').join(';')}m',
      );

      verify(handler.setCursorBold()).called(kMaxCsiParameters);
      verifyNoMoreInteractions(handler);
    });

    test('ignores a CSI with too many parameters', () {
      final handler = _TraceHandler();
      final parser = EscapeParser(handler);
      final parameters = List.filled(kMaxCsiParameters + 1, '1').join(';');

      parser.write('\x1b[${parameters}m');
      expect(handler.events, isEmpty);
    });

    test('saturates numeric CSI parameters', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[999999999999999999999999999999A');
      verify(handler.moveCursorY(-kMaxCsiParameterValue)).called(1);
      verifyNoMoreInteractions(handler);
    });
  });

  group('EscapeParser unsupported control strings', () {
    test('quarantines DCS, SOS, PM, and APC through split ST', () {
      for (final introducer in ['P', 'X', '^', '_']) {
        final handler = _RecordingHandler();
        final parser = EscapeParser(handler);
        final input =
            '\x1b${introducer}hidden\x07\r\n\x1b[31m\x1bXstill hidden\x1b\\ok';

        for (final rune in input.runes) {
          parser.write(String.fromCharCode(rune));
        }

        expect(handler.text, 'ok', reason: 'ESC $introducer');
        expect(handler.bells, 0, reason: 'ESC $introducer');
      }
    });

    test('CAN and SUB cancel a quarantined string', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1bPhidden\x18ok');
      parser.write('\x1b_hidden\x1ago');

      expect(handler.text, 'okgo');
    });

    test('CAN and SUB cancel CSI, OSC, and SCS', () {
      for (final cancel in ['\x18', '\x1a']) {
        final handler = _RecordingHandler();
        final parser = EscapeParser(handler);

        parser.write('\x1b[31${cancel}csi');
        parser.write('\x1b]0;title${cancel}osc');
        parser.write('\x1b(${cancel}scs');

        expect(handler.text, 'csioscscs');
        expect(handler.titles, isEmpty);
      }
    });
  });

  group('EscapeParser extended SGR colors', () {
    test('ignores truncated extended colors without throwing', () {
      for (final sequence in [
        '\x1b[38m',
        '\x1b[38;5m',
        '\x1b[38;2;1;2m',
        '\x1b[48m',
        '\x1b[48;5m',
        '\x1b[48;2;1;2m',
      ]) {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write(sequence);
        verifyNoMoreInteractions(handler);
      }
    });

    test('does not reinterpret malformed color tails as SGR commands', () {
      for (final sequence in [
        '\x1b[38;2;1;4m',
        '\x1b[48;2;1;4m',
        '\x1b[48;7;4m',
      ]) {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write(sequence);
        verifyNoMoreInteractions(handler);
      }
    });

    test('accepts extended color component boundaries', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[38;2;0;127;255;48;5;255m');

      verifyInOrder([
        handler.setForegroundColorRgb(0, 127, 255),
        handler.setBackgroundColor256(255),
      ]);
      verifyNoMoreInteractions(handler);
    });

    test('skips complete out-of-range colors and continues', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[38;5;256;4m');
      parser.write('\x1b[48;2;0;256;0;4m');

      verify(handler.setCursorUnderline()).called(2);
      verifyNoMoreInteractions(handler);
    });
  });

  group('EscapeParser debugger offsets', () {
    test('uses exclusive global rune offsets across split sequences', () {
      final debugger = TerminalDebugger();

      debugger.write('A\u{1f47b}');
      debugger.write('\x1b[');
      debugger.write('2');
      debugger.write('A');
      debugger.write('\x1b]0;title\x1b');
      debugger.write('\\Z');
      debugger.write('\x1b(0');
      debugger.write('\x1b[>4m');

      expect(
        debugger.commands
            .map((command) => (command.start, command.end, command.chars))
            .toList(),
        [
          (0, 1, 'A'),
          (1, 2, '\u{1f47b}'),
          (2, 6, '\x1b[2A'),
          (6, 17, '\x1b]0;title\x1b\\'),
          (17, 18, 'Z'),
          (18, 21, '\x1b(0'),
          (21, 26, '\x1b[>4m'),
        ],
      );
      expect(debugger.commands[3].explanation, hasLength(2));
      expect(
        debugger.getRecord(debugger.commands.last),
        'A\u{1f47b}\x1b[2A\x1b]0;title\x1b\\Z\x1b(0\x1b[>4m',
      );
    });

    test('discarded strings do not skew the following token', () {
      final debugger = TerminalDebugger();
      const discarded = '\x1bP\u{1f47b}hidden\x1b\\';

      debugger.write(discarded);
      debugger.write('X');

      expect(debugger.commands, hasLength(1));
      expect(debugger.commands.single.start, discarded.runes.length);
      expect(debugger.commands.single.end, discarded.runes.length + 1);
      expect(debugger.commands.single.chars, 'X');
    });
  });
}

/// Records the handler calls these tests assert on; everything else is a no-op.
class _RecordingHandler implements EscapeHandler {
  final _text = StringBuffer();
  final titles = <String>[];
  final resizes = <(int, int)>[];
  var bells = 0;
  var sizeQueries = 0;

  String get text => _text.toString();

  @override
  void writeChar(int char) => _text.writeCharCode(char);

  @override
  void setTitle(String name) => titles.add(name);

  @override
  void bell() => bells++;

  @override
  void resize(int cols, int rows) => resizes.add((cols, rows));

  @override
  void sendSize() => sizeQueries++;

  @override
  void noSuchMethod(Invocation invocation) {}
}

List<String> _trace(
  List<String> chunks, {
  int maxPendingSequenceLength = kMaxPendingSequenceLength,
}) {
  final handler = _TraceHandler();
  final parser = EscapeParser(
    handler,
    maxPendingSequenceLength: maxPendingSequenceLength,
  );
  for (final chunk in chunks) {
    parser.write(chunk);
  }
  return handler.events;
}

class _TraceHandler implements EscapeHandler {
  final events = <String>[];

  @override
  void noSuchMethod(Invocation invocation) {
    events.add(
      '${invocation.memberName}:'
      '${invocation.positionalArguments}:'
      '${invocation.namedArguments}',
    );
  }
}
