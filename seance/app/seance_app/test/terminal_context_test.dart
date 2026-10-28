import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/terminal_context.dart';
import 'package:xterm/xterm.dart';

List<String> _values(
  String text, {
  String? cwd = '/home/me/project',
  String? home,
}) => [
  for (final item in detectContextItems(
    text,
    workingDirectory: cwd,
    homeDirectory: home,
  ))
    '${item.kind.name}:${item.value}',
];

void main() {
  group('detectContextItems', () {
    test('finds links and trims what the sentence put around them', () {
      expect(_values('see https://example.com/a?b=1&c=2. or (http://x.io/y)'), [
        'url:https://example.com/a?b=1&c=2',
        'url:http://x.io/y',
      ]);
      expect(_values('https://en.wikipedia.org/wiki/Foo_(bar), next'), [
        'url:https://en.wikipedia.org/wiki/Foo_(bar)',
      ]);
    });

    test('ignores schemes it cannot open and links with credentials', () {
      expect(_values('file:///etc/passwd ftp://a.b/c'), isEmpty);
      expect(_values('https://user:pw@example.com/x'), isEmpty);
      expect(_values('https:// nothing'), isEmpty);
    });

    test('never reads a link a second time as a path', () {
      expect(_values('clone https://github.com/a/b.git now'), [
        'url:https://github.com/a/b.git',
      ]);
    });

    test('finds absolute, home and dot-relative paths', () {
      expect(
        _values('cat /etc/hosts ~/notes.md ./build/ ../x', home: '/home/me'),
        [
          'path:/etc/hosts',
          'path:/home/me/notes.md',
          'path:/home/me/project/build',
          'path:/home/me/x',
        ],
      );
    });

    test('keeps a home path unresolved until the home is known', () {
      expect(_values('~/a/../b.txt'), ['path:~/b.txt']);
    });

    test('reads slash-relative names only when they look like files', () {
      expect(
        _values('modified:   lib/main.dart\n\tsrc/\nand/or 10 MB/s 2026/10/28'),
        ['path:/home/me/project/lib/main.dart', 'path:/home/me/project/src'],
      );
    });

    test('drops relative paths without a working directory', () {
      expect(_values('lib/main.dart /etc/hosts', cwd: null), [
        'path:/etc/hosts',
      ]);
    });

    test('splits a location suffix and a PATH list', () {
      final items = detectContextItems(
        'lib/a.dart:12:5: error\nPATH=/usr/bin:/bin',
        workingDirectory: '/w',
      );
      expect(items.map((i) => i.value), ['/w/lib/a.dart', '/usr/bin', '/bin']);
      expect(items.first.label, 'lib/a.dart:12:5');
    });

    test('finds a path after a flag, a quote or a bracket', () {
      expect(_values('--prefix=/usr/local "/tmp/a b" (/var/log)'), [
        'path:/usr/local',
        'path:/tmp/a',
        'path:/var/log',
      ]);
    });

    test('leaves out a prompt\'s own directory', () {
      expect(_values(r'me@host:~/src$ cat ./a.txt', home: '/home/me'), [
        'path:/home/me/project/a.txt',
      ]);
      expect(_values('root@host:/etc# ls'), isEmpty);
    });

    test('leaves out markup a page printed', () {
      expect(
        _values('<title>Example</title></head><body><br/><p>x</p></body>'),
        isEmpty,
      );
      expect(_values('/* comment */ int x;'), isEmpty);
    });

    test('leaves out the directory other prompts show', () {
      for (final prompt in [
        r'me@host ~/src/project $ make',
        r'[me@host ~/src]$ ls',
        r'me@host ~/s/project> ls',
        r'~/src ❯ ls',
      ]) {
        expect(_values(prompt, home: '/home/me'), isEmpty, reason: prompt);
      }
      // A redirect after a path is not a prompt.
      expect(_values('sort /tmp/in.txt > out'), ['path:/tmp/in.txt']);
    });

    test('reads a diff header without its a/ and b/', () {
      expect(_values('diff --git a/lib/main.dart b/lib/main.dart'), [
        'path:/home/me/project/lib/main.dart',
        'path:/home/me/project/lib/main.dart',
      ]);
      expect(_values('+++ b/src/app.ts'), ['path:/home/me/project/src/app.ts']);
      // Elsewhere an a/ is a real folder.
      expect(_values('cat a/b.txt'), ['path:/home/me/project/a/b.txt']);
    });

    test('leaves out what a column or --stat cut short', () {
      expect(_values(' .../services/terminal_context.dart | 345 +++'), isEmpty);
      expect(_values('"/docker-entrypoint.…"   Up 2 hours'), isEmpty);
      expect(_values('see https://example.com/… now'), isEmpty);
      expect(_values('tail /var/log/app... (truncated)'), isEmpty);
      expect(_values('docs at https://... soon'), isEmpty);
    });

    test('reads a comma-separated list as its files', () {
      expect(_values('img/logo.png,img/bg.png'), [
        'path:/home/me/project/img/logo.png',
        'path:/home/me/project/img/bg.png',
      ]);
      expect(_values('/a/x.txt,/b/y.txt'), ['path:/a/x.txt', 'path:/b/y.txt']);
    });

    test('leaves out another host\'s paths', () {
      expect(_values('origin  git@github.com:org/repo.git (fetch)'), isEmpty);
      expect(_values('rsync -av src/ backup.example.com:/var/www/'), [
        'path:/home/me/project/src',
      ]);
      expect(_values('dir C:/Users/me'), isEmpty);
      for (final remote in [
        'scp backup.tar.gz prod:/var/backups/',
        'scp backup.tar.gz 192.168.1.10:/var/backups/',
        'rsync -av dist/ backup.example.com:archives/site.tar.gz',
        'git clone gitlab:group/repo.git',
        'nas:/volume1/data',
        'remote.origin.url=git@github.com:L-K-M/Hauntware.git',
        'BORG_REPO=user@nas:/volume1/backup',
        'REPO=backup.example.com:/srv/borg',
        'restic -r sftp:user@host:/srv/restic-repo init',
        'scp backup.tar.gz [2001:db8::5]:/var/backups/',
        'kubectl cp default/web-7d9f8:/var/log/app.log',
        'remote.origin.url=192.168.1.10:/srv/git/project.git',
        'export BORG_REPO=nas:/volume1/borg',
        'RESTIC_REPOSITORY=sftp:nas:/srv/restic',
      ]) {
        expect(
          _values(remote).where((v) => !v.contains('/project/dist')),
          isEmpty,
          reason: remote,
        );
      }
      expect(_values('scp me@host:/etc/hosts .'), isEmpty);
    });

    test('leaves out a mount\'s container side written as an option', () {
      expect(_values('docker run --volume=./conf:/etc/nginx/conf.d nginx'), [
        'path:/home/me/project/conf',
      ]);
      expect(_values('docker run -v=/srv/data:/var/lib/postgresql/data pg'), [
        'path:/srv/data',
      ]);
      expect(_values('systemd-nspawn --bind=/srv/www:/var/www'), [
        'path:/srv/www',
      ]);
      expect(
        _values('docker run --mount type=bind,src=/srv/conf,dst=/etc/nginx'),
        ['path:/srv/conf'],
      );
    });

    test('reads a path after a closing quote as part of the word', () {
      expect(_values('export PATH="\$HOME"/bin:\$PATH'), isEmpty);
      expect(_values('cp "\$HOME"/.bashrc /tmp/'), ['path:/tmp']);
      expect(_values('echo "hello"/world.txt'), isEmpty);
      // An opening quote still starts a path.
      expect(_values('--prefix="/usr/local" "/tmp/x"'), [
        'path:/usr/local',
        'path:/tmp/x',
      ]);
    });

    test('drops git\'s prefix from an added binary', () {
      expect(_values('Binary files /dev/null and b/img/new.png differ'), [
        'path:/dev/null',
        'path:/home/me/project/img/new.png',
      ]);
    });

    test('drops git\'s prefixes from a binary diff', () {
      expect(
        _values('Binary files a/assets/logo.png and b/assets/logo.png differ'),
        [
          'path:/home/me/project/assets/logo.png',
          'path:/home/me/project/assets/logo.png',
        ],
      );
    });

    test('drops a sanitizer frame\'s module offset', () {
      expect(
        _values(
          '#1 0x7f00 in __libc_start_main (/lib/x86_64-linux-gnu/libc.so.6+0x29d8f)',
        ),
        ['path:/lib/x86_64-linux-gnu/libc.so.6'],
      );
    });

    test('ends a path at CJK punctuation wherever it stands', () {
      expect(_values('已保存到 /tmp/a.txt。'), ['path:/tmp/a.txt']);
      expect(_values('設定 /etc/nginx/nginx.conf。次に再起動します'), [
        'path:/etc/nginx/nginx.conf',
      ]);
      expect(_values('/etc/hosts、/etc/passwd を編集'), [
        'path:/etc/hosts',
        'path:/etc/passwd',
      ]);
      expect(_values('已保存到 /home/me/报告.txt，请查看'), ['path:/home/me/报告.txt']);
      expect(_values('保存先：/tmp/a.txt'), ['path:/tmp/a.txt']);
    });

    test('keeps a glibc frame\'s file and drops a copy\'s cut name', () {
      expect(_values('./app(+0x1149)[0x55d0]'), ['path:/home/me/project/app']);
      expect(_values('/srv/build/app(+0x2a1f) [0x5612]'), [
        'path:/srv/build/app',
      ]);
      expect(_values('/home/me/Downloads/report(1).pdf'), isEmpty);
    });

    test('reads an option\'s target outside a mount', () {
      expect(_values('pip install --target=/opt/libs requests'), [
        'path:/opt/libs',
      ]);
    });

    test('leaves out a quoted attribute on its own line', () {
      expect(_values('+        src="/logo.svg"'), isEmpty);
      expect(_values('  href="/css/app.css"'), isEmpty);
    });

    test('reads a long dotted name in linear time', () {
      final watch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        _values('lib/x.${'a' * 4000}_');
      }
      // The backtracking extension pattern this replaced took about 80 ms
      // per line.
      expect(watch.elapsedMilliseconds, lessThan(500));
    });

    test('offers the host side of a mount, not the container\'s', () {
      expect(
        _values('docker run -v /srv/postgres:/var/lib/postgresql/data pg'),
        ['path:/srv/postgres'],
      );
      expect(_values('  - ./nginx.conf:/etc/nginx/nginx.conf:ro'), [
        'path:/home/me/project/nginx.conf',
      ]);
    });

    test('leaves out web routes', () {
      for (final line in [
        '1.2.3.4 - - "GET /wp-login.php HTTP/1.1" 404',
        'Started GET "/users/1" for 127.0.0.1',
        '> POST /v1/messages HTTP/2',
        '< Location: /login?next=%2Fadmin',
        '<a href="/about">About</a><script src="/js/main.js">',
        '<form action="/login">',
        'GET /api/users?id=1 200',
      ]) {
        expect(_values(line), isEmpty, reason: line);
      }
      // A file path in a sentence that ends in a question still reads.
      expect(_values('Did you mean /etc/hosts?'), ['path:/etc/hosts']);
    });

    test('leaves out a stack frame\'s method', () {
      expect(
        _values('\tat java.base/java.lang.Thread.run(Thread.java:1583)'),
        isEmpty,
      );
    });

    test('leaves out a Go stack frame\'s function', () {
      for (final frame in [
        'net/http.serverHandler.ServeHTTP({0xc000134000?}, 0xc000176000)',
        'github.com/org/repo/pkg.TestFoo(0xc000007ba0)',
        'github.com/org/repo/internal/server.Run(...)',
        'runtime/debug.Stack()',
        'gopkg.in/yaml.v3.(*decoder).unmarshal(0xc000, 0xc00)',
      ]) {
        expect(_values('\t$frame'), isEmpty, reason: frame);
      }
      expect(_values('\t/home/me/project/main.go:12 +0x1d'), [
        'path:/home/me/project/main.go',
      ]);
    });

    test('reads a file before its location in parentheses', () {
      expect(_values('> /home/me/project/app.py(12)main()'), [
        'path:/home/me/project/app.py',
      ]);
      expect(_values('/home/me/project/Program.cs(12,5): error CS1002'), [
        'path:/home/me/project/Program.cs',
      ]);
      expect(_values('src/a.ts(3,4): error TS2322'), [
        'path:/home/me/project/src/a.ts',
      ]);
      expect(_values('#0 /var/www/html/index.php(12): foo()'), [
        'path:/var/www/html/index.php',
      ]);
    });

    test('reads a database URL without failing', () {
      for (final line in [
        'url: jdbc:postgresql://db:5432/app?sslmode=require',
        'mongodb://admin:pw@mongo:27017/app?authSource=admin',
        'redis://localhost:6379/0?db=1',
        'DSN: postgres://u@h:5432/db?sslmode=disable',
        'nas:/volume1/a=b',
      ]) {
        expect(() => _values(line), returnsNormally, reason: line);
      }
    });

    test('reads a Location label that is not a redirect', () {
      expect(
        _values('Location: /home/me/.local/lib/python3.12/site-packages'),
        ['path:/home/me/.local/lib/python3.12/site-packages'],
      );
      expect(_values('Editable project location: /home/me/p'), [
        'path:/home/me/p',
      ]);
    });

    test('leaves out a progress bar\'s totals', () {
      expect(
        _values(' 45%|####  | 2.23G/4.94G [00:52<01:03, 42.6MB/s]'),
        isEmpty,
      );
      expect(_values('| 1.34k/1.34k ['), isEmpty);
    });

    test('reads a long path list in one pass', () {
      final watch = Stopwatch()..start();
      _values('/a:' * (contextLineLimit ~/ 3));
      _values('CLASSPATH=${'/opt/lib/x.jar:' * 270}');
      // The per-path rescans this replaced took hundreds of milliseconds.
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });

    test('reads every entry of a path list', () {
      expect(_values('CLASSPATH=.:/usr/share/java/junit.jar'), [
        'path:/usr/share/java/junit.jar',
      ]);
      expect(_values('PATH=/usr/local/bin:/usr/bin'), [
        'path:/usr/local/bin',
        'path:/usr/bin',
      ]);
      // `bin` could be a host as well as a folder, so what follows it is
      // left out; the entry after a path is read.
      expect(_values('PATH=bin:/usr/local/bin:/usr/bin'), ['path:/usr/bin']);
      expect(_values('/usr/local/bin:/usr/bin:/bin'), [
        'path:/usr/local/bin',
        'path:/usr/bin',
        'path:/bin',
      ]);
      // Without list context a `before:` may name a host or a container,
      // so the far side is left out.
      expect(_values('/usr/bin:/bin'), ['path:/usr/bin']);
      expect(_values('Error:/x/y.txt'), isEmpty);
    });

    test('reads a path before a comment', () {
      expect(_values('source ~/.cargo/env # rust', home: '/home/me'), [
        'path:/home/me/.cargo/env',
      ]);
      expect(_values('node_modules/ # deps'), [
        'path:/home/me/project/node_modules',
      ]);
      expect(_values('[root@host /etc]# ls'), isEmpty);
      expect(_values('myhost /etc/portage # ', cwd: '/etc/portage'), isEmpty);
    });

    test('reads a path a sentence closes with three dots', () {
      expect(_values('Writing /etc/nginx/nginx.conf...'), [
        'path:/etc/nginx/nginx.conf',
      ]);
      expect(_values('Checking /usr/lib/x.so... ok'), ['path:/usr/lib/x.so']);
    });

    test('drops Markdown emphasis around a link', () {
      expect(_values('**https://example.com/docs**'), [
        'url:https://example.com/docs',
      ]);
    });

    test('reads an IPv6 link', () {
      expect(_values('Serving HTTP on :: port 8000 (http://[::]:8000/) ...'), [
        'url:http://[::]:8000/',
      ]);
    });

    test('does not offer a value the line limit cut', () {
      final pad = 'x' * (contextLineLimit - 30);
      expect(
        _values('$pad https://example.com/some/long/path/here.html'),
        isEmpty,
      );
      expect(_values('$pad /home/me/project/build/main.cpp.o'), isEmpty);
    });

    test('ends a path at a quote the sentence closes', () {
      expect(_values('“Saved to /tmp/out.pdf”'), ['path:/tmp/out.pdf']);
      expect(_values('unrecognized option: ‘--prefix=/usr/local’'), [
        'path:/usr/local',
      ]);
    });

    test('keeps an apostrophe inside a name', () {
      expect(_values('~/Documents/Dad’s_taxes.pdf', home: '/home/me'), [
        'path:/home/me/Documents/Dad’s_taxes.pdf',
      ]);
    });

    test('reads paths in curly quotes', () {
      expect(_values('Saving to: ‘foo/bar.tar.gz’'), [
        'path:/home/me/project/foo/bar.tar.gz',
      ]);
      expect(_values('cannot stat “/etc/hosts”'), ['path:/etc/hosts']);
    });

    test('refuses a value with bidi or invisible characters', () {
      expect(_values('/Users/me/\u202Efdp.exe'), isEmpty);
      expect(_values('https://evil.example/\u202Emoc.knab'), isEmpty);
      expect(_values('/tmp/a\u200Bb.txt'), isEmpty);
    });

    test('keeps a home path inside a home it does not know yet', () {
      expect(_values('cat ~/../../etc/x'), isEmpty);
      expect(_values('cat ~/../../etc/x', home: '/home/me'), ['path:/etc/x']);
    });

    test('reads a long line in linear time', () {
      final watch = Stopwatch()..start();
      _values('https://a.b/${')' * 8000}');
      _values('https://a.b/${'.' * 32000}x');
      _values('/a${'.' * 16000}x');
      _values('x /etc/a.txt ' * 40000);
      // The quadratic trimming this replaced took seconds per line; the
      // bound only has to catch that, not time a busy CI runner.
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });

    test('leaves out the root, comments and sentence punctuation', () {
      expect(_values('cd / // comment, see /etc/hosts.'), ['path:/etc/hosts']);
    });
  });

  group('TerminalContextStack', () {
    late Terminal terminal;
    late ValueNotifier<String?> cwd;
    late TerminalContextStack stack;

    setUp(() {
      terminal = Terminal(maxLines: 1000);
      cwd = ValueNotifier<String?>('/srv');
      stack = TerminalContextStack(terminal: terminal, workingDirectory: cwd);
    });

    tearDown(() {
      stack.dispose();
      cwd.dispose();
    });

    List<String> values() => [for (final item in stack.items) item.value];

    test('puts the newest finished line on top', () {
      terminal.write('one /etc/hosts\r\ntwo https://example.com\r\n\$ ');
      stack.scanNow();
      expect(values(), ['https://example.com', '/etc/hosts']);
    });

    test('skips the line under the cursor until it is finished', () {
      terminal.write('\$ cat /usr/lo');
      stack.scanNow();
      expect(values(), isEmpty);

      terminal.write('cal/x.txt\r\n');
      stack.scanNow();
      expect(values(), ['/usr/local/x.txt']);
    });

    test('reads a path wrapped across rows as one', () {
      terminal.resize(20, 10);
      terminal.write('see /var/lib/some/long/name.txt ok\r\n');
      stack.scanNow();
      expect(values(), ['/var/lib/some/long/name.txt']);
    });

    test('reads tab-separated columns as separate words', () {
      terminal.write('M\tlib/main.dart\r\n4.0K\t./build/\r\n\$ ');
      stack.scanNow();
      expect(values(), ['/srv/build', '/srv/lib/main.dart']);
    });

    test('reads a wide character at the edge of a wrapped row', () {
      terminal.resize(20, 10);
      terminal.write('cat /srv/abcdefghij北京/notes.txt\r\n\$ ');
      stack.scanNow();
      expect(values(), ['/srv/abcdefghij北京/notes.txt']);
    });

    test('reads a tab gap at the edge of a wrapped row as a space', () {
      // Past the last tab stop the cursor waits at the edge, so the next
      // column starts on the wrapped row.
      terminal.resize(36, 10);
      terminal.write('/srv/lib/aaaaa/bbbbb/ccccc/dd.txt\tlib/new.txt\r\n\$ ');
      stack.scanNow();
      expect(values(), [
        '/srv/lib/new.txt',
        '/srv/lib/aaaaa/bbbbb/ccccc/dd.txt',
      ]);
    });

    test('reads a tab gap after a wide character as a space', () {
      terminal.write('/srv/文\tb/c.txt\r\n\$ ');
      stack.scanNow();
      expect(values(), ['/srv/b/c.txt', '/srv/文']);
    });

    test('reads a line the same after narrowing the window', () {
      terminal.resize(40, 10);
      terminal.write('cat /srv/abcdefghij北京/notes.txt\r\n\$ ');
      stack.scanNow();
      terminal.resize(20, 10);
      stack.scanNow();
      expect(values(), ['/srv/abcdefghij北京/notes.txt']);
    });

    test('reads a wide-character path the same after widening', () {
      for (var width = 6; width <= 70; width++) {
        for (final grow in [7, 9]) {
          final wide = Terminal(maxLines: 1000);
          final own = TerminalContextStack(
            terminal: wide,
            workingDirectory: cwd,
            homeDirectory: () => '/home/me',
          );
          wide.resize(width, 10);
          wide.write('Saved ~/文档/报告/二零二六年十月.xlsx\r\n\$ ');
          own.scanNow();
          wide.resize(width + grow, 10);
          own.scanNow();
          expect(
            [for (final item in own.items) item.value],
            ['/home/me/文档/报告/二零二六年十月.xlsx'],
            reason: '$width -> ${width + grow}',
          );
          own.dispose();
        }
      }
    });

    test('reads on after the vendored xterm loses rows', () {
      // CSI 3J and then a resize leave rows unset in the fork's buffer, and
      // its own next write fails on them (outside this tab). The stack's
      // read must still return.
      terminal.resize(80, 24);
      for (var i = 0; i < 30; i++) {
        terminal.write('line \$i /etc/hosts\r\n');
      }
      terminal.write('\$ clear\r\n\x1b[H\x1b[2J\x1b[3J\$ ');
      terminal.resize(100, 30);
      expect(() => terminal.write('ls\r\n'), throwsA(anything));
      expect(stack.scanNow, returnsNormally);
    });

    test('ignores the alternate screen', () {
      terminal.write('\x1b[?1049h/etc/hosts\r\n');
      stack.scanNow();
      expect(values(), isEmpty);
    });

    test('a cleared stack stays clear until the item is printed again', () {
      terminal.write('/etc/hosts\r\n/etc/passwd\r\n');
      stack.scanNow();
      stack.clear();
      stack.scanNow();
      expect(values(), isEmpty);

      terminal.write('again /etc/hosts\r\n');
      stack.scanNow();
      expect(values(), ['/etc/hosts']);
    });

    test('moves a repeated item back to the top', () {
      terminal.write('/a.txt\r\n/b.txt\r\n');
      stack.scanNow();
      terminal.write('/a.txt\r\n');
      stack.scanNow();
      expect(values(), ['/a.txt', '/b.txt']);
    });

    test('keeps at most its capacity', () {
      for (var i = 0; i < TerminalContextStack.capacity + 10; i++) {
        terminal.write('/f$i.txt\r\n');
      }
      stack.scanNow();
      expect(stack.items, hasLength(TerminalContextStack.capacity));
      expect(
        stack.items.first.value,
        '/f${TerminalContextStack.capacity + 9}.txt',
      );
    });

    test('resolves relative paths where the shell was', () {
      terminal.write('src/a.c\r\n');
      stack.scanNow();
      cwd.value = '/tmp';
      terminal.write('src/a.c\r\n');
      stack.scanNow();
      expect(values(), ['/tmp/src/a.c', '/srv/src/a.c']);
    });

    testWidgets('reads on its own after output settles', (tester) async {
      // Built inside the test so its throttle runs on the fake clock.
      final own = TerminalContextStack(
        terminal: terminal,
        workingDirectory: cwd,
      );
      addTearDown(own.dispose);
      await tester.pump(TerminalContextStack.scanDelay);
      terminal.write('/etc/hosts\r\n');
      expect(own.items, isEmpty);
      await tester.pump(TerminalContextStack.scanDelay);
      expect([for (final item in own.items) item.value], ['/etc/hosts']);
    });
  });
}
