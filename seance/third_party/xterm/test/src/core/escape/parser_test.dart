import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.resize(80, 24));
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
      parser.write('\x1b[>6n'); // XTMODKEYS: disable
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

  /// [seance fork] An escape sequence that never terminates used to be held on
  /// the queue forever and re-parsed in full on every write — quadratic time
  /// and unbounded memory, which wedged the terminal for the rest of the
  /// session. See PATCHES.md.
  ///
  /// These use a recording handler rather than a mock: the assertions are
  /// about what did and did not reach the terminal across several writes,
  /// which reads better as accumulated state than as a pile of verifies.
  group('EscapeParser pending-sequence cap', () {
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
      // Dropped rather than rendered, and never reported as a title.
      expect(handler.text, isEmpty);
      expect(handler.titles, isEmpty);
    });

    test('resumes ordinary output after abandoning', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler, maxPendingSequenceLength: 64);

      parser.write(osc0(200));
      parser.write('ok');
      expect(handler.text, 'ok');
    });

    test('a later terminator lands normally once the run is abandoned', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler, maxPendingSequenceLength: 64);

      parser.write(osc0(200));
      // The sequence this BEL was meant to close is gone, so it rings the bell
      // and the text after it renders as text.
      parser.write('\x07hi');
      expect(handler.bells, 1);
      expect(handler.text, 'hi');
    });

    test('caps an unterminated CSI too', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler, maxPendingSequenceLength: 64);

      // Digits and `;` are the only bytes that keep a CSI open.
      parser.write('\x1b[${'1;' * 100}');
      expect(handler.text, isEmpty);

      parser.write('ok');
      expect(handler.text, 'ok');
    });

    test('drops one cap\'s worth, not the whole stream', () {
      final handler = _RecordingHandler();
      final parser = EscapeParser(handler, maxPendingSequenceLength: 64);

      parser.write('\x1b]0;');
      // Chunked the way an SSH stream arrives: the run is abandoned as soon as
      // it crosses the cap, so all but that much of the output still renders.
      for (var i = 0; i < 20; i++) {
        parser.write('a' * 32);
      }
      expect(handler.text.length, greaterThan(20 * 32 - 64 - 32));
    });
  });
}

/// Records the handler calls these tests assert on; everything else is a no-op.
class _RecordingHandler implements EscapeHandler {
  final _text = StringBuffer();
  final titles = <String>[];
  var bells = 0;

  String get text => _text.toString();

  @override
  void writeChar(int char) => _text.writeCharCode(char);

  @override
  void setTitle(String name) => titles.add(name);

  @override
  void bell() => bells++;

  @override
  void noSuchMethod(Invocation invocation) {}
}
