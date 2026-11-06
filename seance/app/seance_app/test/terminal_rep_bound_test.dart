import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// App-suite coverage for the bounded REP patch in the vendored xterm fork.
/// CI does not normally run `third_party/xterm`'s own package tests.
void main() {
  test('remote REP output is bounded by the visible scrolling region', () {
    final terminal = Terminal()..resize(8, 4);

    terminal.write('x\x1b[1000000b');

    final repeated = terminal.buffer
        .getText()
        .runes
        .where((value) => value == 0x78)
        .length;
    expect(repeated, 1 + 8 * 4);
  });

  test('remote REP cannot repeatedly copy a tall scrolling region', () {
    final terminal = Terminal(maxLines: 512)..resize(1, 512);

    // The host owns viewport sizing; remote resize controls are ignored.
    terminal.write(
      '\x1b[2;512r'
      '\x1b[3;1HB'
      '\x1b[512;1H'
      'x\x1b[999999999b',
    );

    final output = terminal.buffer.getText().runes;
    expect(output.where((value) => value == 0x78).length, 1);
    expect(output.where((value) => value == 0x42).length, 1);
  });
}
