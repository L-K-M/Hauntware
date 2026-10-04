import 'package:test/test.dart';
import 'package:planchette_core/planchette_core.dart';

List<(String, SyntaxTokenType)> _tokens(String text) => [
  for (final token in tokenizeSyntax(text, syntaxLanguageFor('config.env')!))
    (text.substring(token.start, token.end), token.type),
];

void main() {
  group('dotenv detection', () {
    for (final path in [
      '.env',
      '/srv/app/.env',
      '.env.local',
      '.env.production.local',
      '.env.example',
      'config.env',
      r'C:\project\.env',
      r'C:\project\.env.local',
    ]) {
      test('recognizes $path', () {
        expect(syntaxLanguageFor(path)?.id, 'dotenv');
      });
    }

    test('does not capture similarly named files or parent directories', () {
      expect(syntaxLanguageFor('.environment'), isNull);
      expect(syntaxLanguageFor('.envrc'), isNull);
      expect(syntaxLanguageFor('/srv/.env/config.json')?.id, 'json');
      expect(syntaxLanguageFor(r'C:\.env\config.json')?.id, 'json');
    });
  });

  group('dotenv tokens', () {
    test('keys and export prefixes have exact independent ranges', () {
      const text =
          '  export port = 3000\nexport export=value\nexport=literal\n';
      expect(_tokens(text), [
        ('export', SyntaxTokenType.keyword),
        ('port', SyntaxTokenType.meta),
        ('export', SyntaxTokenType.keyword),
        ('export', SyntaxTokenType.meta),
        ('export', SyntaxTokenType.meta),
      ]);
      final tokens = tokenizeSyntax(text, syntaxLanguageFor('config.env')!);
      expect(tokens[1].start, text.indexOf('port ='));
      expect(tokens[3].start, text.indexOf('export=value'));
    });

    test('bare values stay text and semicolons are literal', () {
      expect(
        _tokens('PORT=3000\nDEBUG=true\nEMPTY=\nTEXT=if then export ; 42'),
        [
          ('PORT', SyntaxTokenType.meta),
          ('DEBUG', SyntaxTokenType.meta),
          ('EMPTY', SyntaxTokenType.meta),
          ('TEXT', SyntaxTokenType.meta),
        ],
      );
    });

    test('hashes start comments outside quoted values', () {
      expect(_tokens('# header\nA=value# inline\nB="a#b" # tail\nC= # empty'), [
        ('# header', SyntaxTokenType.comment),
        ('A', SyntaxTokenType.meta),
        ('# inline', SyntaxTokenType.comment),
        ('B', SyntaxTokenType.meta),
        ('"a#b"', SyntaxTokenType.string),
        ('# tail', SyntaxTokenType.comment),
        ('C', SyntaxTokenType.meta),
        ('# empty', SyntaxTokenType.comment),
      ]);
    });

    test('quotes inside bare values do not hide following assignments', () {
      expect(_tokens('NAME=O\'Brien\nJSON={"name":"example"}\nNEXT=value'), [
        ('NAME', SyntaxTokenType.meta),
        ('JSON', SyntaxTokenType.meta),
        ('NEXT', SyntaxTokenType.meta),
      ]);
    });

    for (final quote in ["'", '"']) {
      test('$quote quoted values span lines and suppress inner syntax', () {
        final value = '${quote}first\nINNER=no\n# still string\nlast$quote';
        expect(_tokens('MULTI=$value\nNEXT=value'), [
          ('MULTI', SyntaxTokenType.meta),
          (value, SyntaxTokenType.string),
          ('NEXT', SyntaxTokenType.meta),
        ]);
      });
    }

    test('escaped quotes and backslashes preserve the value boundary', () {
      const value = r'"a\"b\\"';
      expect(_tokens('KEY=$value # tail\nNEXT=x'), [
        ('KEY', SyntaxTokenType.meta),
        (value, SyntaxTokenType.string),
        ('# tail', SyntaxTokenType.comment),
        ('NEXT', SyntaxTokenType.meta),
      ]);
    });

    test('unfinished multiline values retain their contents as strings', () {
      expect(_tokens('KEY="unfinished\nNEXT=value\n# content'), [
        ('KEY', SyntaxTokenType.meta),
        ('"unfinished\nNEXT=value\n# content', SyntaxTokenType.string),
      ]);
    });

    test('BOM, CRLF, empty lines and Unicode retain valid offsets', () {
      const text = '\ufeff# header\r\n\r\nEMOJI="👻"\r\nNEXT=value\r\n';
      expect(_tokens(text), [
        ('# header', SyntaxTokenType.comment),
        ('EMOJI', SyntaxTokenType.meta),
        ('"👻"', SyntaxTokenType.string),
        ('NEXT', SyntaxTokenType.meta),
      ]);
      var end = 0;
      for (final token in tokenizeSyntax(
        text,
        syntaxLanguageFor('config.env')!,
      )) {
        expect(token.start, greaterThanOrEqualTo(end));
        expect(token.end, greaterThan(token.start));
        expect(token.end, lessThanOrEqualTo(text.length));
        end = token.end;
      }
    });
  });
}
