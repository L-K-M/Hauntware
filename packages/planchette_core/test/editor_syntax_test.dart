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
      expect(syntaxLanguageFor('main.go')?.id, 'go');
      expect(syntaxLanguageFor('lib.rs')?.id, 'rust');
      expect(syntaxLanguageFor('fix.patch')?.id, 'diff');
      expect(syntaxLanguageFor('changes.diff')?.id, 'diff');
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

    test('yaml: meta token offsets skip every dash prefix', () {
      // Regression: a key inside a nested list must start at the key
      // itself, not at either of the leading '-' list markers.
      const text = '- - name: x\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.yaml);
      final meta = _ofType(tokens, SyntaxTokenType.meta);
      expect(meta, hasLength(1));
      expect(meta.single.start, text.indexOf('name'));
      expect(meta.single.end, text.indexOf('name') + 'name'.length);
      expect(text.substring(meta.single.start, meta.single.end), 'name');
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

    test('CSS scans long colonless identifiers without stalling', () {
      const identifierLength = 20 * 1000;
      const maximumScanTime = Duration(seconds: 1);
      final text = '${'a' * identifierLength}\ncolor: red;';
      final stopwatch = Stopwatch()..start();
      final tokens = tokenizeSyntax(text, SyntaxLanguages.css);
      stopwatch.stop();

      expect(tokens, [
        SyntaxToken(
          identifierLength + 1,
          identifierLength + 1 + 'color'.length,
          SyntaxTokenType.meta,
        ),
      ]);
      // A generous ceiling detects quadratic retries, not normal CI variance.
      expect(stopwatch.elapsed, lessThan(maximumScanTime));
    });

    test('Rust attributes scan a line of unclosed openers linearly', () {
      // Every '#[' starts a candidate; letting the candidate run past the
      // next '[' made each one rescan to the end of the line.
      const repetitions = 20 * 1000;
      const maximumScanTime = Duration(seconds: 1);
      final text = '${'#[' * repetitions}\n#[derive(Debug)]';
      final stopwatch = Stopwatch()..start();
      final tokens = tokenizeSyntax(text, SyntaxLanguages.rust);
      stopwatch.stop();

      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        ['#[derive(Debug)]'],
      );
      // A generous ceiling detects quadratic retries, not normal CI variance.
      expect(stopwatch.elapsed, lessThan(maximumScanTime));
    });

    test(
      'CSS meta boundaries preserve custom properties and token priority',
      () {
        const text =
            ':root { --accent-color: red; -webkit-transform: none; }\n'
            'a:hover { color: "ignored: value"; /* hidden: value */ }';
        final tokens = tokenizeSyntax(text, SyntaxLanguages.css);

        expect(
          _ofType(
            tokens,
            SyntaxTokenType.meta,
          ).map((token) => _slice(text, token)),
          ['--accent-color', '-webkit-transform', 'a', 'color'],
        );
        for (var i = 1; i < tokens.length; i++) {
          expect(tokens[i].start, greaterThanOrEqualTo(tokens[i - 1].end));
        }
      },
    );

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

    test('reports exact case folding for ordinary text', () {
      final result = searchText('Die Größe der Straße', 'größe');
      expect(result.caseFolding, CaseFolding.exact);
      expect(result.caseFoldedExactly, isTrue);
      expect(result.matches, [const TextMatch(start: 4, end: 9)]);
    });

    test('Dart lowercasing preserves length, so the guard is defensive', () {
      // Every code point folds to the same number of UTF-16 units today. If a
      // future SDK breaks that, searchText reports it rather than quietly
      // changing what a case-insensitive search means.
      // Every code point, surrogates included: a lone surrogate is a valid
      // Dart string unit too. Fail only on a mismatch, so the scan does not
      // build a million reason strings.
      for (var rune = 0x80; rune <= 0x10FFFF; rune++) {
        final value = String.fromCharCode(rune);
        if (value.toLowerCase().length != value.length) {
          fail('U+${rune.toRadixString(16)} changes length when lowercased');
        }
      }
    });

    test('a fold that erases the whole query finds nothing', () {
      // A folding table may drop characters (default-ignorable marks, say).
      // An empty needle would match at every offset and hand Replace All a
      // list of zero-width matches to insert its replacement at.
      // The document holds no soft hyphen, so its fold keeps its length and
      // the folded path is taken; only the query vanishes.
      String fold(String value) => value.replaceAll('\u00AD', '');
      final result = searchText('plain text', '\u00AD', fold: fold);
      expect(result.caseFolding, CaseFolding.exact);
      expect(result.matches, isEmpty);
    });

    // The document side of the guard. Paired with 'a length-changing query is
    // still folded' below, which is the side that must NOT report limited.
    test('a length-changing document is reported and matched exactly', () {
      // ß uppercases to "SS", which is what a full case fold would expand it
      // to. Dart's toLowerCase does not do that, so the fold is injected to
      // reach the path a host with its own folding table would take.
      String fold(String value) =>
          value.replaceAll('ß', 'ss').replaceAll('ẞ', 'ss');
      final result = searchText('Die Straße', 'STRASSE', fold: fold);
      expect(result.caseFolding, CaseFolding.lengthChanging);
      expect(result.caseFoldedExactly, isFalse);
      // Reported as limited, and the match is the exact one — the honest
      // outcome is "fewer matches than you asked for", not a wrong range.
      expect(result.matches, isEmpty);
      expect(searchText('Die Straße', 'Straße', fold: fold).matches, [
        const TextMatch(start: 4, end: 10),
      ]);
      expect(findSearchMatches('ab ab', 'ab', start: 99), isEmpty);
    });

    test('a case-sensitive search is never limited', () {
      final result = searchText(
        'Die Straße',
        'STRASSE',
        caseSensitive: true,
        fold: (value) => value.toLowerCase().replaceAll('ß', 'ss'),
      );
      expect(result.caseFolding, CaseFolding.exact);
      expect(result.matches, isEmpty);
    });

    test('a length-changing query is still folded', () {
      // Only the document's length decides whether offsets stay valid. A
      // query whose fold is longer matches the longer region the document
      // actually has, which is what case-insensitive matching means: `Straße`
      // and `strasse` are case equivalents, not the same string.
      final result = searchText(
        'die strasse',
        'Straße',
        fold: (value) => value.toLowerCase().replaceAll('ß', 'ss'),
      );
      expect(result.caseFolding, CaseFolding.exact);
      expect(result.matches, [const TextMatch(start: 4, end: 11)]);
    });

    test('a length-preserving fold fixes what toLowerCase misses', () {
      // Greek words end in the final sigma, which `toLowerCase` never
      // produces: it maps capital sigma to plain sigma unconditionally.
      const text = 'η σοφος';
      expect(findSearchMatches(text, 'ΣΟΦΟΣ'), isEmpty);
      expect(
        searchText(
          text,
          'ΣΟΦΟΣ',
          fold: (value) => value.toLowerCase().replaceAll('ς', 'σ'),
        ).matches,
        [const TextMatch(start: 2, end: 7)],
      );
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
      expect(findSearchMatches('ab ab ab ab', 'ab', start: 5, reverse: true), [
        const TextMatch(start: 0, end: 2),
        const TextMatch(start: 3, end: 5),
      ]);
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

    // Lost from #85 when a force-push replaced its first revision.
    test('a reverse window offers the same occurrences as a forward scan', () {
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

    test(
      'a reverse window ends at the limit without losing the oldest hit',
      () {
        final text = List.filled(10, 'a').join();
        expect(
          findSearchMatches(text, 'a', limit: 3, start: 6, reverse: true),
          [
            const TextMatch(start: 3, end: 4),
            const TextMatch(start: 4, end: 5),
            const TextMatch(start: 5, end: 6),
          ],
        );
      },
    );

    test('a window says how many matches come before it', () {
      const text = 'ab ab ab ab';
      expect(searchText(text, 'ab', limit: 2).precedingCount, 0);
      expect(searchText(text, 'ab', start: 3).precedingCount, isNull);
      final back = searchText(text, 'ab', limit: 1, start: 6, reverse: true);
      expect(back.matches, [const TextMatch(start: 3, end: 5)]);
      expect(back.precedingCount, 1);
      expect(searchText(text, 'ab', limit: 3, reverse: true).precedingCount, 1);
      expect(searchText(text, 'x', reverse: true).precedingCount, 0);
    });

    test('an empty limit finds nothing in either direction', () {
      expect(findSearchMatches('ab ab', 'ab', limit: 0), isEmpty);
      expect(
        findSearchMatches('ab ab', 'ab', limit: 0, reverse: true),
        isEmpty,
      );
    });

    // From #12, with a Unicode word classifier.
    test('whole words respect boundaries, edges and underscore', () {
      const text = 'cat concat cat. (cat) cat_cat café cat';
      expect(findSearchMatches(text, 'cat', wholeWord: true), const [
        TextMatch(start: 0, end: 3),
        TextMatch(start: 11, end: 14),
        TextMatch(start: 17, end: 20),
        TextMatch(start: 35, end: 38),
      ]);
      expect(
        findSearchMatches('cat cat', 'cat', wholeWord: true),
        hasLength(2),
      );
      expect(findSearchMatches('concat', 'cat', wholeWord: true), isEmpty);
      expect(findSearchMatches('cat_cat', 'cat', wholeWord: true), isEmpty);
      expect(
        findSearchMatches('Cat CAT', 'cat', wholeWord: true),
        hasLength(2),
      );
      expect(findSearchMatches('a == b', '==', wholeWord: true), hasLength(1));
      // Emoji are boundaries, as with \b in other editors.
      expect(findSearchMatches('cat🙂', 'cat', wholeWord: true), const [
        TextMatch(start: 0, end: 3),
      ]);
      expect(findSearchMatches('🙂cat', 'cat', wholeWord: true), const [
        TextMatch(start: 2, end: 5),
      ]);
    });

    test('prose punctuation ends a word, letters of any script do not', () {
      for (final text in ['“cat”', 'cat—dog', 'le cat\u00A0!', '«cat»']) {
        expect(
          findSearchMatches(text, 'cat', wholeWord: true),
          hasLength(1),
          reason: text,
        );
      }
      expect(findSearchMatches('catécat', 'cat', wholeWord: true), isEmpty);
      expect(findSearchMatches('猫猫', '猫', wholeWord: true), isEmpty);
      expect(findSearchMatches('猫、犬', '猫', wholeWord: true), hasLength(1));
      // An astral letter is word content too, read as one code point.
      expect(findSearchMatches('𝒜cat', 'cat', wholeWord: true), isEmpty);
    });

    test('a match edge that is not a word character needs no boundary', () {
      expect(findSearchMatches('a==b', '==', wholeWord: true), hasLength(1));
      expect(findSearchMatches('cat ', 'cat ', wholeWord: true), hasLength(1));
      expect(findSearchMatches('cat x', 'cat ', wholeWord: true), hasLength(1));
      expect(findSearchMatches('concat x', 'cat ', wholeWord: true), isEmpty);
    });

    test('a rejected hit can hide a whole word that starts inside it', () {
      expect(findSearchMatches('xab ab ab', 'ab ab', wholeWord: true), const [
        TextMatch(start: 4, end: 9),
      ]);
    });

    test('whole words page the same way in both directions', () {
      for (final text in ['cat concat cat', 'cat_cat cat', 'aa aaa aa']) {
        for (final query in ['cat', 'aa']) {
          expect(
            findSearchMatches(text, query, wholeWord: true, reverse: true),
            findSearchMatches(text, query, wholeWord: true),
            reason: 'reverse whole-word window of "$query" in "$text"',
          );
        }
      }
    });

    test('whole words work with a case fold', () {
      String fold(String value) => value.toLowerCase().replaceAll('ς', 'σ');
      expect(
        searchText(
          'σοφος σοφοςx',
          'ΣΟΦΟΣ',
          wholeWord: true,
          fold: fold,
        ).matches,
        const [TextMatch(start: 0, end: 5)],
      );
    });

    test('a reverse window over many matches takes linear time', () {
      // Evicting the oldest hit from the front of a list is O(limit) per
      // match: Find Previous from the first match of a 2 MB run of one
      // character took seconds.
      final text = 'a' * 2000000;
      final watch = Stopwatch()..start();
      final window = findSearchMatches(text, 'a', reverse: true);
      watch.stop();
      expect(window, hasLength(searchMatchLimit));
      expect(window.last, const TextMatch(start: 1999999, end: 2000000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    group('scoped to a stored range', () {
      const text = 'cat one cat two cat';
      //                       0123456789012345678
      // 'cat' sits at 0-3, 8-11 and 16-19.

      test('only matches lying wholly inside count', () {
        expect(
          findSearchMatches(text, 'cat', scope: (start: 4, end: 19)),
          const [TextMatch(start: 8, end: 11), TextMatch(start: 16, end: 19)],
        );
        // A match that straddles either edge does not count.
        expect(
          findSearchMatches(text, 'cat', scope: (start: 4, end: 18)),
          const [TextMatch(start: 8, end: 11)],
        );
        expect(
          findSearchMatches(text, 'cat', scope: (start: 1, end: 4)),
          isEmpty,
        );
      });

      test('counts and pages are scope-relative', () {
        const scope = (start: 4, end: 20);
        // Forward pages keep the document's contract: a mid-text start
        // does not count backwards.
        final page = searchText(text, 'cat', scope: scope, start: 12);
        expect(page.matches, const [TextMatch(start: 16, end: 19)]);
        // Reverse windows count only what the scope holds: unscoped, one
        // match at 0-3 would raise precedingCount to 2.
        final window = searchText(
          text,
          'cat',
          scope: scope,
          reverse: true,
          limit: 1,
        );
        expect(window.matches, const [TextMatch(start: 16, end: 19)]);
        expect(window.precedingCount, 1);
        expect(
          searchText(
            text,
            'cat',
            scope: scope,
            start: 16,
            reverse: true,
          ).matches,
          const [TextMatch(start: 8, end: 11)],
        );
      });
    });
  });

  group('language fixes', () {
    List<String> slices(
      String text,
      SyntaxLanguage language,
      SyntaxTokenType type,
    ) => [
      for (final token in _ofType(tokenizeSyntax(text, language), type))
        _slice(text, token),
    ];

    test('Rust lifetimes are names, not strings that eat the line', () {
      const text = "fn f<'a>(x: &'a str) -> &'static str { x }";
      final rust = syntaxLanguageFor('lib.rs')!;
      expect(slices(text, rust, SyntaxTokenType.string), isEmpty);
      expect(slices(text, rust, SyntaxTokenType.meta), ["'a", "'a", "'static"]);
      expect(slices(text, rust, SyntaxTokenType.keyword), ['fn']);
    });

    test('Rust and Go character literals, escapes included', () {
      const text =
          r"let c = 'x'; let n = '\n'; let q = '\''; let e = '\u{1F600}';";
      expect(slices(text, SyntaxLanguages.rust, SyntaxTokenType.string), [
        "'x'",
        r"'\n'",
        r"'\''",
        r"'\u{1F600}'",
      ]);
      expect(
        slices(
          "r := 'é' + '\\x41'",
          SyntaxLanguages.go,
          SyntaxTokenType.string,
        ),
        ["'é'", r"'\x41'"],
      );
    });

    test('Rust raw strings take no escapes; raw identifiers are not strings', () {
      const text =
          r'let a = r"C:\"; let b = r#"x"\y"#; let c = br"\d"; let r#type = 1;';
      expect(slices(text, SyntaxLanguages.rust, SyntaxTokenType.string), [
        r'r"C:\"',
        r'r#"x"\y"#',
        r'br"\d"',
      ]);
      expect(
        slices(text, SyntaxLanguages.rust, SyntaxTokenType.keyword),
        contains('let'),
      );
    });

    test('Rust attributes holding a string keep only the string colored', () {
      // A known limit of the meta merge: overlapping matches are dropped.
      const text = '#[cfg(feature = "serde")]\nfn f() {}';
      expect(slices(text, SyntaxLanguages.rust, SyntaxTokenType.meta), isEmpty);
      expect(slices(text, SyntaxLanguages.rust, SyntaxTokenType.string), [
        '"serde"',
      ]);
    });

    test('Go raw strings span lines and take no escapes', () {
      // The backslash before the line break and before the closing backtick
      // are both plain text.
      const text = 'p := `C:\\dir\\\nD:\\`\nq := "a\\"b"';
      expect(slices(text, SyntaxLanguages.go, SyntaxTokenType.string), [
        '`C:\\dir\\\nD:\\`',
        '"a\\"b"',
      ]);
    });

    test('shell and SQL single quotes take no backslash escapes', () {
      const shell = r"echo 'C:\' && ls # done";
      expect(slices(shell, SyntaxLanguages.shell, SyntaxTokenType.string), [
        r"'C:\'",
      ]);
      expect(slices(shell, SyntaxLanguages.shell, SyntaxTokenType.comment), [
        '# done',
      ]);
      const sql = r"SELECT '\' AS slash -- note";
      expect(slices(sql, SyntaxLanguages.sql, SyntaxTokenType.comment), [
        '-- note',
      ]);
    });

    test('JSON and YAML quoted keys are keys, values stay strings', () {
      const json = '{"name": "Ada", "tags": ["a:b"]}';
      expect(slices(json, SyntaxLanguages.json, SyntaxTokenType.meta), [
        '"name"',
        '"tags"',
      ]);
      expect(slices(json, SyntaxLanguages.json, SyntaxTokenType.string), [
        '"Ada"',
        '"a:b"',
      ]);
      expect(
        slices("'quoted key' : x", SyntaxLanguages.yaml, SyntaxTokenType.meta),
        ["'quoted key'"],
      );
    });

    test('C preprocessor, Rust attributes and Python decorators', () {
      expect(
        slices(
          '#include <stdio.h>\n  #  define X 1\nint a = b # c;',
          SyntaxLanguages.cFamily,
          SyntaxTokenType.meta,
        ),
        ['#include', '  #  define'],
      );
      expect(
        slices(
          '<?php\n# TODO tidy this\n#pragma once\n',
          SyntaxLanguages.cFamily,
          SyntaxTokenType.meta,
        ),
        ['#pragma'],
      );
      expect(
        slices(
          '#elseif os(macOS)\n#nullable enable\n#include_next <limits.h>\n',
          SyntaxLanguages.cFamily,
          SyntaxTokenType.meta,
        ),
        ['#elseif', '#nullable', '#include_next'],
      );
      expect(
        slices(
          '#[derive(Debug)]\n#![allow(dead_code)]',
          SyntaxLanguages.rust,
          SyntaxTokenType.meta,
        ),
        ['#[derive(Debug)]', '#![allow(dead_code)]'],
      );
      expect(
        slices(
          '@app.route("/")\ndef f(): return a @ b',
          SyntaxLanguages.python,
          SyntaxTokenType.meta,
        ),
        ['@app.route'],
      );
    });

    test('diffs separate headers, hunks, additions and removals', () {
      const text =
          'diff --git a/x b/x\n'
          'index 1..2 100644\n'
          '--- a/x\n'
          '+++ b/x\n'
          '@@ -1,3 +1,3 @@\n'
          ' same\n'
          '--- removed SQL comment\n'
          '+++ added counter\n'
          '\\ No newline at end of file\n'
          '\n'
          'diff --git a/y b/y\n';
      final diff = SyntaxLanguages.diff;
      expect(slices(text, diff, SyntaxTokenType.keyword), [
        'diff --git a/x b/x',
        'index 1..2 100644',
        '--- a/x',
        '+++ b/x',
        'diff --git a/y b/y',
      ]);
      expect(slices(text, diff, SyntaxTokenType.meta), ['@@ -1,3 +1,3 @@']);
      expect(slices(text, diff, SyntaxTokenType.number), [
        '--- removed SQL comment',
      ]);
      expect(slices(text, diff, SyntaxTokenType.string), ['+++ added counter']);
      expect(slices(text, diff, SyntaxTokenType.comment), [
        '\\ No newline at end of file',
      ]);
    });
  });
}
