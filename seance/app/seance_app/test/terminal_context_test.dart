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
      expect(_values('scp me@host:/etc/hosts .'), isEmpty);
    });

    test('reads every entry of a path list, and paths after a message', () {
      expect(_values('CLASSPATH=.:/usr/share/java/junit.jar'), [
        'path:/usr/share/java/junit.jar',
      ]);
      expect(_values('PATH=bin:/usr/local/bin:/usr/bin'), [
        'path:/usr/local/bin',
        'path:/usr/bin',
      ]);
      expect(_values('java -cp app.jar:lib/dep.jar Main'), [
        'path:/home/me/project/lib/dep.jar',
      ]);
      expect(_values('Error:/x/y.txt'), ['path:/x/y.txt']);
    });

    test('reads a path before a comment', () {
      expect(_values('source ~/.cargo/env # rust', home: '/home/me'), [
        'path:/home/me/.cargo/env',
      ]);
      expect(_values('node_modules/ # deps'), [
        'path:/home/me/project/node_modules',
      ]);
      expect(_values('[root@host /etc]# ls'), isEmpty);
    });

    test('does not offer a value the line limit cut', () {
      final pad = 'x' * (contextLineLimit - 30);
      expect(
        _values('$pad https://example.com/some/long/path/here.html'),
        isEmpty,
      );
      expect(_values('$pad /home/me/project/build/main.cpp.o'), isEmpty);
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

    test('reads a line the same after narrowing the window', () {
      terminal.resize(40, 10);
      terminal.write('cat /srv/abcdefghij北京/notes.txt\r\n\$ ');
      stack.scanNow();
      terminal.resize(20, 10);
      stack.scanNow();
      expect(values(), ['/srv/abcdefghij北京/notes.txt']);
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
