// The capture tool's S2 measurements against the real program in dash
// and bash (03 §6.2). Tagged `shell`; a shell that is not installed is
// skipped.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

import '../../tool/src/local_sampler.dart';
import '../../tool/src/s2_measure.dart';

String? _which(String name) => [
  for (final dir in kCapturePath.split(':')) '$dir/$name',
].where((p) => File(p).existsSync()).firstOrNull;

void main() {
  final dash = _which('dash');
  final bash = _which('bash');
  final user = Platform.environment['USER'] ?? 'nobody';
  final env = runEnvironment(home: Directory.systemTemp.path, user: user);

  group('bash as the login shell', () {
    Future<(LocalSampler, Object?)> start(String bashrc) async {
      final home = Directory.systemTemp.createTempSync('klab-home-');
      addTearDown(() => home.deleteSync(recursive: true));
      File('${home.path}/.bashrc').writeAsStringSync(bashrc);
      final sampler = await LocalSampler.start(
        SamplerLaunch.loginShell(bash!),
        kind: SamplerKind.fast,
        environment: runEnvironment(
          home: home.path,
          user: user,
          shell: bash,
          ssh: true,
        ),
      );
      try {
        await sampler.ready;
        return (sampler, null);
      } on SamplerFailure catch (e) {
        return (sampler, e);
      }
    }

    test('.bashrc output before READY is counted and skipped', () async {
      final (sampler, error) = await start("printf 'hello\\r\\n'\n");
      expect(error, isNull);
      expect(sampler.bytesBeforeReady, 7);
      final reply = await sampler.request(1, [Collector.overview]);
      expect(reply.tick!.section('overview')!.status, SectionStatus.ok);
      expect(
        reply.bytes,
        greaterThan(reply.tick!.sections.single.payload.length),
      );
      await sampler.close();
    });

    test('more than 64 KiB before READY fails the start', () async {
      final (sampler, error) = await start(
        "head -c ${kMaxPreambleBytes + 1} /dev/zero | tr '\\000' x\n",
      );
      expect(
        error,
        isA<SamplerFailure>().having(
          (e) => e.fault,
          'fault',
          HwsSessionFault.noReady,
        ),
      );
      await sampler.close();
      expect(sampler.bytesBeforeReady, kMaxPreambleBytes + 1);
    });
  }, skip: bash == null ? 'bash is not installed' : false);

  test('a login shell that exits before READY is recorded', () async {
    // `false` exits at once, often while the program is still being
    // written, which once surfaced as an uncaught error.
    final runs = await measurePreReady([_which('false')!], user);
    expect(runs.map((r) => r['outcome']).toSet(), {'exited'});
  });

  test('fast-tick measurement reports bytes, blocks and CPU', () async {
    // Enough ticks for the shell's own CPU to pass one clock tick (about
    // 1.5 ms each against 10 ms ticks at CLK_TCK 100).
    final m = await measureFastTick(
      dash!,
      Collector.core,
      200,
      await clockTicksPerSecond(),
      env,
    );
    final blocks = m['payloadBlocks']! as Map<String, int>;
    expect(blocks.keys, containsAll(['stat', 'meminfo', 'loadavg', 'uptime']));
    expect(
      (m['replyBytes']! as Map<String, num>)['min'],
      greaterThan(m['payloadBytes']! as int),
    );
    expect(m['cpuMsPerTick'], greaterThan(0));
    // The fast path forks nothing (03 §6.2).
    expect(m['childCpuMs'], 0);
  }, skip: dash == null ? 'dash is not installed' : false);

  test('procs measurement reads the declared section size', () async {
    final runs = await measureProcs(
      [dash!],
      [2],
      await clockTicksPerSecond(),
      env,
    );
    expect(runs.map((r) => r['extraProcesses']), [0, 2]);
    for (final r in runs) {
      expect(r['outcome'], 'ok');
      // The `S` marker's size, not a seq or another small number: each
      // process adds a stat line, five status lines and its cmdline.
      expect(r['bytesPerProcess'], inInclusiveRange(100, 4096));
      expect(r['capFraction'], lessThan(1));
    }
  }, skip: dash == null ? 'dash is not installed' : false);

  test('slow-tick measurement covers every slow collector', () async {
    final runs = await measureSlowTick(dash!, await clockTicksPerSecond(), env);
    final slow = [
      for (final c in Collector.values)
        if (c.sampler == SamplerKind.slow) c.name,
    ];
    expect(runs.map((r) => (r['collectors']! as List).join(',')), [
      ...slow,
      slow.where((c) => c != Collector.probe.name).join(','),
    ]);
    for (final r in runs) {
      expect((r['statuses']! as Map).keys, isNotEmpty);
      expect((r['wallMs']! as Map<String, num>)['min'], greaterThan(0));
    }
  }, skip: dash == null ? 'dash is not installed' : false);

  test('block sizes add up to the payload', () {
    final payload = utf8.encode('== stat ==\ncpu 1 2\n== uptime ==\n9.5 1.0');
    expect(blockSizes(payload), {'stat': 19, 'uptime': 20});
  });

  test('sleepers are started and killed by pid', () async {
    final pids = await spawnSleepers(3);
    expect(pids, hasLength(3));
    expect(pids.every(_alive), isTrue);
    await killSleepers(pids);
    // Killed sleepers leave /proc, or stay as zombies until init reaps
    // them.
    expect(pids.where(_alive), isEmpty);
  });
}

/// Whether [pid] exists and is not a zombie (state `Z`, the field after
/// the comm's closing parenthesis).
bool _alive(int pid) {
  try {
    final text = File('/proc/$pid/stat').readAsStringSync();
    return text[text.lastIndexOf(')') + 2] != 'Z';
  } on FileSystemException {
    return false;
  }
}
