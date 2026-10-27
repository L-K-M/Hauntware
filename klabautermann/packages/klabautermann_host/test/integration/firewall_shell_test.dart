// NET-06's script through real shells (03 §7.11), with stand-ins first on
// a PATH that holds nothing else: ufw and a stopped firewalld, then nft
// and both iptables-saves, then no tool at all. Each runs as the
// builder's argv with `sh` replaced by the shell under test. Tagged
// `shell`; a shell that is not installed gets no tests.
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

/// The commands the script itself runs, linked in beside the stand-ins.
const _needed = ['head'];

void main() {
  late Directory bin;

  setUp(() async {
    bin = await Directory.systemTemp.createTemp('klab-fw-');
    for (final tool in _needed) {
      for (final dir in ['/usr/bin', '/bin']) {
        if (File('$dir/$tool').existsSync()) {
          await Link('${bin.path}/$tool').create('$dir/$tool');
          break;
        }
      }
    }
  });

  tearDown(() => bin.delete(recursive: true));

  Future<void> standIn(String name, String body) async {
    final file = File('${bin.path}/$name');
    await file.writeAsString('#!/bin/sh\n$body\n');
    await Process.run('chmod', ['+x', file.path]);
  }

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      Future<FirewallRead> run() async {
        final argv = [
          for (final w in HostCommands.firewall()) w == 'sh' ? shell : w,
        ];
        final r = await Process.run(
          argv.first,
          argv.sublist(1),
          environment: {'PATH': bin.path},
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final read = parseFirewall(r.stdout as String);
        expect(read, isNotNull, reason: '${r.stdout}');
        return read!;
      }

      test('ufw and a stopped firewalld', () async {
        await standIn(
          'ufw',
          "printf 'Status: active\\n\\nTo  Action  From\\n--  ------  ----\\n"
              "22/tcp  ALLOW IN  Anywhere\\n'",
        );
        await standIn(
          'firewall-cmd',
          '[ "\$1" = --state ] && { echo "not running"; exit 252; }; exit 1',
        );
        final read = await run();
        expect(read.ufw!.active, isTrue);
        expect(read.ufw!.rules.single.to, '22/tcp');
        expect(read.firewalld!.running, isFalse);
        expect(read.nftables, isNull);
      });

      test('nft and both iptables-saves', () async {
        await standIn(
          'nft',
          "echo '{\"nftables\": [{\"chain\": "
              "{\"family\": \"inet\", \"table\": \"filter\", "
              "\"name\": \"input\", \"hook\": \"input\", "
              "\"policy\": \"accept\"}}]}'",
        );
        await standIn(
          'iptables-save',
          "printf '*filter\\n:INPUT ACCEPT [0:0]\\nCOMMIT\\n'",
        );
        await standIn('ip6tables-save', 'exit 0');
        final read = await run();
        expect(read.nftables!.single.policy, 'accept');
        expect(read.iptables!.single.name, 'INPUT');
        expect(read.ip6tables, isEmpty);
        expect(read.ufw, isNull);
      });

      test('no tool at all', () async {
        expect((await run()).noTool, isTrue);
      });
    });
  }
}
