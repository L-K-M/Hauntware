/// Spike S2 measurements on this machine (04 §13 S2; 03 §6.2, §11.4):
/// output before READY under login-shell startup files, fast-tick bytes
/// and CPU, the `procs` section beyond 1,000 processes against the 1 MiB
/// section cap, and slow-tick wall time.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';

import 'local_sampler.dart';

/// Every measurement as the evidence JSON. [samplerShells] (names or
/// paths) run the program as `/bin/sh` would ([SamplerLaunch.stdinShell])
/// for the fast-tick, procs and slow-tick measurements; [loginShells]
/// start it as sshd runs a command ([SamplerLaunch.loginShell]) for the
/// output before READY, and that start line execs this machine's `sh`.
Future<Map<String, Object?>> measureAll({
  required List<String> samplerShells,
  required List<String> loginShells,
  required String user,
  int ticks = 500,
  List<int> extraProcesses = const [1000, 2000, 3000],
}) async {
  final paths = [for (final s in samplerShells) _resolveShell(s)];
  final logins = [for (final s in loginShells) _resolveShell(s)];
  final clockTicks = await clockTicksPerSecond();
  final env = runEnvironment(home: Directory.systemTemp.path, user: user);
  String loadavg() => File('/proc/loadavg').readAsStringSync().trim();
  String field(String file, String key) => File(file)
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith(key), orElse: () => key)
      .substring(key.length)
      .replaceAll(RegExp(r'^[\s:="]+|"$'), '');
  final loadStart = loadavg();
  final uname = await Process.run('uname', ['-s', '-r', '-m']);
  final result = <String, Object?>{
    'schemaVersion': 1,
    'tool': 'klabautermann_core/tool/capture_fixtures.dart measure',
    'capturedAt': DateTime.now().toUtc().toIso8601String(),
    'collectorSetVersion': kCollectorSetVersion,
    'host': {
      'os': field('/etc/os-release', 'PRETTY_NAME'),
      'kernel': uname.stdout.toString().trim(),
      'cpuModel': field('/proc/cpuinfo', 'model name'),
      'cpus': Platform.numberOfProcessors,
      // sd_booted(3): systemd is running when this directory exists.
      'systemdRunning': Directory('/run/systemd/system').existsSync(),
      'clockTicksPerSecond': clockTicks,
      // What a login shell's start line execs.
      'sh': File(_resolveShell('sh')).resolveSymbolicLinksSync(),
    },
    'shells': {
      for (final p in {...paths, ...logins})
        p: (await Process.run(p, [
          '-c',
          r'printf %s "${BASH_VERSION:-not bash}"',
        ])).stdout.toString(),
    },
    'preReady': await measurePreReady(logins, user),
    'fastTick': [
      for (final p in paths)
        for (final c in [Collector.overview, Collector.core])
          await measureFastTick(p, c, ticks, clockTicks, env),
    ],
    'procs': await measureProcs(paths, extraProcesses, clockTicks, env),
    'slowTick': [
      for (final p in paths) ...await measureSlowTick(p, clockTicks, env),
    ],
  };
  result['loadavg'] = {'start': loadStart, 'end': loadavg()};
  return result;
}

/// The startup files each pre-READY scenario writes into a fresh HOME,
/// and whether the run gets the SSH variables.
Map<String, ({Map<String, String> files, bool ssh})> preReadyScenarios() {
  String bulk(int bytes) =>
      "cat <<'EOF'\n${'${'x' * 63}\n' * (bytes ~/ 64)}EOF\n";
  const banner = "printf 'banner from %s\\r\\n' \"\$0\"\n";
  return {
    'empty HOME': (files: const {}, ssh: true),
    'this host\'s /etc/skel files': (
      files: {
        for (final name in ['.bashrc', '.profile'])
          if (File('/etc/skel/$name') case final f when f.existsSync())
            name: f.readAsStringSync(),
      },
      ssh: true,
    ),
    '.bashrc prints a banner': (files: const {'.bashrc': banner}, ssh: true),
    '.bashrc prints a banner, no SSH variables': (
      files: const {'.bashrc': banner},
      ssh: false,
    ),
    '.profile, .bash_profile and .bash_login print banners': (
      files: const {
        '.profile': banner,
        '.bash_profile': banner,
        '.bash_login': banner,
      },
      ssh: true,
    ),
    '.bashrc prints 60 KiB': (files: {'.bashrc': bulk(60 << 10)}, ssh: true),
    '.bashrc prints 70 KiB': (files: {'.bashrc': bulk(70 << 10)}, ssh: true),
  };
}

