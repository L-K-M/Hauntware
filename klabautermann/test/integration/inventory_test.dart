// The host write inventory check (inventory.dart; 03 §8.11, M4 plan
// M18): snapshots as inventory.sh prints them, their diff, and the
// allowlist that encodes 8.11's MVP rows, without a host.
import 'dart:io';

import 'package:test/test.dart';

import 'inventory.dart';

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _other =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// A snapshot of [stats] (raw mode, uid, gid, size, path) and [hashes].
String _snapshot(
  List<(String, int, int, int, String)> stats, [
  Map<String, String> hashes = const {},
]) => [
  for (final (mode, uid, gid, size, path) in stats)
    'S\t$mode\t$uid\t$gid\t$size\t$path',
  '--- sha256',
  for (final MapEntry(key: path, value: hash) in hashes.entries) '$hash  $path',
  '',
].join('\n');

void main() {
  group('snapshots', () {
    test('read types, permissions, owners, sizes and small files\' '
        'hashes', () {
      final snapshot = parseSnapshot(
        _snapshot(
          [
            ('41ed', 0, 0, 4096, '/etc'),
            ('81a4', 1000, 1000, 3, '/home/klab/a file'),
            ('a1ff', 0, 0, 1, '/etc/link'),
            ('8de4', 0, 0, 9, '/usr/local/bin/suid'),
          ],
          {'/home/klab/a file': _hash},
        ),
      );
      expect(snapshot['/etc']!.type, EntryType.directory);
      expect(snapshot['/etc']!.mode, 0x1ed);
      final file = snapshot['/home/klab/a file']!;
      expect(
        (file.type, file.uid, file.size, file.sha256),
        (EntryType.file, 1000, 3, _hash),
      );
      expect(snapshot['/etc/link']!.type, EntryType.symlink);
      expect(snapshot['/usr/local/bin/suid']!.mode, 0xde4, reason: 'set-uid');
      expect(snapshot['/usr/local/bin/suid']!.sha256, isNull);
    });

    test('a line inventory.sh would not print fails the read', () {
      expect(
        () => parseSnapshot('S\t41ed\t0\t0\n'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseSnapshot('--- sha256\nnot a hash  /etc\n'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a pass that printed nothing fails the read', () {
      expect(
        () => parseSnapshot('--- sha256\n'),
        throwsA(isA<FormatException>()),
        reason: 'no stat lines',
      );
      expect(
        () => parseSnapshot(_snapshot([('81a4', 0, 0, 3, '/etc/f')])),
        throwsA(isA<FormatException>()),
        reason: 'no hashes',
      );
      expect(
        parseSnapshot(_snapshot([('81a4', 0, 0, 1048577, '/etc/big')])),
        contains('/etc/big'),
        reason: 'only files below 1 MiB are hashed',
      );
    });

    test('inventory.sh prints what the reader reads', () async {
      final root = await Directory.systemTemp.createTemp('inventory-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/f').writeAsString('hi\n');
      await Link('${root.path}/l').create('f');
      final script = File('test/integration/inventory.sh');
      final result = await Process.run('sh', [script.path, root.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');

      final snapshot = parseSnapshot('${result.stdout}');
      expect(snapshot.keys, containsAll([root.path, '${root.path}/f']));
      expect(snapshot['${root.path}/f']!.sha256, hasLength(64));
      expect(snapshot['${root.path}/l']!.type, EntryType.symlink);
    });
  });

  group('the diff', () {
    test('lists additions, removals and changes, by path', () {
      final before = parseSnapshot(
        _snapshot(
          [
            ('41ed', 0, 0, 4096, '/d'),
            ('81a4', 0, 0, 3, '/d/kept'),
            ('81a4', 0, 0, 3, '/d/edited'),
            ('81a4', 0, 0, 3, '/d/chmod'),
            ('81a4', 0, 0, 3, '/d/gone'),
          ],
          {'/d/kept': _hash, '/d/edited': _hash, '/d/chmod': _hash},
        ),
      );
      final after = parseSnapshot(
        _snapshot(
          [
            ('41ed', 0, 0, 8192, '/d'),
            ('81a4', 0, 0, 3, '/d/kept'),
            ('81a4', 0, 0, 3, '/d/edited'),
            ('8180', 0, 0, 3, '/d/chmod'),
            ('81a4', 1000, 1000, 2, '/d/new'),
          ],
          {'/d/kept': _hash, '/d/edited': _other, '/d/chmod': _hash},
        ),
      );
      expect(
        [for (final c in diffSnapshots(before, after)) (c.path, c.kind)],
        [
          ('/d/chmod', ChangeKind.changed),
          ('/d/edited', ChangeKind.changed),
          ('/d/gone', ChangeKind.removed),
          ('/d/new', ChangeKind.added),
        ],
        reason: 'a directory\'s size follows its entries',
      );
    });
  });

  group('the allowlist', () {
    test('a glob\'s * stays in one segment, ** crosses them', () {
      final allowlist = InventoryAllowlist.parse('''
# comment
user   /home/*/.local/state/klabautermann/ops/*.json   # trailing comment
deep   /var/lib/klabautermann/**
''');
      expect(
        allowlist.rowFor('/home/klab/.local/state/klabautermann/ops/1.json'),
        'user',
      );
      expect(
        allowlist.rowFor('/home/a/b/.local/state/klabautermann/ops/1.json'),
        isNull,
      );
      expect(allowlist.rowFor('/var/lib/klabautermann/ops/x/y'), 'deep');
      expect(allowlist.rowFor('/var/lib/klabautermannx'), isNull);
      expect(allowlist.rowFor('/home/klab/.docker/config.json'), isNull);
    });

    test('a line without a row and an absolute glob is refused', () {
      for (final line in ['row', 'row relative/*', 'row /a /b']) {
        expect(
          () => InventoryAllowlist.parse(line),
          throwsA(isA<FormatException>()),
          reason: line,
        );
      }
    });

    test('the committed list covers only 8.11\'s MVP rows', () async {
      final allowlist = InventoryAllowlist.parse(
        await File('test/integration/inventory_allowlist.txt').readAsString(),
      );
      expect(allowlist.rules.map((r) => r.row).toSet(), {
        'detached-user',
        'detached-root',
      });
      for (final path in [
        '/home/klab/.local/state/klabautermann/ops/20261018-1.json',
        '/home/klab/.local/state/klabautermann/ops/20261018-1.log',
        '/var/lib/klabautermann/ops/20261018-2.json',
      ]) {
        expect(allowlist.rowFor(path), isNotNull, reason: path);
      }
      // 8.11's "never written".
      for (final path in [
        '/home/klab/.docker/config.json',
        '/home/klab/.ssh/authorized_keys',
        '/tmp/klabautermann-probe.sh',
        '/usr/local/bin/klabautermann-notify',
        '/etc/sudoers.d/klabautermann-readonly',
      ]) {
        expect(allowlist.rowFor(path), isNull, reason: path);
      }
    });

    test('the report names each change\'s row, and a defect as such', () {
      final allowlist = InventoryAllowlist.parse('user /home/*/x');
      final report = inventoryReport([
        InventoryChange(
          '/home/klab/x',
          ChangeKind.added,
          after: const InventoryEntry(
            type: EntryType.file,
            mode: 0x180,
            uid: 1000,
            gid: 1000,
            size: 2,
          ),
        ),
        InventoryChange(
          '/tmp/y',
          ChangeKind.removed,
          before: const InventoryEntry(
            type: EntryType.directory,
            mode: 0x1ff,
            uid: 0,
            gid: 0,
            size: 4096,
          ),
        ),
      ], allowlist);
      expect(
        report,
        'user\t/home/klab/x\tadded file 0600 1000:1000 2 B\n'
        'NOT ALLOWED\t/tmp/y\tremoved directory 0777 0:0 4096 B\n',
      );
      expect(inventoryReport(const [], allowlist), 'no change\n');
    });
  });
}
