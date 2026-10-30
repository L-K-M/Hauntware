import 'package:test/test.dart';
import 'package:xterm/src/terminal.dart';

void main() {
  /// The text of every buffer line, top to bottom.
  List<String> rows(Terminal terminal) {
    final lines = terminal.buffer.lines;
    return [for (var i = 0; i < lines.length; i++) lines[i].toString()];
  }

  test('reflow() keeps the order of a scrollback that has wrapped', () {
    final terminal = Terminal(maxLines: 40);
    terminal.resize(10, 5);
    for (var i = 0; i < 30; i++) {
      terminal.write('row$i-xxxxxxxxxx\r\n');
    }
    terminal.resize(30, 5);

    // The first row is the tail of a line whose start the ring evicted.
    final text = rows(terminal).where((row) => row.startsWith('row')).toList();
    expect(text.last, 'row29-xxxxxxxxxx');
    expect(text, everyElement(endsWith('-xxxxxxxxxx')));
    final numbers = [
      for (final row in text)
        int.parse(RegExp(r'^row(\d+)').firstMatch(row)![1]!),
    ];
    expect(numbers, [for (var i = numbers.first; i < 30; i++) i]);

    terminal.resize(20, 5);
    expect(
        rows(terminal).where((row) => row.isNotEmpty).last, 'row29-xxxxxxxxxx');
  });

  test('reflow() keeps the rows left after the scrollback is cleared', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(20, 5);
    for (var i = 0; i < 12; i++) {
      terminal.write('line $i\r\n');
    }
    // CSI 3J drops the scrollback above the screen.
    terminal.write('\x1b[3J');
    terminal.resize(30, 5);

    expect(rows(terminal).take(4), ['line 8', 'line 9', 'line 10', 'line 11']);
  });

  test('reflow() can reflow a single line', () {
    final terminal = Terminal();

    terminal.write('1234567890abcdefg');
    terminal.resize(10, 10);

    expect(terminal.buffer.lines[0].toString(), '1234567890');
    expect(terminal.buffer.lines[1].toString(), 'abcdefg');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);

    terminal.resize(13, 10);

    expect(terminal.buffer.lines[0].toString(), '1234567890abc');
    expect(terminal.buffer.lines[1].toString(), 'defg');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);

    terminal.resize(20, 10);

    expect(terminal.buffer.lines[0].toString(), '1234567890abcdefg');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
  });

  test('reflow() can reflow a single line to multiple lines', () {
    final terminal = Terminal();

    terminal.write('1234567890abcdefg');
    terminal.resize(5, 10);

    expect(terminal.buffer.lines[0].toString(), '12345');
    expect(terminal.buffer.lines[1].toString(), '67890');
    expect(terminal.buffer.lines[2].toString(), 'abcde');
    expect(terminal.buffer.lines[3].toString(), 'fg');

    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);
    expect(terminal.buffer.lines[2].isWrapped, isTrue);
    expect(terminal.buffer.lines[3].isWrapped, isTrue);

    terminal.resize(6, 10);

    expect(terminal.buffer.lines[0].toString(), '123456');
    expect(terminal.buffer.lines[1].toString(), '7890ab');
    expect(terminal.buffer.lines[2].toString(), 'cdefg');

    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);
    expect(terminal.buffer.lines[2].isWrapped, isTrue);
  });

  test('reflow() keeps a wide character at the edge whole when widening', () {
    final terminal = Terminal();

    // At width 8 the third wide character sits in the last column, with
    // its second cell at the start of the next row.
    terminal.resize(8, 10);
    terminal.write('abc文档报x');
    terminal.resize(12, 10);

    final line = terminal.buffer.lines[0];
    final cells = [
      for (var i = 0; i < 10; i++)
        line.getCodePoint(i) == 0
            ? '_'
            : String.fromCharCode(line.getCodePoint(i)),
    ];
    // No empty copy of the second cell between the characters.
    expect(cells.join(), 'abc文_档_报_x');
  });

  /// The text of the logical line starting at row 0: its rows, wrapped
  /// ones joined, with a wide character's second cell left out.
  String firstLine(Terminal terminal) {
    final lines = terminal.buffer.lines;
    final text = StringBuffer(lines[0].getText());
    for (var row = 1; row < lines.length && lines[row].isWrapped; row++) {
      text.write(lines[row].getText());
    }
    return text.toString();
  }

  for (final (text, from, to) in [
    ('/srv报/abc报', 11, 6),
    ('Saved  /home/me/projects/会议记录/二零二六年十月', 47, 24),
    ('Saved  /home/me/projects/会议记录/二零二六年十月', 47, 34),
    ('Saved /home/me/docs/文档/报告', 14, 16),
  ]) {
    test(
        'reflow() keeps a line ending in a wide character at the edge '
        'whole ($from -> $to)', () {
      final terminal = Terminal();
      terminal.resize(from, 10);
      terminal.write(text);
      terminal.resize(to, 10);

      expect(firstLine(terminal), text);
      // No empty row inside the line: read cell by cell, one would be a
      // gap in the text.
      final lines = terminal.buffer.lines;
      for (var row = 1; row < lines.length && lines[row].isWrapped; row++) {
        expect(lines[row].getTrimmedLength(), isPositive, reason: 'row $row');
      }
    });
  }

  test('reflow() through one column keeps wide characters whole', () {
    final terminal = Terminal();
    terminal.resize(80, 24);
    terminal.write('cat /srv/文档/a.txt\r\n\$ ');
    terminal.resize(1, 24);
    terminal.resize(80, 24);

    expect(firstLine(terminal), 'cat /srv/文档/a.txt');
  });

  test('reflow() widens a line whose wrapped rows were erased', () {
    final terminal = Terminal();
    terminal.resize(60, 10);
    // ECH blanks both rows of a wrapped line and, unlike EL, keeps the
    // second one wrapped.
    terminal.write('${'a' * 61}\r\x1b[60X\x1b[A\x1b[60X\x1b[3B\$ ');
    terminal.resize(200, 10);

    expect(terminal.viewWidth, 200);
  });

  test('reflow() through one column keeps a line that starts wide', () {
    for (final (width, text, back) in [
      (40, '文c零报', 80),
      (39, '零报二c', 18),
      (80, '文档 is here', 80),
    ]) {
      final terminal = Terminal();
      terminal.resize(width, 10);
      terminal.write('$text\r\n\$ ');
      terminal.resize(1, 10);
      terminal.resize(back, 10);

      expect(rows(terminal).take(2), [text, r'$ '], reason: text);
      expect(terminal.buffer.lines[0].isWrapped, isFalse, reason: text);
    }
  });

  test('reflow() to one column with a wide character finishes', () {
    final terminal = Terminal();
    terminal.resize(49, 6);
    terminal.write('文\r\n');
    terminal.resize(1, 7);

    final lines = terminal.buffer.lines;
    expect(
      [for (var i = 0; i < lines.length; i++) lines[i].getCodePoint(0)],
      contains('文'.runes.single),
    );
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('reflow() can reflow wide characters', () {
    final terminal = Terminal();

    terminal.write('床前明月光疑是地上霜');
    terminal.resize(10, 10);

    expect(terminal.buffer.lines[0].toString(), '床前明月光');
    expect(terminal.buffer.lines[1].toString(), '疑是地上霜');

    terminal.resize(9, 10);

    expect(terminal.buffer.lines[0].toString(), '床前明月');
    expect(terminal.buffer.lines[1].toString(), '光疑是地');
    expect(terminal.buffer.lines[2].toString(), '上霜');

    terminal.resize(11, 10);

    expect(terminal.buffer.lines[0].toString(), '床前明月光');
    expect(terminal.buffer.lines[1].toString(), '疑是地上霜');

    terminal.resize(13, 10);
    expect(terminal.buffer.lines[0].toString(), '床前明月光疑');
    expect(terminal.buffer.lines[1].toString(), '是地上霜');
  });

  test('lines has correct length after reflow', () {
    final terminal = Terminal();

    terminal.write('1234567890abcdefg');
    terminal.resize(10, 10);

    for (var i = 0; i < 10; i++) {
      expect(terminal.buffer.lines[i].length, 10);
    }

    terminal.resize(13, 10);
    for (var i = 0; i < 10; i++) {
      expect(terminal.buffer.lines[i].length, 13);
    }
  });
}