/// Each scenario under each login shell: the output before READY and
/// whether the session then answers an `overview` tick.
Future<List<Map<String, Object?>>> measurePreReady(
  List<String> loginShells,
  String user,
) async {
  final out = <Map<String, Object?>>[];
  for (final shell in loginShells) {
    for (final MapEntry(key: name, value: s) in preReadyScenarios().entries) {
      final home = Directory.systemTemp.createTempSync('klab-s2-home-');
      LocalSampler? sampler;
      var outcome = 'ready';
      bool? tickOk;
      try {
        s.files.forEach((f, text) {
          File('${home.path}/$f').writeAsStringSync(text);
        });
        // Inside the try, so that a start that throws (a login shell that
        // is not the first of its name on kCapturePath) removes the HOME.
        final started = sampler = await LocalSampler.start(
          SamplerLaunch.loginShell(shell),
          kind: SamplerKind.fast,
          environment: runEnvironment(
            home: home.path,
            user: user,
            shell: shell,
            ssh: s.ssh,
          ),
        );
        await started.ready.timeout(const Duration(seconds: 20));
        final reply = await started.request(1, [Collector.overview]);
        tickOk = reply.tick?.section('overview')?.status == SectionStatus.ok;
      } on SamplerFailure catch (e) {
        outcome = e.fault?.name ?? 'exited';
      } on TimeoutException {
        // A startup file that blocks: no READY and no exit. Recorded as a
        // row like the other non-READY outcomes, not an aborted run.
        outcome = 'timeout';
      } finally {
        await sampler?.close();
        home.deleteSync(recursive: true);
      }
      out.add({
        'loginShell': shell,
        'scenario': name,
        'sshVariables': s.ssh,
        'bytesBeforeReady': sampler!.bytesBeforeReady,
        'outcome': outcome,
        'overviewTickOk': tickOk,
      });
    }
  }
  return out;
}

/// [ticks] back-to-back ticks of [collector] after five warm-up ticks:
/// reply bytes, the payload's block sizes and the shell's CPU per tick.
/// The fast path forks nothing (03 §6.2), so `childCpuMs` stays 0 while
/// that holds.
Future<Map<String, Object?>> measureFastTick(
  String shell,
  Collector collector,
  int ticks,
  int clockTicks,
  Map<String, String> env,
) => _withSampler(shell, SamplerKind.fast, env, (s) async {
  var seq = 0;
  for (var i = 0; i < 5; i++) {
    await s.request(++seq, [collector]);
  }
  final cpu0 = readProcessCpu(s.pid);
  final bytes = <num>[];
  final walls = <num>[];
  late HwsSection section;
  for (var i = 0; i < ticks; i++) {
    final r = await s.request(++seq, [collector]);
    final tick = r.tick ?? (throw StateError('tick lost: ${r.lostDetail}'));
    section = tick.section(collector.name)!;
    bytes.add(r.bytes);
    walls.add(r.wall.inMicroseconds / 1000);
  }
  final cpu1 = readProcessCpu(s.pid);
  double ms(int t) => t * 1000 / clockTicks;
  return {
    'shell': shell,
    'collector': collector.name,
    'ticks': ticks,
    'replyBytes': _stats(bytes),
    'payloadBytes': section.payload.length,
    'payloadBlocks': blockSizes(section.payload),
    'cpuMsPerTick': ms(cpu1.self - cpu0.self) / ticks,
    'childCpuMs': ms(cpu1.children - cpu0.children),
    'wallMsPerTick': _stats(walls),
  };
});

/// Bytes per `== name ==` block of a payload, header lines and newlines
/// included, so the values add up to the payload size.
Map<String, int> blockSizes(List<int> payload) {
  final sizes = <String, int>{};
  var current = '';
  for (final line in latin1.decode(payload).split('\n')) {
    current = blockHeaderPattern.firstMatch(line)?[1] ?? current;
    sizes[current] = (sizes[current] ?? 0) + line.length + 1;
  }
  sizes[current] = sizes[current]! - 1;
  return sizes;
}

/// Lines per `== name ==` block of a payload, header lines left out.
Map<String, int> blockLines(List<int> payload) {
  final lines = <String, int>{};
  String? current;
  for (final line in latin1.decode(payload).split('\n')) {
    if (blockHeaderPattern.firstMatch(line)?[1] case final name?) {
      current = name;
      lines[name] ??= 0;
    } else if (current != null) {
      lines[current] = lines[current]! + 1;
    }
  }
  return lines;
}

