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

  group('known tools: the separate value of a secret option and secret '
      'header values (03 §8.9)', () {
    test('sshpass -p, and the command it runs keeps its own options', () {
      expect(
        _shown(['sshpass', '-p', 'hunter2', 'ssh', '-p', '22', 'me@host']),
        ['sshpass', '-p', _mask, 'ssh', '-p', '22', 'me@host'],
      );
      expect(
        _shown(['sh', '-c', 'sshpass -f pw.txt rsync -p a b; sshpass -p x y']),
        ['sh', '-c', 'sshpass -f pw.txt rsync -p a b; sshpass -p $_mask y'],
      );
    });

    test('curl user:password values keep the user, as URL credentials do', () {
      final masked = maskCommandLine([
        '/usr/bin/curl',
        '-u',
        'me:hunter2',
        '--user',
        'me:a b',
        '-U',
        'proxy:p',
        '--proxy-user',
        'proxy:q',
        '-uattached:r',
        '-su',
        'cluster:s',
        '-E',
        'client.pem:t',
        '--cert',
        'client.pem:u',
        'https://example.com',
      ]);

      expect(
        [for (final m in masked) m.display],
        [
          '/usr/bin/curl',
          '-u',
          'me:$_mask',
          '--user',
          'me:$_mask',
          '-U',
          'proxy:$_mask',
          '--proxy-user',
          'proxy:$_mask',
          '-uattached:$_mask',
          '-su',
          'cluster:$_mask',
          '-E',
          'client.pem:$_mask',
          '--cert',
          'client.pem:$_mask',
          'https://example.com',
        ],
      );
      expect(masked[2].reveal(), 'me:hunter2');
      expect(masked[2].toString(), isNot(contains('hunter2')));
      expect(_shown(['sh', '-c', "curl -fsS -u 'me:a b' https://h | sh"]), [
        'sh',
        '-c',
        "curl -fsS -u 'me:$_mask https://h | sh",
      ]);
    });

    test('a curl user without a password and a client certificate without '
        'a passphrase stay visible', () {
      final argv = ['curl', '-u', 'me', '-E', 'client.pem', '-p', 'https://h'];
      expect(_shown(argv), argv);
    });

    test('secret header values keep the header name', () {
      final masked = maskCommandLine([
        'curl',
        '-H',
        'Authorization: Bearer abc',
        '--header',
        'proxy-authorization: Basic eA==',
        '-H',
        'Cookie: session=1',
        '-H',
        'Set-Cookie: a=b',
        '-H',
        'X-Auth-Token: t',
        '-H',
        'Private-Token:t',
        '-H',
        'x-api-key: k',
        '-H',
        'X-Client-Secret: s',
        '-H',
        'X-Upstream-Auth: a',
        '-H',
        'X-Goog-Api-Key-Id: i',
        '-HAuthorization: Bearer abc',
        'https://h',
      ]);

      expect(
        [for (final m in masked) m.display],
        [
          'curl',
          '-H',
          'Authorization:$_mask',
          '--header',
          'proxy-authorization:$_mask',
          '-H',
          'Cookie:$_mask',
          '-H',
          'Set-Cookie:$_mask',
          '-H',
          'X-Auth-Token:$_mask',
          '-H',
          'Private-Token:$_mask',
          '-H',
          'x-api-key:$_mask',
          '-H',
          'X-Client-Secret:$_mask',
          '-H',
          'X-Upstream-Auth:$_mask',
          '-H',
          'X-Goog-Api-Key-Id:$_mask',
          '-HAuthorization:$_mask',
          'https://h',
        ],
      );
      expect(masked[2].reveal(), 'Authorization: Bearer abc');
    });

    test('a header value inside a -c line runs to its closing quote', () {
      expect(
        _shown([
          'sh',
          '-c',
          'curl -H "Authorization: Bearer a b" -H "Accept: */*" https://h',
        ]),
        [
          'sh',
          '-c',
          'curl -H "Authorization:$_mask -H "Accept: */*" https://h',
        ],
      );
      expect(
        _shown(['sh', '-c', "wget --header='Cookie: a=1; b=2' -q https://h"]),
        ['sh', '-c', 'wget --header=\'Cookie:$_mask -q https://h'],
      );
    });

    test('a ps fallback header masks the token after the name', () {
      expect(_shown(['curl -H Authorization: Bearer abc https://h']), [
        'curl -H Authorization: $_mask abc https://h',
      ]);
    });

    test('wget --header, and httpie header items and --auth', () {
      expect(
        _shown([
          'wget',
          '--header=X-API-Key: k',
          '--header',
          'Authorization: Basic eA==',
          '--password',
          'p',
          '--http-password=q',
          '--ftp-password',
          'r',
          'https://h',
        ]),
        [
          'wget',
          '--header=X-API-Key:$_mask',
          '--header',
          'Authorization:$_mask',
          '--password',
          _mask,
          '--http-password=$_mask',
          '--ftp-password',
          _mask,
          'https://h',
        ],
      );
      expect(
        _shown([
          'http',
          '-a',
          'me:hunter2',
          'GET',
          'https://h',
          'Authorization:Bearer abc',
          'X-API-Key:k',
          'Accept:application/json',
        ]),
        [
          'http',
          '-a',
          'me:$_mask',
          'GET',
          'https://h',
          'Authorization:$_mask',
          'X-API-Key:$_mask',
          'Accept:application/json',
        ],
      );
      // A bearer token has no `:`, so httpie's --auth is masked whole.
      expect(_shown(['http', '-A', 'bearer', '-a', 'abc', 'https://h']), [
        'http',
        '-A',
        'bearer',
        '-a',
        _mask,
        'https://h',
      ]);
    });

    test('a header that is not secret, and a secret assignment inside one', () {
      expect(
        _shown(['curl', '-H', 'Accept: text/html', '-H', 'X-Q: token=abc']),
        ['curl', '-H', 'Accept: text/html', '-H', 'X-Q: token=$_mask'],
      );
    });

    test('redis-cli -a and mongosh -p, while their ports stay visible', () {
      expect(_shown(['redis-cli', '-h', 'db', '-p', '6379', '-a', 'hunter2']), [
        'redis-cli',
        '-h',
        'db',
        '-p',
        '6379',
        '-a',
        _mask,
      ]);
      expect(
        _shown(['mongosh', '--port', '27017', '-u', 'me', '-p', 'hunter2']),
        ['mongosh', '--port', '27017', '-u', 'me', '-p', _mask],
      );
      expect(_shown(['mongo', '-p', 'x']), ['mongo', '-p', _mask]);
    });

    test('htpasswd -b takes the password as its last positional argument', () {
      expect(_shown(['htpasswd', '-b', '/etc/htpasswd', 'me', 'hunter2']), [
        'htpasswd',
        '-b',
        '/etc/htpasswd',
        'me',
        _mask,
      ]);
      expect(_shown(['htpasswd', '-nbB', '-C', '10', 'me', 'hunter2']), [
        'htpasswd',
        '-nbB',
        '-C',
        '10',
        'me',
        _mask,
      ]);
      final prompted = ['htpasswd', '-c', '/etc/htpasswd', 'me'];
      expect(_shown(prompted), prompted);
    });

    test('openssl pass phrase arguments keep their source', () {
      expect(
        _shown([
          'openssl',
          'pkcs12',
          '-passin',
          'pass:hunter2',
          '-passout',
          'env:OUT_PW',
          '-pass',
          'bare',
        ]),
        [
          'openssl',
          'pkcs12',
          '-passin',
          'pass:$_mask',
          '-passout',
          'env:$_mask',
          '-pass',
          _mask,
        ],
      );
      expect(
        _shown(['openssl', 'enc', '-aes256', '-k', 'hunter2', '-in', 'f']),
        ['openssl', 'enc', '-aes256', '-k', _mask, '-in', 'f'],
      );
    });

    test('smbclient user%password keeps the user', () {
      expect(
        _shown([
          'smbclient',
          '//h/s',
          '-U',
          'me%hunter2',
          '-Ume%x',
          '--user=me%y',
        ]),
        [
          'smbclient',
          '//h/s',
          '-U',
          'me%$_mask',
          '-Ume%$_mask',
          '--user=me%$_mask',
        ],
      );
      final prompted = ['smbclient', '//h/s', '-U', 'me'];
      expect(_shown(prompted), prompted);
    });

    test('vault and consul -token, mysql --password', () {
      expect(_shown(['vault', 'login', '-token', 's.x', '-token=s.y']), [
        'vault',
        'login',
        '-token',
        _mask,
        '-token=$_mask',
      ]);
      expect(_shown(['consul', 'members', '-token', 'x']), [
        'consul',
        'members',
        '-token',
        _mask,
      ]);
      expect(_shown(['mysql', '--password', 'x', '-phunter2']), [
        'mysql',
        '--password',
        _mask,
        '-p$_mask',
      ]);
    });

    test('docker login -p, while docker run -p publishes a port', () {
      expect(
        _shown([
          'docker',
          '-H',
          'tcp://h:2376',
          'login',
          '-u',
          'me',
          '-p',
          'hunter2',
          'registry',
        ]),
        [
          'docker',
          '-H',
          'tcp://h:2376',
          'login',
          '-u',
          'me',
          '-p',
          _mask,
          'registry',
        ],
      );
      expect(_shown(['sh', '-c', 'podman login -p x r && podman run -p 1 i']), [
        'sh',
        '-c',
        'podman login -p $_mask r && podman run -p 1 i',
      ]);
      final run = ['docker', 'run', '-p', '8080:80', '-u', '1000:1000', 'i'];
      expect(_shown(run), run);
    });

    test('a command after a shell separator is read on its own', () {
      for (final line in [
        'curl -s https://h && sudo -u www:data ls',
        'curl -s https://h; app -u me:x',
        'curl -s https://h | app -H Authorization:x',
      ]) {
        expect(_shown(['sh', '-c', line]), ['sh', '-c', line]);
      }
    });

    test('a tool is found after a wrapper and inside a -c line', () {
      expect(
        _shown(['sudo', '-u', 'root', 'env', 'A=1', 'curl', '-u', 'me:x']),
        ['sudo', '-u', 'root', 'env', 'A=1', 'curl', '-u', 'me:$_mask'],
      );
      expect(_shown(['', 'x=\$(curl -u me:x https://h)']), [
        '',
        'x=\$(curl -u me:$_mask https://h)',
      ]);
    });

    test('-p with a separate value on a tool not in the table stays '
        'visible', () {
      for (final argv in [
        ['app', '-p', '8080'],
        ['ssh', '-p', '22', 'h'],
        ['mkdir', '-p', '/x'],
        ['python3', '-m', 'http.server', '-b', '::', '8080'],
      ]) {
        expect(_shown(argv), argv);
      }
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
    // The known tools' rules read an option cluster, a header name and a
    // program's name once each.
    final cluster = '-${'s' * 131071}';
    expect(_shown(['curl', cluster]), ['curl', cluster]);
    expect(_shown(['curl', '-H', '${'a' * 131071}:']), [
      'curl',
      '-H',
      '${'a' * 131071}:',
    ]);
    final names = 'curl ${'x/curl ' * 20000}';
    expect(_shown(['sh', names]), ['sh', names]);
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
