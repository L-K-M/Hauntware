// NET-02 and NET-03's script through real shells (03 §7.11): this host's
// sysfs and /proc/net, with a stand-in `ip` first on PATH that answers
// `-j` as iproute2 does, or refuses it as BusyBox does and answers `-o`.
// Each runs as the builder's argv with `sh` replaced by the shell under
// test. Tagged `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

const _iproute2 = r'''#!/bin/sh
[ "$1" = -j ] || exit 1
echo '[{"ifindex":1,"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8,"scope":"host"}]}]'
''';

const _busybox = r'''#!/bin/sh
[ "$1" = -o ] || { echo "ip: invalid option -- 'j'" >&2; exit 1; }
echo '1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever'
''';

void main() {
  late Directory bin;

  setUp(() async {
    bin = await Directory.systemTemp.createTemp('klab-net-');
  });

  tearDown(() => bin.delete(recursive: true));

  Future<void> standIn(String script) async {
    final ip = File('${bin.path}/ip');
    await ip.writeAsString(script);
    await Process.run('chmod', ['+x', ip.path]);
  }

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      Future<InterfacesRead> run() async {
        final argv = [
          for (final w in HostCommands.interfaces()) w == 'sh' ? shell : w,
        ];
        final r = await Process.run(
          argv.first,
          argv.sublist(1),
          environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final read = parseInterfaces(r.stdout as String);
        expect(read, isNotNull, reason: '${r.stdout}');
        return read!;
      }

      test('this host\'s interfaces and sockets, with iproute2', () async {
        await standIn(_iproute2);
        final read = await run();
        final names = Directory('/sys/class/net')
            .listSync()
            .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
            .toSet();
        expect(read.interfaces.map((i) => i.name).toSet(), names);
        final lo = read.interfaces.singleWhere((i) => i.name == 'lo');
        expect(lo.mtu, isNotNull);
        expect(lo.rxBytes, isNotNull);
        expect(read.addressesRead, isTrue);
        expect(lo.addresses.single.address, '127.0.0.1');
        expect(read.sockets.used, isNotNull);
      });

      test('BusyBox ip answers line by line', () async {
        await standIn(_busybox);
        final read = await run();
        final lo = read.interfaces.singleWhere((i) => i.name == 'lo');
        expect(read.addressesRead, isTrue);
        expect(lo.addresses.single.scope, 'host');
      });
    });
  }
}