/// The `procs` collector with [extraProcesses] more sleeping processes
/// than the machine runs, up to three requests per shell and count (one
/// when it takes over 10 s). The payload size is the `S` marker's
/// declared byte count, which the reply carries even when the frame
/// parser rejects it for exceeding [kMaxSectionBytes]. `rows` counts
/// the lines of the payload's `rows` block, the rows the host sent: every
/// process up to [kProcsRowCap], and above that from half the cap to the
/// cap (D48). `bytesPerRow` divides the size by it;
/// both are null when the reply was lost, which keeps no payload. Before
/// collector-set version 5 the host sent every process, and the S2
/// evidence records the size over the process count as
/// `bytesPerProcess`.
Future<List<Map<String, Object?>>> measureProcs(
  List<String> shells,
  List<int> extraProcesses,
  int clockTicks,
  Map<String, String> env,
) async {
  final out = <Map<String, Object?>>[];
  for (final extra in [0, ...extraProcesses]) {
    final sleepers = await Sleepers.spawn(extra);
    try {
      for (final shell in shells) {
        out.add(
          await _withSampler(shell, SamplerKind.slow, env, (s) async {
            final walls = <num>[];
            final cpus = <num>[];
            var processes = 0;
            late SamplerReply reply;
            for (var i = 1; i <= 3 && (i == 1 || walls.last < 10000); i++) {
              processes = Directory('/proc')
                  .listSync()
                  .where((e) => int.tryParse(e.path.substring(6)) != null)
                  .length;
              final (r, cpu) = await _timed(s, i, [
                Collector.procs,
              ], clockTicks);
              reply = r;
              walls.add(r.wall.inMicroseconds / 1000);
              cpus.add(cpu);
            }
            final bytes = int.parse(
              RegExp(
                r'\x1e[0-9a-f]{32} S procs [a-z]+ (\d+)\n',
              ).firstMatch(latin1.decode(reply.head))![1]!,
            );
            final payload = reply.tick
                ?.section(Collector.procs.wireName)
                ?.payload;
            final rows = payload == null ? null : blockLines(payload)['rows'];
            return {
              'shell': shell,
              'extraProcesses': extra,
              'processes': processes,
              'payloadBytes': bytes,
              'rows': rows,
              'bytesPerRow': rows == null || rows == 0 ? null : bytes / rows,
              'capFraction': bytes / kMaxSectionBytes,
              'outcome': reply.tick == null
                  ? 'lost: ${reply.lostDetail}'
                  : 'ok',
              'wallMs': _stats(walls),
              'cpuMs': _stats(cpus),
            };
          }),
        );
      }
    } finally {
      await sleepers.kill();
    }
  }
  return out;
}

/// How long a sleeper lives unless killed: far past one round of
/// [measureProcs] (the 3,000-process round took about 3 minutes), so the
/// process count holds for the whole round.
const _sleeperSeconds = 3600;

/// How long [Sleepers.spawn] waits for its children to exec sleep.
const _sleeperStartWait = Duration(seconds: 10);

/// Whether [pid] is still a sleeper. Once a sleeper has ended and been
/// reaped, the kernel can give its pid to an unrelated process.
bool isSleeper(int pid) {
  try {
    return File('/proc/$pid/cmdline').readAsStringSync() ==
        'sleep\x00$_sleeperSeconds\x00';
  } on FileSystemException {
    return false;
  }
}

/// Sleeping processes that pad the process list for [measureProcs]. They
/// are children of one spawner shell that waits for them, so a killed
/// sleeper is reaped and leaves `/proc` whether or not this machine's
/// init reaps orphans.
final class Sleepers {
  Sleepers._(this._spawner, this.pids);

  final Process? _spawner;
  final List<int> pids;

