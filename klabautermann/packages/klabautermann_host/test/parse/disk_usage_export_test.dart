// DSK-07's whole-tree read (03 §7.3): ncdu's and gdu's exports read as
// they stream into the listings `du` would have given, whatever the chunks.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// `ncdu 1.19 -x -o - /srv` over a hard link, a symlink, a quoted name and
/// a nested folder, as recorded (timestamps and the device trimmed).
const _ncdu = '''
[1,2,{"progname":"ncdu","progver":"1.19","timestamp":1794229955},
[{"name":"/srv","asize":4096,"dsize":4096,"dev":65024},
[{"name":"c","asize":4096,"dsize":4096},
{"name":"hardlink","asize":300000,"dsize":303104,"ino":3301399,"hlnkc":true,"nlink":2},
{"name":"link","asize":4,"notreg":true},
{"name":"we\\"ird name","asize":3,"dsize":4096}],
[{"name":"a","asize":4096,"dsize":4096},
[{"name":"b","asize":4096,"dsize":4096},
{"name":"small","asize":5000,"dsize":8192}],
{"name":"big","asize":300000,"dsize":303104,"ino":3301399,"hlnkc":true,"nlink":2}]]]
''';

/// `gdu 5.25 -x -o- /srv` of the same tree: folders carry no size of
/// their own.
const _gdu = '''
[1,2,{"progname":"gdu","progver":"5.25.0","timestamp":1794229955},
[{"name":"/srv","mtime":1794229955},
[{"name":"a","mtime":1794229955},
{"name":"big","asize":300000,"dsize":303104,"mtime":1794229955},
[{"name":"b","mtime":1794229955},
{"name":"small","asize":5000,"dsize":8192,"mtime":1794229955}]],
[{"name":"c","mtime":1794229955},
{"name":"hardlink","asize":300000,"dsize":303104,"mtime":1794229955,"ino":3301399,"hlnkc":true},
{"name":"link","asize":4,"mtime":1794229955,"notreg":true},
{"name":"we\\"ird name","asize":3,"dsize":4096,"mtime":1794229955}]]]
''';

DiskUsageTree _read(String text, {int chunk = 1 << 20, int keep = 1000}) {
  final reader = DiskUsageExportReader('/srv', keep: keep);
  for (var start = 0; start < text.length; start += chunk) {
    reader.add(text.substring(start, (start + chunk).clamp(0, text.length)));
  }
  return reader.close();
}

List<(String, int, bool)> _entries(DiskUsageListing listing) => [
  for (final entry in listing.entries)
    (entry.name, entry.bytes, entry.isFolder),
];

void main() {
  test('ncdu: folders list their largest first and count a hard link '
      'once, as du does', () {
    final tree = _read(_ncdu);

    final top = tree.listing('/srv')!;
    // c: its own 4 KiB, the hard link's first name (303104), the quoted
    // file; a: its own 4 KiB, b (12 KiB), and the link's second name,
    // counted already.
    expect(_entries(top), [
      ('c', 4096 + 303104 + 4096, true),
      ('a', 4096 + 12288, true),
    ]);
    expect(top.totalBytes, 4096 + 311296 + 16384);
    expect(top.incomplete, isFalse);
    expect(top.truncated, isFalse);

    expect(_entries(tree.listing('/srv/c')!), [
      ('hardlink', 303104, false),
      ('we"ird name', 4096, false),
      ('link', 0, false),
    ]);
    expect(_entries(tree.listing('/srv/a/b')!), [('small', 8192, false)]);
    expect(tree.listing('/srv/a/big'), isNull, reason: 'a file');
    expect(tree.listing('/srv/missing'), isNull);
    expect(tree.listing('/other'), isNull);
  });

  test('gdu: the same tree without folders\' own sizes', () {
    final tree = _read(_gdu);
    expect(_entries(tree.listing('/srv')!), [
      ('a', 303104 + 8192, true),
      // gdu marks only the second name a hard link, so both count here.
      ('c', 303104 + 4096, true),
    ]);
    expect(_entries(tree.listing('/srv/a')!), [
      ('big', 303104, false),
      ('b', 8192, true),
    ]);
  });

  test('any chunking reads the same tree', () {
    final whole = _read(_ncdu);
    for (final chunk in [1, 2, 3, 7, 64]) {
      final tree = _read(_ncdu, chunk: chunk);
      for (final path in ['/srv', '/srv/a', '/srv/a/b', '/srv/c']) {
        expect(
          _entries(tree.listing(path)!),
          _entries(whole.listing(path)!),
          reason: '$path in chunks of $chunk',
        );
      }
    }
  });

  test('a folder keeps its largest entries and says it was cut', () {
    final files = [
      for (var index = 1; index <= 9; index++)
        '{"name":"f$index","dsize":${index * 1024}}',
    ].join(',\n');
    final tree = _read(
      '[1,2,{"progname":"ncdu"},\n[{"name":"/srv","dsize":0},\n$files]]',
      keep: 3,
    );
    final listing = tree.listing('/srv')!;
    expect(listing.entries.map((entry) => entry.name), ['f9', 'f8', 'f7']);
    expect(listing.totalBytes, 45 * 1024, reason: 'all nine count');
    expect(listing.truncated, isTrue);
  });

  test('a read error marks the folder and those above it incomplete; '
      'another filesystem is left out', () {
    const text = '''
[1,2,{"progname":"ncdu"},
[{"name":"/srv","dsize":4096},
[{"name":"a","dsize":4096},
[{"name":"locked","dsize":4096,"read_error":true}]],
{"name":"proc","excluded":"otherfs"},
{"name":"ok","dsize":1024}]]
''';
    final tree = _read(text);
    expect(tree.listing('/srv')!.incomplete, isTrue);
    expect(tree.listing('/srv/a')!.incomplete, isTrue);
    expect(tree.listing('/srv/a/locked')!.incomplete, isTrue);
    expect(tree.listing('/srv')!.entries.map((entry) => entry.name), [
      'a',
      'ok',
    ]);
  });

  test('the root folder\'s listing works for /', () {
    final reader = DiskUsageExportReader('/')
      ..add('[1,2,{},[{"name":"/","dsize":0},[{"name":"etc","dsize":8}]]]');
    final tree = reader.close();
    expect(_entries(tree.listing('/')!), [('etc', 8, true)]);
    expect(tree.listing('/etc')!.entries, isEmpty);
  });

  group('refuses', () {
    void refuses(String text, {int maxEntries = 1 << 20}) {
      final reader = DiskUsageExportReader('/srv', maxEntries: maxEntries);
      expect(
        () => reader
          ..add(text)
          ..close(),
        throwsA(isA<DiskUsageExportException>()),
        reason: text,
      );
    }

    test('an export cut short, as on a timeout', () {
      refuses(_ncdu.substring(0, _ncdu.length ~/ 2));
    });

    test('text that is not an export', () {
      refuses('ncdu: command not found');
      refuses('[1,2,{"progname":"ncdu"},{"name":"stray"}]');
      refuses('[1,2,{"progname":"ncdu"},[{"name":"/srv"},{"nope":1}]]');
      refuses('[1,2,{"progname":"ncdu"},[{"name":"/srv"}]]x');
    });

    test('more entries than the bound', () {
      refuses(_ncdu, maxEntries: 3);
    });
  });
}
