import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Regression cover for the hang fixed in the vendored xterm fork (see
/// `third_party/xterm/PATCHES.md`). An OSC closes only on BEL or ESC, so a
/// stray `ESC ]` in shell output — a log with captured escapes, a binary, a
/// program killed mid-title — opened a sequence that never finished. Every
/// later byte was pinned on the parser's queue and the whole run re-parsed on
/// every write: quadratic time and unbounded memory. The incremental parser
/// now retains at most one bounded OSC and quarantines overflow through BEL or
/// ST, so remote payload cannot become executable terminal text.
///
/// These live in the app rather than in `third_party/xterm/test/` (which has
/// its own, finer-grained cases) because CI runs the app's suite and does not
/// run the vendored package's.
void main() {
  /// Enough output to carry the pending run past the cap, delivered in the
  /// chunks an SSH stream arrives in rather than one giant write.
  void writeChunked(Terminal terminal, int bytes) {
    const chunk = 4096;
    for (var written = 0; written < bytes; written += chunk) {
      terminal.write('x' * chunk);
    }
  }

  test('an OSC that never closes cannot wedge the terminal', () {
    final terminal = Terminal();
    terminal.write('\x1b]0;');

    writeChunked(terminal, kMaxPendingSequenceLength * 4);
    terminal.write('\x07\r\nrecovered\r\n');

    expect(terminal.buffer.getText(), contains('recovered'));
  });

  test('a CSI cannot accumulate an unbounded pending run', () {
    final terminal = Terminal();
    // Digits and `;` are the only bytes that keep a CSI open, so a runaway CSI
    // is far harder to hit than a runaway OSC — but it accumulated the same
    // way. The explicit final byte is swallowed with the oversized sequence;
    // text after it must resume normally.
    terminal.write('\x1b[${'1;' * kMaxPendingSequenceLength}');
    terminal.write('m');
    terminal.write('\r\nrecovered\r\n');

    expect(terminal.buffer.getText(), contains('recovered'));
  });

  test('an over-cap OSC swallows its terminator, then resumes normally', () {
    final terminal = Terminal();
    var bells = 0;
    terminal.onBell = () => bells++;

    terminal.write('\x1b]0;');
    writeChunked(terminal, kMaxPendingSequenceLength * 2);
    terminal.write('\x07');

    expect(bells, 0);

    terminal.write('\x07');
    expect(bells, 1);
  });

  test('a title split across writes still arrives intact', () {
    final terminal = Terminal();
    String? title;
    terminal.onTitleChange = (value) => title = value;

    // The cap must not break the ordinary case it guards: a real sequence
    // straddling a chunk boundary still waits for its remainder.
    terminal.write('\x1b]0;my ti');
    expect(title, isNull);

    terminal.write('tle\x07');
    expect(title, 'my title');
  });

  test(
    'unsupported control strings cannot execute embedded terminal input',
    () {
      final terminal = Terminal();
      var bells = 0;
      terminal.onBell = () => bells++;

      terminal.write('\x1bPdiscarded\x07\r\n\x1b[31m\x1b');
      terminal.write('\\visible');

      expect(bells, 0);
      expect(terminal.buffer.getText(), contains('visible'));
      expect(terminal.buffer.getText(), isNot(contains('discarded')));
    },
  );

  test('remote resize is ignored but local resize and size query remain', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add)..resize(80, 24);

    terminal.write('\x1b[8;10;20t');
    expect((terminal.viewWidth, terminal.viewHeight), (80, 24));

    terminal.write('\x1b[18t');
    expect(output, ['\x1b[8;24;80t']);
  });
}
