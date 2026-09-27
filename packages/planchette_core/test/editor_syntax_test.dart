import 'package:test/test.dart';
import 'package:planchette_core/planchette_core.dart';

List<SyntaxToken> _ofType(List<SyntaxToken> tokens, SyntaxTokenType type) =>
    tokens.where((token) => token.type == type).toList();

String _slice(String text, SyntaxToken token) =>
    text.substring(token.start, token.end);

void main() {
  group('language detection', () {
    test('resolves well-known extensions', () {
      expect(syntaxLanguageFor('/srv/deploy.py')?.id, 'python');
      expect(syntaxLanguageFor('/etc/nginx/nginx.conf')?.id, 'ini');
      expect(syntaxLanguageFor('/tmp/data.json')?.id, 'json');
      expect(syntaxLanguageFor('compose.yaml')?.id, 'yaml');
      expect(syntaxLanguageFor('main.go')?.id, 'c-family');
      expect(syntaxLanguageFor('query.sql')?.id, 'sql');
      expect(syntaxLanguageFor('notes.xyz'), isNull);
      expect(syntaxLanguageFor('README'), isNull);
    });

    test('resolves well-known basenames before extensions', () {
      expect(syntaxLanguageFor('/app/Dockerfile')?.id, 'dockerfile');
      expect(syntaxLanguageFor('Dockerfile.prod')?.id, 'dockerfile');
      expect(syntaxLanguageFor('/home/user/.bashrc')?.id, 'shell');
      expect(syntaxLanguageFor('/home/user/.ssh/config')?.id, 'ini');
      expect(syntaxLanguageFor('/etc/ssh/sshd_config')?.id, 'ini');
      expect(syntaxLanguageFor('Makefile')?.id, 'shell');
    });

    test('falls back to the shebang line', () {
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/deploy',
          firstLine: '#!/usr/bin/env bash',
        )?.id,
        'shell',
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/python3',
        )?.id,
        'python',
      );
      expect(
        syntaxLanguageFor('/usr/local/bin/x', firstLine: 'not a shebang'),
        isNull,
      );
    });

    // 06 §7's additions — detection coverage for the new families.
    test('§7: css covers .css/.scss/.less', () {
      expect(syntaxLanguageFor('site.css')?.id, 'css');
      expect(syntaxLanguageFor('theme.scss')?.id, 'css');
      expect(syntaxLanguageFor('legacy.less')?.id, 'css');
    });

    test('§7: ruby covers extensions, convention basenames, shebangs', () {
      expect(syntaxLanguageFor('app.rb')?.id, 'ruby');
      expect(syntaxLanguageFor('tasks.rake')?.id, 'ruby');
      expect(syntaxLanguageFor('my.gemspec')?.id, 'ruby');
      expect(syntaxLanguageFor('Gemfile')?.id, 'ruby');
      expect(syntaxLanguageFor('Rakefile')?.id, 'ruby');
      expect(syntaxLanguageFor('config.ru')?.id, 'ruby');
      // Directly and after env (06 §7).
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/ruby',
        )?.id,
        'ruby',
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/env ruby',
        )?.id,
        'ruby',
      );
    });

    test('§7: perl covers .pl/.pm and shebangs', () {
      expect(syntaxLanguageFor('script.pl')?.id, 'perl');
      expect(syntaxLanguageFor('Module.pm')?.id, 'perl');
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/perl',
        )?.id,
        'perl',
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/env perl',
        )?.id,
        'perl',
      );
    });

    test('§7: lua covers .lua and the pinned interpreter spellings', () {
      expect(syntaxLanguageFor('init.lua')?.id, 'lua');
      for (final interpreter in [
        'lua',
        'luajit',
        'lua5.1',
        'lua5.2',
        'lua5.3',
        'lua5.4',
      ]) {
        expect(
          syntaxLanguageFor(
            '/usr/local/bin/tool',
            firstLine: '#!/usr/bin/$interpreter',
          )?.id,
          'lua',
          reason: interpreter,
        );
        expect(
          syntaxLanguageFor(
            '/usr/local/bin/tool',
            firstLine: '#!/usr/bin/env $interpreter',
          )?.id,
          'lua',
          reason: 'env $interpreter',
        );
      }
      // No over-capture: spellings that merely start with "lua" are not
      // claimed (06 §7).
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/lua5.5',
        ),
        isNull,
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/luabridge',
        ),
        isNull,
      );
    });

    test('§7: Apache dot-configs map to ini', () {
      expect(syntaxLanguageFor('/srv/www/.htaccess')?.id, 'ini');
      expect(syntaxLanguageFor('/srv/www/.htpasswd')?.id, 'ini');
    });
  });

  group('tokenizer', () {
    test('shell: comments, keywords, strings, numbers, variables', () {
      const text = '# note\necho "hi" 42 \$HOME\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.shell);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(comments, hasLength(1));
      expect(_slice(text, comments.single), '# note');
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('echo'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('"hi"'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        contains('42'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('\$HOME'),
      );
    });

    test('shell: a hash inside a word is not a comment', () {
      final tokens = tokenizeSyntax('path/foo#bar\n', SyntaxLanguages.shell);
      expect(_ofType(tokens, SyntaxTokenType.comment), isEmpty);
    });

    test(
      'python: hash comments need no boundary; triple quotes span lines',
      () {
        const text = 'x=1# c\n"""doc\nstring"""\n';
        final tokens = tokenizeSyntax(text, SyntaxLanguages.python);
        final comments = _ofType(tokens, SyntaxTokenType.comment);
        expect(comments.map((t) => _slice(text, t)), contains('# c'));
        final strings = _ofType(tokens, SyntaxTokenType.string);
        expect(strings, hasLength(1));
        expect(_slice(text, strings.single), '"""doc\nstring"""');
      },
    );

    test('javascript: block comments and template strings', () {
      const text = '/* a\nb */ const x = `tpl\nline`; // end\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.javascript);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(comments.map((t) => _slice(text, t)), contains('/* a\nb */'));
      expect(comments.map((t) => _slice(text, t)), contains('// end'));
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('`tpl\nline`'),
      );
    });

    test('strings: escapes are honored and unterminated stops at newline', () {
      const text = '"a\\"b" "open\nnext';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.json);
      final strings = _ofType(tokens, SyntaxTokenType.string);
      expect(_slice(text, strings.first), '"a\\"b"');
      expect(_slice(text, strings.last), '"open');
    });

    test('numbers: hex, decimals, exponents', () {
      const text = 'a = 0xFF; b = 3.14e-2; c = 10_000';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.cFamily);
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        containsAll(['0xFF', '3.14e-2', '10_000']),
      );
    });

    test('yaml: keys are meta unless consumed by another token', () {
      const text = 'name: test\n# port: none\nport: 8080\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.yaml);
      final meta = _ofType(tokens, SyntaxTokenType.meta);
      expect(meta.map((t) => _slice(text, t)), ['name', 'port']);
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        contains('8080'),
      );
    });

    test('ini: sections, comments, booleans', () {
      const text = '[core]\n; note\nenabled = TRUE\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.ini);
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('[core]'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('; note'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('TRUE'),
      );
    });

    test('dockerfile: instructions are case-insensitive keywords', () {
      const text = 'FROM debian:stable\nrun apt-get update\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.dockerfile);
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['FROM', 'run']),
      );
    });

    // 06 §7's additions — one tokenizer smoke test per new family.
    test('§7 css: block comments, property meta, at-rule keywords', () {
      const text = '/* note */\n@media screen {\n  color: red;\n}\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.css);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('/* note */'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('color'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('media'),
      );
    });

    test('§7 ruby: bounded hash comments, keywords, strings', () {
      const text = '# note\ndef greet\n  puts "hi"\nend\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.ruby);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('# note'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['def', 'end', 'puts']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('"hi"'),
      );
      // The boundary flag: `x#y` is not a comment start.
      expect(
        _ofType(
          tokenizeSyntax('x#y\n', SyntaxLanguages.ruby),
          SyntaxTokenType.comment,
        ),
        isEmpty,
      );
    });

    test('§7 perl: # glued to a sigil or delimiter is not a comment', () {
      // The last index of an array, `#` as a quote or regex delimiter, and
      // `#` inside a regex: each used to grey out the rest of its line
      // (ported from Séance's fix of the same rule).
      for (final line in [
        r'for my $i (0..$#list) { print $i }',
        r's#/usr#/opt#;',
        r'my @w = qw#a b#;',
        r'$line =~ s/#.*//;',
      ]) {
        final tokens = tokenizeSyntax('$line\n', SyntaxLanguages.perl);
        expect(_ofType(tokens, SyntaxTokenType.comment), isEmpty, reason: line);
      }
    });

    test('§7 perl: hash comments after whitespace, keywords, strings', () {
      const text = 'my \$x = 1; # tail\nsub f { print "hi" }\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.perl);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('# tail'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['my', 'sub', 'print']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('"hi"'),
      );
    });

    test('§7 lua: --[[ ]] spans lines, [[ ]] strings, -- line comments', () {
      // The pins 06 §7 requires: a spanning --[[ ]] comment and a plain
      // [[ ]] string, proving the block-comment rule wins over both the
      // -- line rule and the [[ string rule.
      const text =
          '--[[ block\ncomment ]]\nlocal s = [[ multi\nline ]]\n'
          '-- tail\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.lua);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(
        comments.map((t) => _slice(text, t)),
        containsAll(['--[[ block\ncomment ]]', '-- tail']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('[[ multi\nline ]]'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('local'),
      );
    });

    test('tokens are ordered and never overlap', () {
      const text =
          'if [ -f "\$HOME/.bashrc" ]; then # load\n  source '
          '"\$HOME/.bashrc" 2>/dev/null\nfi\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.shell);
      for (var i = 1; i < tokens.length; i++) {
        expect(tokens[i].start, greaterThanOrEqualTo(tokens[i - 1].end));
      }
    });
  });

  group('search', () {
    test('is case-insensitive by default and reports exact ranges', () {
      final matches = findSearchMatches('Beta beta BETA', 'beta');
      expect(matches, hasLength(3));
      expect(matches.first, const TextMatch(start: 0, end: 4));
      expect(matches.last, const TextMatch(start: 10, end: 14));
      expect(
        findSearchMatches('Beta beta BETA', 'beta', caseSensitive: true),
        hasLength(1),
      );
    });

    test('caps the match count at the limit', () {
      final text = 'a' * 50;
      expect(findSearchMatches(text, 'a', limit: 10), hasLength(10));
    });

    test('an empty query has no matches', () {
      expect(findSearchMatches('anything', ''), isEmpty);
    });

    test('a start offset skips the matches before it', () {
      expect(findSearchMatches('ab ab ab ab', 'ab', start: 3), [
        const TextMatch(start: 3, end: 5),
        const TextMatch(start: 6, end: 8),
        const TextMatch(start: 9, end: 11),
      ]);
      expect(findSearchMatches('ab ab', 'ab', start: 99), isEmpty);
    });

    test('a reverse window returns the matches before the bound', () {
      expect(
        findSearchMatches('ab ab ab ab', 'ab', start: 5, reverse: true),
        [const TextMatch(start: 0, end: 2), const TextMatch(start: 3, end: 5)],
      );
      expect(findSearchMatches('ab ab ab ab', 'ab', reverse: true), [
        const TextMatch(start: 0, end: 2),
        const TextMatch(start: 3, end: 5),
        const TextMatch(start: 6, end: 8),
        const TextMatch(start: 9, end: 11),
      ]);
      expect(findSearchMatches('ab', 'ab', start: 0, reverse: true), isEmpty);
    });

    test('a reverse window still honours the limit', () {
      final text = List.filled(50, 'a').join();
      expect(findSearchMatches(text, 'a', limit: 3, reverse: true), [
        const TextMatch(start: 47, end: 48),
        const TextMatch(start: 48, end: 49),
        const TextMatch(start: 49, end: 50),
      ]);
    });

    test('a reverse window offers the same occurrences as a forward scan', () {
      // Self-overlapping needles are the case that diverged: 'aa' in 'aaaa' is
      // [0, 2] forwards, and a backward scan with lastIndexOf also offered the
      // match at 1 that Find Next would never produce.
      for (final text in ['aaaa', 'aaaaa', 'ababab', 'ababa', 'cat CAT cat']) {
        for (final query in ['a', 'aa', 'aba', 'cat']) {
          expect(
            findSearchMatches(text, query, reverse: true),
            findSearchMatches(text, query),
            reason: 'reverse window of "$query" in "$text"',
          );
        }
      }
    });

    test('a reverse window ends at the limit without losing the oldest hit', () {
      final text = List.filled(10, 'a').join();
      expect(findSearchMatches(text, 'a', limit: 3, start: 6, reverse: true), [
        const TextMatch(start: 3, end: 4),
        const TextMatch(start: 4, end: 5),
        const TextMatch(start: 5, end: 6),
      ]);
    });
  });
}
