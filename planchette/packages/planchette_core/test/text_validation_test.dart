import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

/// Each problem as its kind, the text it flags, and its subject and related
/// line when it has them, so expectations read like the document.
List<String> _problems(String text, TextFormat? format) => [
  for (final problem in validateText(text, format))
    [
      problem.kind.name,
      problem.severity.name,
      text.substring(problem.start, problem.end),
      ?problem.subject,
      if (problem.counterpart case final counterpart?) 'closes $counterpart',
      if (problem.relatedLine case final line?) 'line $line',
      ?problem.detail,
    ].join(' | '),
];

TextFormat? _format(String path) =>
    textFormatFor(path, syntaxLanguageFor(path));

void main() {
  group('format choice', () {
    test('follows the language and the path', () {
      expect(_format('/srv/app/.env'), TextFormat.dotenv);
      expect(_format('config.env'), TextFormat.dotenv);
      expect(_format('package.json'), TextFormat.json);
      expect(_format('notes.jsonc'), TextFormat.jsonWithComments);
      expect(_format('docker-compose.yml'), TextFormat.yaml);
      expect(_format('Cargo.toml'), TextFormat.toml);
      expect(_format('pom.xml'), TextFormat.xml);
      expect(_format('icon.svg'), TextFormat.xml);
      expect(_format('Info.plist'), TextFormat.xml);
    });

    test('reads comments in the JSON files whose readers allow them', () {
      for (final path in [
        'tsconfig.json',
        'web/tsconfig.app.json',
        'jsconfig.base.json',
        '.devcontainer/devcontainer.json',
        'deno.json',
        '/repo/.vscode/settings.json',
        r'C:\repo\.vscode\launch.json',
        '/home/me/.config/Code/User/settings.json',
      ]) {
        expect(_format(path), TextFormat.jsonWithComments, reason: path);
      }
      expect(_format('/srv/app/settings.json'), TextFormat.json);
      expect(_format('tasks.json'), TextFormat.json);
    });

    test('leaves formats without a dependable check alone', () {
      // INI dialects repeat keys by design; HTML is not XML.
      for (final path in [
        'app.service',
        'sshd_config',
        '.gitconfig',
        'settings.ini',
        'index.html',
        'page.htm',
        'main.dart',
        'script.sh',
        'README.md',
        'notes.txt',
      ]) {
        expect(_format(path), isNull, reason: path);
      }
    });
  });

  group('conflict markers', () {
    const conflict =
        'a = 1\n'
        '<<<<<<< HEAD\n'
        'b = 2\n'
        '=======\n'
        'b = 3\n'
        '>>>>>>> feature\n';

    test('flag each conflict once, at its opening marker', () {
      expect(_problems(conflict, null), [
        'mergeConflict | error | <<<<<<< HEAD',
      ]);
      expect(_problems('$conflict$conflict', null), hasLength(2));
    });

    test('are reported alone, before any format check', () {
      expect(_problems('{"a": 1,\n$conflict}', TextFormat.json), [
        'mergeConflict | error | <<<<<<< HEAD',
      ]);
    });

    test('accept diff3 base sections and CRLF lines', () {
      const diff3 =
          '<<<<<<< ours\r\nx\r\n||||||| base\r\ny\r\n=======\r\nz\r\n>>>>>>> theirs\r\n';
      expect(_problems(diff3, null), ['mergeConflict | error | <<<<<<< ours']);
    });

    test('need all three markers at the start of a line', () {
      expect(_problems('Title\n=======\n', null), isEmpty);
      expect(_problems('<<<<<<< HEAD\nonly the start\n', null), isEmpty);
      expect(_problems('<<<<<<<< x\n=======\n>>>>>>>> y\n', null), isEmpty);
      expect(_problems(' <<<<<<< x\n=======\n>>>>>>> y\n', null), isEmpty);
    });
  });

  group('JSON', () {
    test('a valid or blank document has no problems', () {
      expect(
        _problems('{"a": [1, 2.5e3, true, null, "x"]}', TextFormat.json),
        isEmpty,
      );
      expect(_problems('', TextFormat.json), isEmpty);
      expect(_problems('  \n', TextFormat.json), isEmpty);
    });

    test('flags the first syntax error at the token', () {
      expect(_problems('{"a": 1 "b": 2}', TextFormat.json), [
        "syntaxError | error | \" | expected ',' or '}'",
      ]);
      expect(_problems('{"a": tru}', TextFormat.json), [
        'syntaxError | error | tru | expected a value',
      ]);
      expect(_problems('[1, 2', TextFormat.json), [
        "syntaxError | error | 2 | expected ',' or ']'",
      ]);
    });

    test('flags a string that a line break cut short from its quote', () {
      expect(_problems('{"name": "Ada\n}', TextFormat.json), [
        'syntaxError | error | "Ada | unescaped control character',
      ]);
    });

    test('flags each repeated key after the first, decoded', () {
      const text = '{\n  "a": 1,\n  "b": {"a": 2},\n  "\\u0061": 3\n}';
      expect(_problems(text, TextFormat.json), [
        'duplicateKey | warning | "\\u0061" | a | line 2',
      ]);
    });

    test('reads past comments and trailing commas, reporting them', () {
      const text = '{\n  // port\n  "a": 1, /* x */\n  "b": [1,],\n}';
      expect(_problems(text, TextFormat.json), [
        'jsonComment | warning | // port',
        'jsonComment | warning | /* x */',
        'jsonTrailingComma | warning | ,',
        'jsonTrailingComma | warning | ,',
      ]);
      expect(_problems(text, TextFormat.jsonWithComments), isEmpty);
    });

    test('keeps a syntax error after comments and repeats', () {
      const text = '{"a": 1, "a": 2, // c\n "b": }';
      expect(_problems(text, TextFormat.jsonWithComments), [
        'duplicateKey | warning | "a" | a | line 1',
        'syntaxError | error | } | expected a value',
      ]);
    });

    test('flags an unterminated block comment', () {
      expect(
        _problems('{"a": 1 /* never\nclosed', TextFormat.jsonWithComments),
        ['syntaxError | error | /* never | unterminated comment'],
      );
    });

    test('flags trailing content', () {
      expect(_problems('{}\n{}', TextFormat.json), [
        'syntaxError | error | { | unexpected trailing content',
      ]);
    });
  });

  group('dotenv', () {
    test('flags a key set again, export or not', () {
      const text = 'PORT=1\n# PORT=2\nexport PORT=3\nHOST=a\nPORT = 4\n';
      expect(_problems(text, TextFormat.dotenv), [
        'duplicateKey | warning | PORT | PORT | line 1',
        'duplicateKey | warning | PORT | PORT | line 1',
      ]);
    });

    test('accepts quoted values across lines and quotes in bare values', () {
      const text =
          'KEY="-----BEGIN\nabc\n-----END"\nNAME=O\'Brien\nA=\'x\'\nB="a\\"b"\n';
      expect(_problems(text, TextFormat.dotenv), isEmpty);
    });

    test('flags a quoted value that never closes', () {
      expect(_problems('A=1\nB="open\nC=3\n', TextFormat.dotenv), [
        'unterminatedQuote | error | "open',
      ]);
      expect(_problems(r'B="escaped\"', TextFormat.dotenv), [
        r'unterminatedQuote | error | "escaped\"',
      ]);
      expect(_problems('B="closed"', TextFormat.dotenv), isEmpty);
    });
  });

  group('YAML', () {
    test('flags a key repeated in one mapping', () {
      const text =
          'services:\n'
          '  web:\n'
          '    image: a\n'
          '    image: b\n'
          '  db:\n'
          '    image: c\n'
          'services: {}\n';
      expect(_problems(text, TextFormat.yaml), [
        'duplicateKey | warning | image | image | line 3',
        'duplicateKey | warning | services | services | line 1',
      ]);
    });

    test('gives each sequence entry its own mapping', () {
      const text =
          'steps:\n'
          '  - name: a\n'
          '    run: x\n'
          '  - name: b\n'
          '    run: y\n'
          'list:\n'
          '- name: a\n'
          '- name: b\n'
          '- - name: c\n'
          '  - name: d\n'
          '-\n'
          '  name: e\n'
          '-\n'
          '  name: f\n';
      expect(_problems(text, TextFormat.yaml), isEmpty);
    });

    test('finds repeats inside a sequence entry', () {
      const text = '- name: a\n  name: b\n- other: 1\n';
      expect(_problems(text, TextFormat.yaml), [
        'duplicateKey | warning | name | name | line 1',
      ]);
    });

    test('compares quoted and plain keys by their text', () {
      const text = 'a: 1\n"a": 2\n\'b\': 3\nb: 4\ntrue: 5\n"true": 6\n';
      expect(_problems(text, TextFormat.yaml), [
        'duplicateKey | warning | "a" | a | line 1',
        'duplicateKey | warning | b | b | line 3',
      ]);
    });

    test('steps over block scalars', () {
      const text =
          'script: |\n'
          '  key: 1\n'
          '  key: 2\n'
          '\n'
          '    key: 3\n'
          'other: >-\n'
          '  key: 4\n'
          'anchored: &x |\n'
          '  key: 5\n'
          'items:\n'
          '  - |\n'
          '    key: 6\n'
          '  - key: |\n'
          '      key: 7\n'
          '    key2: 8\n'
          'key: 9\n';
      expect(_problems(text, TextFormat.yaml), isEmpty);
    });

    test('steps over quoted scalars and flow collections across lines', () {
      const text =
          'a: "first line\n'
          '  a: still the string"\n'
          'b: [one,\n'
          '  b: still the list]\n'
          'c: {x: 1,\n'
          '  c: 2}\n'
          "d: 'it''s\n"
          "  d: quoted'\n";
      expect(_problems(text, TextFormat.yaml), isEmpty);
    });

    test('starts afresh for each document', () {
      expect(
        _problems('a: 1\n---\na: 2\n...\n---\na: 3\n', TextFormat.yaml),
        isEmpty,
      );
    });

    test('ignores comments, merge keys and keys with properties', () {
      const text =
          'a: 1 # a: 2\n'
          '# a: 3\n'
          'base: &base {x: 1}\n'
          'one:\n'
          '  <<: *base\n'
          '  <<: *base\n'
          '? complex\n'
          ': value\n'
          '? complex\n'
          ': value\n';
      expect(_problems(text, TextFormat.yaml), isEmpty);
    });

    test('closes deeper mappings on lines without keys', () {
      const text =
          'a:\n'
          '  x: 1\n'
          '&anchor b:\n'
          '  x: 2\n'
          'c:\n'
          '  - y\n'
          '  x: 3\n';
      expect(_problems(text, TextFormat.yaml), isEmpty);
    });

    test('does not check templates', () {
      const text =
          '{{- if .Values.x }}\n'
          'image: a\n'
          '{{- else }}\n'
          'image: b\n'
          '{{- end }}\n';
      expect(_problems(text, TextFormat.yaml), isEmpty);
      // Values with template expressions are ordinary YAML.
      expect(_problems('a: "{{ x }}"\na: 2\n', TextFormat.yaml), hasLength(1));
    });

    test('flags tab indentation but not tabs in blank or comment lines', () {
      const text = 'a:\n\tb: 1\n\t\n\t# note\nc: |\n  \ttext\n';
      expect(_problems(text, TextFormat.yaml), [
        'tabIndentation | error | \tb:',
      ]);
    });

    test('reads CRLF line endings', () {
      expect(_problems('a: 1\r\na: 2\r\n', TextFormat.yaml), [
        'duplicateKey | warning | a | a | line 1',
      ]);
    });
  });

  group('TOML', () {
    test('flags a key defined twice in one table', () {
      const text =
          'name = "a"\n'
          '[package]\n'
          'name = "b"\n'
          'version = "1"\n'
          '"name" = "c"\n'
          'a.b = 1\n'
          'a . b = 2\n';
      expect(_problems(text, TextFormat.toml), [
        'duplicateKey | error | "name" | "name" | line 3',
        'duplicateKey | error | a . b | a . b | line 6',
      ]);
    });

    test('flags a table declared twice', () {
      const text = '[a]\nx = 1\n[b]\n[ a ]\ny = 2\n';
      expect(_problems(text, TextFormat.toml), [
        'duplicateTable | error | a | a | line 1',
      ]);
    });

    test('starts afresh for each array-of-tables element', () {
      const text =
          '[[fruits]]\n'
          'name = "apple"\n'
          '[fruits.physical]\n'
          'color = "red"\n'
          '[[fruits]]\n'
          'name = "banana"\n'
          '[fruits.physical]\n'
          'color = "yellow"\n';
      expect(_problems(text, TextFormat.toml), isEmpty);
    });

    test('steps over multi-line strings and arrays', () {
      const text =
          'a = """\n'
          'a = 2\n'
          '"""\n'
          "b = '''one\n"
          "b = 2'''\n"
          'c = [\n'
          '  "c = 3",\n'
          '  [4],\n'
          ']\n'
          'd = { e = 1, e = 2 }\n';
      expect(_problems(text, TextFormat.toml), isEmpty);
    });
  });

  group('XML', () {
    test('accepts well-formed documents', () {
      const text =
          '<?xml version="1.0"?>\n'
          '<!DOCTYPE note [<!ENTITY a "<b>">]>\n'
          '<note a="1" b=\'x > y\'>\n'
          '  <!-- <unclosed> -->\n'
          '  <![CDATA[ <raw> ]]>\n'
          '  <empty/>\n'
          '  <ns:item />\n'
          '</note>\n';
      expect(_problems(text, TextFormat.xml), isEmpty);
    });

    test('flags an element left open inside another', () {
      expect(_problems('<a>\n  <b>\n</a>\n', TextFormat.xml), [
        'unclosedElement | error | b | b',
      ]);
    });

    test('flags a closing tag that matches nothing open', () {
      expect(_problems('<a>\n</b>\n</a>', TextFormat.xml), [
        'mismatchedClosingTag | error | b | b | closes a | line 1',
      ]);
      expect(_problems('<a/></a>', TextFormat.xml), [
        'unexpectedClosingTag | error | a | a',
      ]);
    });

    test('flags elements still open at the end', () {
      expect(_problems('<a><b></b>', TextFormat.xml), [
        'unclosedElement | error | a | a',
      ]);
    });

    test('flags a repeated attribute and malformed ones', () {
      expect(_problems('<a x="1" x="2"/>', TextFormat.xml), [
        'duplicateAttribute | error | x | x',
      ]);
      expect(_problems('<a x=1></a>', TextFormat.xml), [
        'syntaxError | error | x | attribute value must be quoted',
      ]);
      expect(_problems('<input disabled></input>', TextFormat.xml), [
        'syntaxError | error | disabled | attribute without a value',
      ]);
    });

    test('flags a bare < in text', () {
      expect(_problems('<a>1 < 2</a>', TextFormat.xml), [
        "syntaxError | error | < | '<' in text must be written as &lt;",
      ]);
    });

    test('stops at a construct that never ends', () {
      expect(_problems('<a>\n<!-- open\n<b>', TextFormat.xml), [
        'syntaxError | error | <!-- open | unterminated comment',
      ]);
      expect(_problems('<a href="x"', TextFormat.xml), [
        'syntaxError | error | <a href="x" | unterminated tag',
      ]);
    });
  });

  test('stops at the problem limit', () {
    final text = List.filled(textProblemLimit + 20, 'A=1').join('\n');
    expect(validateText(text, TextFormat.dotenv), hasLength(textProblemLimit));
  });
}