  /// Starts [n] sleepers.
  static Future<Sleepers> spawn(int n) async {
    if (n == 0) return Sleepers._(null, const []);
    final p = await Process.start('sh', [
      '-c',
      // The spawner closes its stdout once every pid is out, which ends
      // the stream below, and then waits for the sleepers.
      'i=0; while [ "\$i" -lt "\$1" ]; do '
          'sleep $_sleeperSeconds </dev/null >/dev/null 2>&1 & '
          r'echo "$!"; i=$((i + 1)); done; exec >&-; wait',
      'spawn',
      '$n',
    ]);
    p.stderr.drain<void>().ignore();
    final pids = await p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(int.parse)
        .toList();
    final sleepers = Sleepers._(p, pids);
    if (pids.length != n) {
      await sleepers.kill();
      throw StateError('started ${pids.length} of $n sleepers');
    }
    // `$!` names a child as soon as it forks, before it execs sleep, and
    // kill() signals only pids that are sleepers by then; a child caught
    // early would never be signalled and the spawner would wait for it.
    final started = Stopwatch()..start();
    while (!pids.every(isSleeper)) {
      if (started.elapsed > _sleeperStartWait) {
        pids.forEach(Process.killPid);
        await sleepers.kill();
        throw StateError('sleepers did not exec within $_sleeperStartWait');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sleepers;
  }

  /// Signals each pid that is still a sleeper and waits up to 10 s for
  /// the spawner to reap them all, so the next round does not count
  /// them; throws when they outlast that.
  Future<void> kill() async {
    pids.where(isSleeper).forEach(Process.killPid);
    await _spawner?.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError(
        'sleepers still running 10 s after SIGTERM; '
        'the next process count would include them',
      ),
    );
  }
}

/// Each slow collector a tick can request on its own, then all of them
/// but the probe in one tick, three rounds on one sampler: wall time, CPU
/// and the statuses. A collector with arguments is `hw_o` only.
Future<List<Map<String, Object?>>> measureSlowTick(
  String shell,
  int clockTicks,
  Map<String, String> env,
) => _withSampler(shell, SamplerKind.slow, env, (s) async {
  final slow = [
    for (final c in Collector.values)
      if (c.sampler == SamplerKind.slow && c.argValidators.isEmpty) c,
  ];
  final requests = [
    for (final c in slow) [c],
    slow.where((c) => c != Collector.probe).toList(),
  ];
  final walls = [for (final _ in requests) <num>[]];
  final cpus = [for (final _ in requests) <num>[]];
  final last = <SamplerReply>[];
  var seq = 0;
  for (var round = 0; round < 3; round++) {
    last.clear();
    for (var i = 0; i < requests.length; i++) {
      final (r, cpu) = await _timed(s, ++seq, requests[i], clockTicks);
      last.add(r);
      walls[i].add(r.wall.inMicroseconds / 1000);
      cpus[i].add(cpu);
    }
  }
  return [
    for (var i = 0; i < requests.length; i++)
      {
        'shell': shell,
        'collectors': [for (final c in requests[i]) c.name],
        'wallMs': _stats(walls[i]),
        'cpuMs': _stats(cpus[i]),
        'replyBytes': last[i].bytes,
        'statuses': {
          for (final sec in last[i].tick?.sections ?? const <HwsSection>[])
            sec.collector: sec.status.name,
        },
      },
  ];
});

/// Runs [body] on a `<shell> -s` sampler of [kind] once it is READY.
Future<T> _withSampler<T>(
  String shell,
  SamplerKind kind,
  Map<String, String> env,
  Future<T> Function(LocalSampler) body,
) async {
  final s = await LocalSampler.start(
    SamplerLaunch.stdinShell(shell),
    kind: kind,
    environment: env,
  );
  try {
    await s.ready;
    return await body(s);
  } finally {
    await s.close();
  }
}

/// One request and the CPU it cost the shell and its waited-for
/// children, in milliseconds. No request waits longer than 10 minutes.
Future<(SamplerReply, double)> _timed(
  LocalSampler s,
  int seq,
  List<Collector> collectors,
  int clockTicks,
) async {
  final a = readProcessCpu(s.pid);
  final r = await s
      .request(seq, collectors)
      .timeout(const Duration(minutes: 10));
  final b = readProcessCpu(s.pid);
  return (r, (b.self + b.children - a.self - a.children) * 1000 / clockTicks);
}

String _resolveShell(String shell) {
  if (shell.contains('/')) return shell;
  return findOnCapturePath(shell) ??
      (throw ArgumentError.value(shell, 'shell', 'not on $kCapturePath'));
}

Map<String, num> _stats(List<num> values) {
  final sorted = [...values]..sort();
  double round(num v) => (v * 1000).round() / 1000;
  return {
    'min': round(sorted.first),
    'median': round(sorted[sorted.length ~/ 2]),
    'mean': round(sorted.reduce((a, b) => a + b) / sorted.length),
    'max': round(sorted.last),
  };
}
