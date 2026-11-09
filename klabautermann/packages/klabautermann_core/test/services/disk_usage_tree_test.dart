// DSK-07's whole-tree read (03 §7.3): an ncdu or gdu export streams into
// a tree the explorer answers folders from, falling back to `du` folder by
// folder whenever the export cannot answer, and one tree held per server.
import 'dart:async';

import 'package:klabautermann_core/src/services/disk_usage.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show ChannelOpenException, ChannelRefusal, RemoteExit;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _export =
    '[1,2,{"progname":"ncdu"},\n'
    '[{"name":"/srv","dsize":4096},\n'
    '[{"name":"data","dsize":4096},{"name":"db","dsize":8192}],\n'
    '{"name":"notes","dsize":4096}]]\n';

HostProfile _profile(Map<String, String?> tools) => HostProfile(tools: tools);

void main() {
  test('ncdu is preferred, then gdu; neither reads folder by folder', () {
    expect(
      diskUsageExportToolOf(_profile({'ncdu': '/usr/bin/ncdu', 'gdu': '/g'})),
      DiskUsageExportTool.ncdu,
    );
    expect(
      diskUsageExportToolOf(_profile({'ncdu': null, 'gdu': '/usr/bin/gdu'})),
      DiskUsageExportTool.gdu,
    );
    expect(diskUsageExportToolOf(_profile({'ncdu': null})), isNull);
    expect(diskUsageExportToolOf(null), isNull);
  });

  test('streams the export in pieces into the tree', () async {
    final link = ScriptedLink();
    final read = readDiskUsageTree(
      '/srv',
      tool: DiskUsageExportTool.ncdu,
      link: link,
    );
    final process = await link.process(0);
    expect(link.commands.single, endsWith("'ncdu' '-x' '-o' '-' '/srv'"));
    for (var start = 0; start < _export.length; start += 7) {
      process.emitText(
        _export.substring(start, (start + 7).clamp(0, _export.length)),
      );
    }
    process.end();

    final tree = (await read)!;
    final top = tree.listing('/srv')!;
    expect(top.totalBytes, 4096 + 12288 + 4096);
    expect(top.entries.map((entry) => (entry.name, entry.isFolder)), [
      ('data', true),
      ('notes', false),
    ]);
    expect(tree.listing('/srv/data')!.entries.single.name, 'db');
    expect(process.closeCalls, 1);
  });

  test('gdu exports with its own flags', () async {
    final link = ScriptedLink();
    final read = readDiskUsageTree(
      '/srv',
      tool: DiskUsageExportTool.gdu,
      link: link,
    );
    (await link.process(0))
      ..emitText(_export)
      ..end();
    expect(await read, isNotNull);
    expect(link.commands.single, endsWith("'gdu' '-x' '-o-' '/srv'"));
  });

  group('answers null, for du to read instead,', () {
    test('when the tool prints something else', () async {
      final link = ScriptedLink();
      final read = readDiskUsageTree(
        '/srv',
        tool: DiskUsageExportTool.ncdu,
        link: link,
      );
      (await link.process(0))
        ..emitText('sh: ncdu: not found\n')
        ..end(const RemoteExit(exitCode: 127));
      expect(await read, isNull);
    });

    test('when the export ends early', () async {
      final link = ScriptedLink();
      final read = readDiskUsageTree(
        '/srv',
        tool: DiskUsageExportTool.ncdu,
        link: link,
      );
      (await link.process(0))
        ..emitText(_export.substring(0, 40))
        ..end();
      expect(await read, isNull);
    });

    test('when it runs past its time, and closes the channel', () async {
      final link = ScriptedLink();
      final read = readDiskUsageTree(
        '/srv',
        tool: DiskUsageExportTool.ncdu,
        link: link,
        timeout: const Duration(milliseconds: 20),
      );
      final process = await link.process(0);
      process.emitText(_export.substring(0, 40));
      expect(await read, isNull);
      expect(process.closeCalls, 1);
    });

    test('when no channel opens', () async {
      final link = ScriptedLink()
        ..startFailures.add(
          const ChannelOpenException(ChannelRefusal.sessionLimit, 'refused'),
        );
      expect(
        await readDiskUsageTree(
          '/srv',
          tool: DiskUsageExportTool.ncdu,
          link: link,
        ),
        isNull,
      );
    });
  });

  test('the mount point and folders under it read from the tree; Read '
      'again below it reads one folder', () {
    bool fromTree(String path, {String? root = '/srv', bool fresh = false}) =>
        diskUsageFromTree(path: path, root: root, fresh: fresh);
    expect(fromTree('/srv'), isTrue);
    expect(fromTree('/srv/data'), isTrue);
    expect(fromTree('/srv', fresh: true), isTrue);
    expect(fromTree('/srv/data', fresh: true), isFalse);
    expect(fromTree('/srvx'), isFalse, reason: 'not under /srv');
    expect(fromTree('/var'), isFalse);
    expect(fromTree('/srv', root: null), isFalse);
    expect(fromTree('/etc', root: '/'), isTrue);
  });

  group('DiskUsageTrees', () {
    var now = DateTime.utc(2026, 11, 9, 12);
    late DiskUsageTrees trees;
    late int reads;
    DiskUsageTree tree(String root) => (DiskUsageExportReader(
      root,
    )..add('[1,2,{},[{"name":"$root","dsize":1}]]')).close();
    Future<DiskUsageTree?> get(
      String root, {
      String server = 'srv-1',
      bool elevated = false,
      bool fresh = false,
      DiskUsageTree? Function()? answer,
    }) => trees.tree(
      server,
      root,
      elevated: elevated,
      fresh: fresh,
      read: () async {
        reads++;
        return (answer ?? () => tree(root))();
      },
    );

    setUp(() {
      now = DateTime.utc(2026, 11, 9, 12);
      trees = DiskUsageTrees(now: () => now);
      reads = 0;
    });

    test('one read answers the folders under the same mount', () async {
      final first = await get('/srv');
      expect(await get('/srv'), same(first));
      expect(reads, 1);
    });

    test('another mount, root reads, Read again or age read again', () async {
      await get('/srv');
      await get('/var');
      expect(reads, 2);
      await get('/var', elevated: true);
      expect(reads, 3);
      await get('/var', elevated: true, fresh: true);
      expect(reads, 4);
      now = now.add(kDiskUsageTreeLifetime);
      await get('/var', elevated: true);
      expect(reads, 5);
    });

    test(
      'a failed export is not kept; a forgotten server reads again',
      () async {
        expect(await get('/srv', answer: () => null), isNull);
        await Future<void>.delayed(Duration.zero);
        await get('/srv');
        expect(reads, 2);

        trees.forget(['srv-1']);
        await get('/srv');
        expect(reads, 3);
      },
    );
  });
}
