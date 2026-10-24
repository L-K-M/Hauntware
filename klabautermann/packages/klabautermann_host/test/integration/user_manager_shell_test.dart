// The slow program's user manager collectors through a real shell (03
// §7.5, SVC-09): `user_units` and `user_timers` ask `systemctl --user`,
// setting systemd's own XDG_RUNTIME_DIR where the session has none, in
// the system collectors' block shapes, and a missing user bus reads as
// an error. A stand-in `systemctl` on PATH records what it was asked.
// Tagged `shell`; a shell that is not installed gets no tests.
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

/// A `systemctl` stand-in on systemd 255 that logs each call's runtime
/// directory and arguments to [log], then answers [answer] with exit
/// [status].
String _systemctl(String log, {required String answer, int status = 0}) =>
    '''
if [ "\$1" = --version ]; then echo 'systemd 255 (255.4)'; exit 0; fi
printf '%s|%s\\n' "\${XDG_RUNTIME_DIR:-}" "\$*" >>'$log'
printf '%s\\n' '$answer'
exit $status
''';

/// One tick of [collectors] under [shell], with [env] over a PATH that
/// holds the stand-in first.
Future<HwsTick> _tick(
  String shell,
  List<Collector> collectors, {
  required String script,
  Map<String, String> env = const {},
}) async {
  final bin = await Directory.systemTemp.createTemp('klab-user-');
  addTearDown(() => bin.delete(recursive: true));
  final file = File('${bin.path}/systemctl');
  await file.writeAsString('#!/bin/sh\n$script\n');
  await Process.run('chmod', ['0755', file.path]);

  final nonce = generateNonce(Random(1));
  final proc = await Process.start('env', [
    '-u',
    'XDG_RUNTIME_DIR',
    'PATH=${bin.path}:${Platform.environment['PATH']}',
    'LC_ALL=C',
    for (final MapEntry(:key, :value) in env.entries) '$key=$value',
    shell,
    '-s',
  ]);
  final out = <int>[];
  final outDone = proc.stdout.forEach(out.addAll);
  final err = proc.stderr.transform(utf8.decoder).join();
  proc.stdin
    ..write(buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce))
    ..write(encodeTickRequest(1, collectors));
  await proc.stdin.close();
  await outDone;
  expect(await proc.exitCode, 0, reason: await err);

  for (final event in HwsTickAssembler(nonce: nonce).push(out)) {
    if (event is HwsTick) return event;
  }
  fail('no tick in ${utf8.decode(out, allowMalformed: true)}');
}

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test("$name: user_units and user_timers ask the user's manager, with "
        "systemd's own runtime directory", () async {
      final dir = await Directory.systemTemp.createTemp('klab-user-log-');
      addTearDown(() => dir.delete(recursive: true));
      final log = '${dir.path}/calls';

      final tick = await _tick(shell, [
        Collector.userUnits,
        Collector.userTimers,
      ], script: _systemctl(log, answer: '[]'));

      final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
      final calls = File(log).readAsLinesSync();
      expect(calls, [
        '/run/user/$uid|--user list-units --all --output=json',
        '/run/user/$uid|--user --failed --output=json',
        '/run/user/$uid|--user list-timers --all --output=json',
      ]);
      final units = tick.section(Collector.userUnits.wireName)!;
      expect(units.status, SectionStatus.ok);
      final parsed = parseUnits(
        utf8.decode(units.payload),
        ParseContext.standard,
      );
      expect(parsed.value.format, UnitListFormat.json);
      final timers = tick.section(Collector.userTimers.wireName)!;
      expect(
        parseTimers(
          utf8.decode(timers.payload),
          ParseContext.standard,
        ).value.format,
        TimerListFormat.json,
      );
    });

    test("$name: a session's own runtime directory is kept", () async {
      final dir = await Directory.systemTemp.createTemp('klab-user-log-');
      addTearDown(() => dir.delete(recursive: true));
      final log = '${dir.path}/calls';

      await _tick(
        shell,
        [Collector.userTimers],
        script: _systemctl(log, answer: '[]'),
        env: {'XDG_RUNTIME_DIR': '/run/user/4242'},
      );

      expect(File(log).readAsLinesSync().single, startsWith('/run/user/4242|'));
    });

    test('$name: a missing user bus reads as an error', () async {
      final dir = await Directory.systemTemp.createTemp('klab-user-log-');
      addTearDown(() => dir.delete(recursive: true));

      final tick = await _tick(
        shell,
        [Collector.userUnits],
        script: _systemctl(
          '${dir.path}/calls',
          answer: 'Failed to connect to bus: No medium found',
          status: 1,
        ),
      );

      expect(
        tick.section(Collector.userUnits.wireName)!.status,
        SectionStatus.error,
      );
    });
  }
}
