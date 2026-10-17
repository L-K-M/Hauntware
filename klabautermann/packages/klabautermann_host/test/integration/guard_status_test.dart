// The slow program's `timeout` guard through a real shell (03 §6.2,
// §6.3): a guarded command the guard stops reports `timeout`, whichever
// `timeout` the host has. GNU's exits 124; BusyBox's exits with the
// stopped command's own status, 143 after its SIGTERM, as the Alpine
// fixture showed (03 §11.3). Each stand-in on PATH stops the command at
// once instead of after 10 s. Without a guard the same 143 stays an
// error. Tagged `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

/// `timeout` stand-ins: each starts the command and stops it with
/// SIGTERM, then exits as that implementation does.
const _timeouts = {
  'GNU': 'shift; "\$@" & kill -TERM \$!; wait \$!; exit 124',
  'BusyBox': 'shift; "\$@" & kill -TERM \$!; wait \$!',
};

/// A directory of scripts for PATH, removed after the test.
Future<Directory> _bin(Map<String, String> scripts) async {
  final bin = await Directory.systemTemp.createTemp('klab-guard-');
  addTearDown(() => bin.delete(recursive: true));
  for (final MapEntry(key: tool, value: script) in scripts.entries) {
    final file = File('${bin.path}/$tool');
    await file.writeAsString('#!/bin/sh\n$script\n');
    await Process.run('chmod', ['0755', file.path]);
  }
  return bin;
}

/// The `fs` section's status from one tick under [shell] with [path].
Future<SectionStatus> _fsStatus(String shell, String path) async {
  final nonce = generateNonce(Random(1));
  final proc = await Process.start('env', [
    'PATH=$path',
    'LC_ALL=C',
    shell,
    '-s',
  ]);
  final out = <int>[];
  final outDone = proc.stdout.forEach(out.addAll);
  final err = proc.stderr.transform(utf8.decoder).join();
  proc.stdin
    ..write(buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce))
    ..write(encodeTickRequest(1, [Collector.fs]));
  await proc.stdin.close();
  await outDone;
  expect(await proc.exitCode, 0, reason: await err);

  for (final event in HwsTickAssembler(nonce: nonce).push(out)) {
    if (event is HwsTick) return event.section(Collector.fs.wireName)!.status;
  }
  fail('no tick in ${utf8.decode(out, allowMalformed: true)}');
}

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    for (final MapEntry(key: kind, value: body) in _timeouts.entries) {
      test('$name: a df that $kind timeout stops reports timeout', () async {
        final bin = await _bin({'timeout': body, 'df': 'exec sleep 30'});
        final path = '${bin.path}:${Platform.environment['PATH']}';

        expect(await _fsStatus(shell, path), SectionStatus.timeout);
      });
    }

    // Without `timeout`, nothing guards df, so its 143 is an error even
    // though it matches BusyBox's stop status. PATH holds df alone.
    test('$name: an unguarded df that SIGTERM ends reports error', () async {
      final bin = await _bin({'df': r'kill -TERM $$'});

      expect(await _fsStatus(shell, bin.path), SectionStatus.error);
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
