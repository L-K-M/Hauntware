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
      expect(
        _values(r'me@host:~/src$ cat ./a.txt', home: '/home/me'),
        ['path:/home/me/project/a.txt'],
      );
      expect(_values('root@host:/etc# ls'), isEmpty);
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
      expect(stack.items.first.value, '/f59.txt');
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
      await tester.pump(const Duration(milliseconds: 400));
      terminal.write('/etc/hosts\r\n');
      expect(own.items, isEmpty);
      await tester.pump(const Duration(milliseconds: 400));
      expect([for (final item in own.items) item.value], ['/etc/hosts']);
    });
  });
}
