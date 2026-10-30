import 'dart:math';

import 'package:test/test.dart';
import 'package:xterm/src/terminal.dart';

/// The text of the logical line starting at row 0.
String _firstLine(Terminal terminal) {
  final lines = terminal.buffer.lines;
  final text = StringBuffer(lines[0].getText());
  for (var row = 1; row < lines.length && lines[row].isWrapped; row++) {
    text.write(lines[row].getText());
  }
  return text.toString();
}

/// Reflowing through any widths and back keeps a line's text, wide
/// characters included (PATCHES.md 43 to 45 and 48). Upstream 4.0.0
/// duplicated a cell at the end of such lines and hung at one column.
void main() {
  test('reflow() keeps a line\'s text through random resizes', () {
    const alphabet = 'ab/.c文档报二零';
    final random = Random(7);
    for (var n = 0; n < 2000; n++) {
      final length = 1 + random.nextInt(30);
      final text = String.fromCharCodes([
        for (var i = 0; i < length; i++)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);
      final terminal = Terminal();
      final widths = [1 + random.nextInt(41)];
      terminal.resize(widths.first, 10);
      terminal.write(text);
      for (var k = 0; k < 4; k++) {
        widths.add(1 + random.nextInt(46));
        terminal.resize(widths.last, 10);
      }
      terminal.resize(80, 10);

      expect(_firstLine(terminal), text, reason: 'widths $widths');
    }
  });
}
