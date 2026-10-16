import 'package:klabautermann_core/src/sampling/argument_masking.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue;
import 'package:test/test.dart';

const _mask = MaskedValue.maskToken;

/// What each argument of [argv] shows.
List<String> _shown(List<String> argv) => [
  for (final value in maskCommandLine(argv)) value.display,
];

void main() {
  group('process arguments are masked per argument (03 §8.9, 7.2)', () {
    test('an attached -p value, as the MySQL clients take a password', () {
      final masked = maskCommandLine(['mysql', '-uroot', '-phunter2', 'db']);

      expect(
        [for (final m in masked) m.display],
        ['mysql', '-uroot', '-p$_mask', 'db'],
      );
      expect(masked[2].isMasked, isTrue);
      expect(masked[2].reveal(), '-phunter2');
      expect(masked[2].toString(), isNot(contains('hunter2')));
      expect(masked[1].isMasked, isFalse);
    });

    test('an attached -p value is masked whole even where it holds a secret '
        'name and a later `=`', () {
      expect(
        _shown([
          'mysql',
          '-pPassw0rd=1',
          '-pMonkey=Banana1',
          '-pS3cretKEY==',
          '-password=x',
        ]),
        ['mysql', '-p$_mask', '-p$_mask', '-p$_mask', '-p$_mask'],
      );
      expect(_shown(['sh', '-c', 'mysqldump -uroot -pmyAuth=xyz db']), [
        'sh',
        '-c',
        'mysqldump -uroot -p$_mask db',
      ]);
    });

    test('the value of an option or variable whose name is secret', () {
      expect(
        _shown([
          'app',
          '--password=hunter2',
          '--db-password=x',
          '-Dspring.datasource.password=y',
          'API_TOKEN=abc',
        ]),
        [
          'app',
          '--password=$_mask',
          '--db-password=$_mask',
          '-Dspring.datasource.password=$_mask',
          'API_TOKEN=$_mask',
        ],
      );
    });

    test('a secret assignment inside an option\'s value', () {
      expect(
        _shown([
          'docker',
          '--env=DB_PASSWORD=hunter2',
          '--build-arg=GITHUB_TOKEN=x',
          '--set=db.password=a=b',
          '--password=a=b',
          '--env=PATH=/usr/bin',
        ]),
        [
          'docker',
          '--env=DB_PASSWORD=$_mask',
          '--build-arg=GITHUB_TOKEN=$_mask',
          '--set=db.password=$_mask',
          '--password=$_mask',
          '--env=PATH=/usr/bin',
        ],
      );
    });

    test('the argument after a secret-named option, unless it is an '
        'option itself', () {
      final masked = maskCommandLine([
        'docker',
        'login',
        '--password',
        'hunter2',
        '-passin',
        'pass:s3cret',
        '--token',
        '--verbose',
      ]);

      expect(
        [for (final m in masked) m.display],
        [
          'docker',
          'login',
          '--password',
          _mask,
          // An attached -p is masked first; its secret name still masks
          // the argument after it.
          '-p$_mask',
          _mask,
          '--token',
          '--verbose',
        ],
      );
      expect(masked[3], MaskedValue.secret('hunter2'));
      expect(masked[5].reveal(), 'pass:s3cret');
    });

    test('URL credentials, keeping the rest of the URL', () {
      final masked = maskCommandLine([
        'psql',
        'postgres://app:s3cret@db.internal/app',
        '--url=https://u:p@example.com/x',
      ]);

      expect(
        [for (final m in masked) m.display],
        [
          'psql',
          'postgres://app:$_mask@db.internal/app',
          '--url=https://u:$_mask@example.com/x',
        ],
      );
      expect(masked[1].reveal(), 'postgres://app:s3cret@db.internal/app');
    });

    test('a URL whose query names a secret also keeps no credentials', () {
      expect(_shown(['curl', 'https://u:p@example.com/?token=abc']), [
        'curl',
        'https://u:$_mask@example.com/?token=$_mask',
      ]);
    });

    test('whitespace tokens inside one argument, as a shell -c command '
        'line and a ps fallback row carry them', () {
      expect(
        _shown(['sh', '-c', 'mysqldump -uroot -phunter2 db | gzip > x.gz']),
        ['sh', '-c', 'mysqldump -uroot -p$_mask db | gzip > x.gz'],
      );
      expect(_shown(['sh', '-c', 'app --password  hunter2']), [
        'sh',
        '-c',
        'app --password  $_mask',
      ]);
    });

    test('a quoted value inside a -c line runs to its closing quote, as '
        'the shell reads it', () {
      expect(
        _shown(['sh', '-c', "mysql --password='correct horse battery' db"]),
        ['sh', '-c', 'mysql --password=$_mask db'],
      );
      expect(_shown(['sh', '-c', 'cd /x && PGPASSWORD="two words" psql']), [
        'sh',
        '-c',
        'cd /x && PGPASSWORD=$_mask psql',
      ]);
      expect(_shown(['sh', '-c', 'cd /x && app --token "a b c" -v']), [
        'sh',
        '-c',
        'cd /x && app --token $_mask -v',
      ]);
      // Backslashes escape a quote or a space; an unclosed quote holds the
      // rest of the argument.
      expect(_shown(['sh', '-c', r'app -p"a \" b" --password=a\ b c']), [
        'sh',
        '-c',
        'app -p$_mask --password=$_mask c',
      ]);
      expect(_shown(['sh', '-c', "app --password='a b"]), [
        'sh',
        '-c',
        'app --password=$_mask',
      ]);
    });

    test('a ps fallback keeps no boundaries: a value with spaces is masked '
        'up to its first space only', () {
      // `ps` joins arguments with spaces (7.2), so `--password 'a b'`
      // arrives as three tokens.
      expect(_shown(['app', '--password', 'a', 'b']), [
        'app',
        '--password',
        _mask,
        'b',
      ]);
    });

    test('a value that starts an argument runs to its end, spaces and '
        'all, where the boundaries are real', () {
      final masked = maskCommandLine([
        'app',
        '--password=correct horse battery',
        '--password',
        'correct horse battery',
        'PGPASSWORD=two words',
        '-pa b',
      ]);

      expect(
        [for (final m in masked) m.display],
        [
          'app',
          '--password=$_mask',
          '--password',
          _mask,
          'PGPASSWORD=$_mask',
          '-p$_mask',
        ],
      );
      expect(masked[3], MaskedValue.secret('correct horse battery'));
      expect(masked[1].reveal(), '--password=correct horse battery');
    });

    test('over-masks rather than leaks: an attached -p is masked whatever '
        'it means, and KEY matches inside other words', () {
      final masked = maskCommandLine(['find', '/', '-print', 'MONKEY=1']);

      expect(
        [for (final m in masked) m.display],
        ['find', '/', '-p$_mask', 'MONKEY=$_mask'],
      );
      expect(masked[2].reveal(), '-print');
    });

    test('over-masks rather than leaks: a -c line that starts with a secret '
        'assignment is masked to its end', () {
      expect(_shown(['sh', '-c', 'PGPASSWORD=x psql -h db']), [
        'sh',
        '-c',
        'PGPASSWORD=$_mask',
      ]);
    });
  });

  test('masking takes time linear in an argument, whatever a host user '
      'puts in one', () {
    // An argument can hold 128 KiB (Linux's MAX_ARG_STRLEN), and every
    // procs sample masks them all in the one engine isolate.
    final watch = Stopwatch()..start();
    for (final argument in ['a=' * 65536, 'a' * 131072, '-x ${'a=' * 65535}']) {
      expect(_shown(['sh', argument]), ['sh', argument]);
    }
    expect(_shown(['sh', '${'a=' * 65535}KEY=x']), [
      'sh',
      '${'a=' * 65535}KEY=$_mask',
    ]);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  group('one budget bounds the tokens read; past it, arguments are masked '
      'whole', () {
    test('the rest of the argument that runs out, then every later one', () {
      final budget = ArgumentMaskingBudget(4);

      final first = maskCommandLine(['sh', '-c', 'a b c d'], budget: budget);
      expect([for (final m in first) m.display], ['sh', '-c', 'a b $_mask']);
      expect(first[2].reveal(), 'a b c d');

      final later = maskCommandLine(['ls', '', 'x y'], budget: budget);
      expect([for (final m in later) m.display], [_mask, '', _mask]);
      expect(later[2], MaskedValue.secret('x y'));
    });

    test('tokens inside a masked value count as read', () {
      expect(
        [
          for (final m in maskCommandLine([
            'sh',
            '-c',
            "app --password='a b c' d e",
          ], budget: ArgumentMaskingBudget(5)))
            m.display,
        ],
        ['sh', '-c', 'app --password=$_mask $_mask'],
      );
    });

    test('a call without one gets its own', () {
      final argv = ['sh', for (var i = 0; i < kArgumentTokensMasked; i++) 'a'];

      expect(_shown(argv).last, _mask);
      expect(_shown(argv.sublist(1)).last, 'a');
    });
  });

  group('tokens that only look secret stay as they are', () {
    for (final (what, argv) in [
      ('the program, even a secret-sounding one', ['/usr/bin/passwd', 'me']),
      ('a login shell\'s dash', ['-bash']),
      ('a login shell that starts like an attached -p', ['-pwsh']),
      (
        'a program named like a secret option, before an argument',
        ['--password-helper', 'run'],
      ),
      ('a bare -p and a separate port', ['ssh', '-p', '2222', 'me@host']),
      ('an upper-case -P and a port option', ['mysql', '-P3306', '--port=1']),
      ('an empty secret assignment', ['app', '--password=']),
      ('a negated flag before an argument', ['app', '--no-password', 'run']),
      ('a secret-named option at the end', ['app', 'run', '--token']),
      (
        'URLs without a password',
        [
          'git',
          'clone',
          'git@github.com:org/repo.git',
          'ssh://me@host/repo',
          'http://example.com:8080/a@b',
        ],
      ),
      ('variables whose names are not secret', ['env', 'PATH=/usr/bin']),
      ('an empty command line', <String>[]),
    ]) {
      test(what, () {
        final masked = maskCommandLine(argv);

        expect([for (final m in masked) m.display], argv);
        expect(masked.where((m) => m.isMasked), isEmpty);
      });
    }

    test('an argument of whitespace only', () {
      expect(_shown(['sh', ' ', '']), ['sh', ' ', '']);
    });
  });
}
