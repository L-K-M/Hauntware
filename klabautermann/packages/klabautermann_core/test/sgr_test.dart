import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

const _esc = '\x1b';
const _red = SgrStyle(foreground: SgrPaletteColor(1));
const _bold = SgrStyle(bold: true);

/// `ESC [ <params> m`.
String _sgr(String params) => '$_esc[${params}m';

void main() {
  group('parseSgr (03 §10.8)', () {
    test('plain text comes back as it is, without spans', () {
      const line = 'GET /health 200\t12 ms ünïcode 😀';
      final result = parseSgr(line);

      expect(identical(result.text, line), isTrue);
      expect(result.spans, isEmpty);
    });

    test('offsets index the visible text, escapes removed', () {
      final result = parseSgr('ok ${_sgr('31')}fail${_sgr('0')} done');

      expect(result.text, 'ok fail done');
      expect(result.spans, [const SgrSpan(3, 7, _red)]);
    });

    test('ESC[m, ESC[0m and an empty parameter reset', () {
      expect(parseSgr('${_sgr('1')}a${_sgr('')}b').spans, [
        const SgrSpan(0, 1, _bold),
      ]);
      expect(parseSgr('${_sgr('1')}a${_sgr('0')}b').spans, [
        const SgrSpan(0, 1, _bold),
      ]);
      // `ESC[;4m` is 0 then 4: the reset clears bold, then underline.
      expect(parseSgr('${_sgr('1')}a${_sgr(';4')}b').spans, [
        const SgrSpan(0, 1, _bold),
        const SgrSpan(1, 2, SgrStyle(underline: true)),
      ]);
    });

    test('several parameters combine in one sequence', () {
      final result = parseSgr('${_sgr('1;3;4;7;9;31;42')}x');

      expect(result.spans, [
        const SgrSpan(
          0,
          1,
          SgrStyle(
            foreground: SgrPaletteColor(1),
            background: SgrPaletteColor(2),
            bold: true,
            italic: true,
            underline: true,
            inverse: true,
            strikethrough: true,
          ),
        ),
      ]);
    });

    test('each attribute has its own reset; 22 clears bold and faint', () {
      final result = parseSgr(
        '${_sgr('1;2;3;4;7;9;31;41')}a'
        '${_sgr('22')}b${_sgr('23;24')}c${_sgr('27;29')}d${_sgr('39;49')}e',
      );

      expect(result.text, 'abcde');
      expect(result.spans.map((span) => span.style), [
        const SgrStyle(
          foreground: SgrPaletteColor(1),
          background: SgrPaletteColor(1),
          bold: true,
          faint: true,
          italic: true,
          underline: true,
          inverse: true,
          strikethrough: true,
        ),
        const SgrStyle(
          foreground: SgrPaletteColor(1),
          background: SgrPaletteColor(1),
          italic: true,
          underline: true,
          inverse: true,
          strikethrough: true,
        ),
        const SgrStyle(
          foreground: SgrPaletteColor(1),
          background: SgrPaletteColor(1),
          inverse: true,
          strikethrough: true,
        ),
        const SgrStyle(
          foreground: SgrPaletteColor(1),
          background: SgrPaletteColor(1),
        ),
      ]);
    });

    test('bright colours map to palette 8 to 15', () {
      expect(
        parseSgr('${_sgr('97;100')}x').spans.single.style,
        const SgrStyle(
          foreground: SgrPaletteColor(15),
          background: SgrPaletteColor(8),
        ),
      );
    });

    group('extended colours', () {
      test('256 colours in the semicolon and colon forms', () {
        expect(
          parseSgr('${_sgr('38;5;208;48;5;17')}x').spans.single.style,
          const SgrStyle(
            foreground: SgrPaletteColor(208),
            background: SgrPaletteColor(17),
          ),
        );
        expect(
          parseSgr('${_sgr('38:5:208')}x').spans.single.style,
          const SgrStyle(foreground: SgrPaletteColor(208)),
        );
      });

      test('true colour in the semicolon form and both colon forms', () {
        const orange = SgrStyle(foreground: SgrRgbColor(255, 128, 0));

        expect(
          parseSgr('${_sgr('38;2;255;128;0')}x').spans.single.style,
          orange,
        );
        // ITU T.416 puts a colour space id first; it is empty or ignored.
        expect(
          parseSgr('${_sgr('38:2::255:128:0')}x').spans.single.style,
          orange,
        );
        expect(
          parseSgr('${_sgr('38:2:0:255:128:0')}x').spans.single.style,
          orange,
        );
        // The common short form without the colour space.
        expect(
          parseSgr('${_sgr('38:2:255:128:0')}x').spans.single.style,
          orange,
        );
        expect(
          parseSgr('${_sgr('48;2;1;2;3')}x').spans.single.style,
          const SgrStyle(background: SgrRgbColor(1, 2, 3)),
        );
      });

      test('an out-of-range value is ignored but its components are '
          'consumed', () {
        // Without consuming, 300 and the RGB values would be read as
        // attributes; only the trailing 1 (bold) may apply.
        expect(parseSgr('${_sgr('38;5;300;1')}x').spans.single.style, _bold);
        expect(
          parseSgr('${_sgr('38;2;256;0;0;1')}x').spans.single.style,
          _bold,
        );
        expect(parseSgr('${_sgr('38:5:999;1')}x').spans.single.style, _bold);
      });

      test('a truncated colour applies nothing else', () {
        expect(parseSgr('${_sgr('38;5')}x').spans, isEmpty);
        expect(parseSgr('${_sgr('38;2;1;2')}x').spans, isEmpty);
        expect(parseSgr('${_sgr('38')}x').spans, isEmpty);
        // An unknown colour mode (T.416's CMY) ends the sequence, so its
        // components are not read as attributes either.
        expect(parseSgr('${_sgr('38;3;4;5;9')}x').spans, isEmpty);
      });

      test('underline colour (58) is consumed and ignored', () {
        expect(parseSgr('${_sgr('58;5;4;1')}x').spans.single.style, _bold);
        expect(parseSgr('${_sgr('58;2;7;8;9;1')}x').spans.single.style, _bold);
        expect(
          parseSgr('${_sgr('58:2::1:2:3;59;1')}x').spans.single.style,
          _bold,
        );
      });
    });

    test('underline styles: 4:0 is off, 4:3 and 21 are on', () {
      const underlined = SgrStyle(underline: true);

      expect(parseSgr('${_sgr('4:3')}x').spans.single.style, underlined);
      expect(parseSgr('${_sgr('21')}x').spans.single.style, underlined);
      expect(parseSgr('${_sgr('4')}a${_sgr('4:0')}b').spans, [
        const SgrSpan(0, 1, underlined),
      ]);
    });

    test('blink and conceal are ignored, so text is never hidden', () {
      final result = parseSgr('${_sgr('5;6;8')}secret${_sgr('28;25')}');

      expect(result.text, 'secret');
      expect(result.spans, isEmpty);
    });

    test('a huge parameter neither overflows nor applies', () {
      final result = parseSgr(
        '${_sgr('99999999999999999999999999;1')}x'
        '${_sgr('38;5;99999999999999999999')}y',
      );

      expect(result.text, 'xy');
      expect(result.spans, [const SgrSpan(0, 2, _bold)]);
    });

    group('everything but SGR is dropped', () {
      test('cursor, erase and mode sequences', () {
        final result = parseSgr(
          '$_esc[2J$_esc[1;1H$_esc[Ka$_esc[?25l$_esc[?1049hb$_esc[4 qc',
        );

        expect(result.text, 'abc');
        expect(result.spans, isEmpty);
      });

      test('a CSI ending in m with a private marker or intermediate is not '
          'SGR', () {
        // xterm's modifyOtherKeys (`CSI > 4 ; 2 m`) must not underline.
        final result = parseSgr('$_esc[>4;2ma$_esc[?1mb$_esc[1 mc');

        expect(result.text, 'abc');
        expect(result.spans, isEmpty);
      });

      test('OSC 52 clipboard writes, with either terminator', () {
        final result = parseSgr(
          'a$_esc]52;c;aGVsbG8=\x07b$_esc]52;c;d29ybGQ=$_esc\\c',
        );

        expect(result.text, 'abc');
      });

      test('OSC 8 hyperlinks keep only their visible text', () {
        final result = parseSgr(
          'see $_esc]8;;https://evil.example/$_esc\\docs$_esc]8;;$_esc\\ now',
        );

        expect(result.text, 'see docs now');
      });

      test('an escape ends an OSC and is read itself', () {
        final result = parseSgr('$_esc]0;title${_sgr('31')}red');

        expect(result.text, 'red');
        expect(result.spans, [const SgrSpan(0, 3, _red)]);
      });

      test('DCS, SOS, PM and APC strings up to ST', () {
        final result = parseSgr(
          'a${_esc}Pq#0;2;0;0;0$_esc\\b${_esc}Xsos$_esc\\c'
          '$_esc^pm$_esc\\d${_esc}_apc$_esc\\e',
        );

        expect(result.text, 'abcde');
      });

      test('two-character and charset escapes', () {
        expect(parseSgr('${_esc}7a${_esc}cb$_esc(Bc$_esc#8d').text, 'abcd');
      });

      test('C0 controls but tab, DEL and C1 controls', () {
        final result = parseSgr('a\rb\bc\x07d\x00e\x7Ff\u0085g\th\u009b31m');

        // C1 controls are dropped, not read as 8-bit CSI or OSC
        // introducers, so the `31m` after U+009B stays visible text.
        expect(result.text, 'abcdefg\th31m');
        expect(result.spans, isEmpty);
      });
    });

    group('broken and truncated sequences', () {
      test('a sequence cut at the end of the line is dropped', () {
        expect(parseSgr('ok $_esc[38;2;1').text, 'ok ');
        expect(parseSgr('ok $_esc').text, 'ok ');
        expect(parseSgr('ok $_esc]8;;https://example').text, 'ok ');
        expect(parseSgr('ok ${_esc}Pdata').text, 'ok ');
        expect(parseSgr('ok $_esc(').text, 'ok ');
      });

      test('a CSI broken by a character it cannot hold is abandoned and '
          'the character kept', () {
        final result = parseSgr('$_esc[31ébad$_esc[3\x1b[1mbold');

        expect(result.text, 'ébadbold');
        expect(result.spans, [const SgrSpan(4, 8, _bold)]);
      });

      test('a C0 control or DEL inside a sequence is dropped and the '
          'sequence goes on', () {
        // As in xterm and VTE, which execute the control (DEL is ignored)
        // without leaving the sequence.
        for (final (line, style) in [
          ('$_esc[3\b1mX', _red),
          ('$_esc\b[31mX', _red),
          ('$_esc[31\rmX', _red),
          ('$_esc[1\x7FmX', _bold),
        ]) {
          final result = parseSgr(line);
          expect(result.text, 'X', reason: line);
          expect(result.spans, [SgrSpan(0, 1, style)], reason: line);
        }
        expect(parseSgr('a$_esc(\nBb').text, 'ab');
      });

      test('CAN and SUB cancel a sequence', () {
        for (final cancel in ['\x18', '\x1A']) {
          final result = parseSgr('$_esc[31${cancel}mX');

          expect(result.text, 'mX');
          expect(result.spans, isEmpty);
        }
      });

      test('an escape before a non-ASCII character drops only itself', () {
        expect(parseSgr('$_escé').text, 'é');
      });
    });

    group('spans', () {
      test('no empty spans; style left set at the end adds nothing', () {
        final result = parseSgr('${_sgr('31')}${_sgr('32')}a${_sgr('1')}');

        expect(result.spans, [
          const SgrSpan(0, 1, SgrStyle(foreground: SgrPaletteColor(2))),
        ]);
      });

      test('the same style selected again continues one span', () {
        final result = parseSgr('${_sgr('31')}a${_sgr('1')}${_sgr('22')}b');

        expect(result.spans, [const SgrSpan(0, 2, _red)]);
      });

      test('each line starts plain: nothing carries over', () {
        expect(parseSgr('${_sgr('31')}first').spans, [
          const SgrSpan(0, 5, _red),
        ]);
        expect(parseSgr('second').spans, isEmpty);
      });

      test('surrogate pairs stay whole inside a span', () {
        final result = parseSgr('${_sgr('1')}😀${_sgr('0')}!');

        expect(result.text, '😀!');
        expect(result.spans, [const SgrSpan(0, 2, _bold)]);
      });
    });
  });
}
