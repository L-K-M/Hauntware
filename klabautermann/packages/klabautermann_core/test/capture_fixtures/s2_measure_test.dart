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

void main() {
  final dash = findOnCapturePath('dash');
  final bash = findOnCapturePath('bash');
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
      final (sampler, error) = await start("printf '%s\\r\\n' \"\$0\"\n");
      expect(error, isNull);
      // `bash\r\n`: sshd passes the login shell's basename as argv[0].
      expect(sampler.bytesBeforeReady, 6);
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

  test('a sampler shell runs under the name sh', () async {
    final sampler = await LocalSampler.start(
      SamplerLaunch.stdinShell(bash!),
      kind: SamplerKind.fast,
      environment: env,
    );
    await sampler.ready;
    final argv0 = File('/proc/${sampler.pid}/cmdline')
        .readAsStringSync()
        .split('\x00')
        .first;
    expect(argv0.split('/').last, 'sh');
    await sampler.close();
  }, skip: bash == null ? 'bash is not installed' : false);

  test('a relative sampler shell path is taken from the cwd', () async {
    // What `--sh` passes on for a path with a slash in it. It starts with
    // the package's test directory, which exists from the cwd (the
    // workspace root or the package) but not beside the temporary `sh`
    // link; past that, `..` stops at the root.
    final anchor = Directory('test').existsSync()
        ? 'test'
        : 'packages/klabautermann_core/test';
    final depth =
        anchor.split('/').length + Directory.current.path.split('/').length;
    final sampler = await LocalSampler.start(
      SamplerLaunch.stdinShell('$anchor/${'../' * depth}${dash!.substring(1)}'),
      kind: SamplerKind.fast,
      environment: env,
    );
    addTearDown(sampler.close);
    await sampler.ready;
  }, skip: dash == null ? 'dash is not installed' : false);

  test('a login shell that cannot start leaves no HOME behind', () async {
    Set<String> homes() => {
      for (final e in Directory.systemTemp.listSync())
        if (e.path.split('/').last.startsWith('klab-s2-home-')) e.path,
    };
    final before = homes();
    await expectLater(
      measurePreReady(['/nonexistent/klab-no-such-shell'], user),
      throwsArgumentError,
    );
    expect(homes().difference(before), isEmpty);
  });

  test('a login shell that exits before READY is recorded', () async {
    // `false` exits at once, often while the program is still being
    // written, which once surfaced as an uncaught error.
    final runs = await measurePreReady([findOnCapturePath('false')!], user);
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
      // kept process adds a row, a `head` header and its cmdline (D48).
      expect(r['bytesPerRow'], inInclusiveRange(40, 4096));
      // Over the rows the host sent, which above the cap can be fewer
      // than the cap.
      expect(r['rows'], allOf(isA<int>(), greaterThan(0)));
      expect(
        r['bytesPerRow'],
        (r['payloadBytes']! as int) / (r['rows']! as int),
      );
      expect(r['capFraction'], lessThan(1));
    }
  }, skip: dash == null ? 'dash is not installed' : false);

  test('slow-tick measurement covers every slow tick collector', () async {
    final runs = await measureSlowTick(dash!, await clockTicksPerSecond(), env);
    final slow = [
      for (final c in Collector.values)
        if (c.sampler == SamplerKind.slow && c.argValidators.isEmpty) c.name,
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

  test('block lines leave out the headers', () {
    final payload = utf8.encode(
      '== meta ==\ntotal=600\n== rows ==\n1 S\n2 S\n3 S\n'
      '== cmdline ==\n==> 1/cmdline <==\n/sbin/init\x1f',
    );
    expect(blockLines(payload), {'meta': 1, 'rows': 3, 'cmdline': 2});
  });

  test('block sizes add up to the payload', () {
    final payload = utf8.encode('== stat ==\ncpu 1 2\n== uptime ==\n9.5 1.0');
    expect(blockSizes(payload), {'stat': 19, 'uptime': 20});
  });

  test('sleepers are started, killed by pid and reaped', () async {
    final sleepers = await Sleepers.spawn(3);
    expect(sleepers.pids, hasLength(3));
    expect(sleepers.pids.every(isSleeper), isTrue);
    await sleepers.kill();
    // The spawner reaps them, so they leave /proc without init's help.
    final listed = sleepers.pids.where(
      (p) => Directory('/proc/$p').existsSync(),
    );
    expect(listed, isEmpty);
  });

  test('a pid that names another process is not a sleeper', () async {
    // What a sleeper's pid can name once the sleeper has ended.
    final other = await Process.start('sleep', ['30']);
    addTearDown(other.kill);
    expect(isSleeper(other.pid), isFalse);
    expect(isSleeper(pid), isFalse);
  });
}
