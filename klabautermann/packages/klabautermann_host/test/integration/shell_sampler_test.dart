// Real-shell integration test (03 §6.2; 04 App. A, E1, E2, E7).
//
// Starts kSamplerStartCommand's `env` with `<shell> -s` in place of
// `sh -s`, writes the assembled program and two ticks in one write, then
// an on-demand request, and checks the assembled replies against the
// local /proc and /etc/os-release. Each shell also runs the command
// itself as the login shell, after printing a startup-file banner.
// Tagged `shell`; a shell that is not installed is skipped with a reason.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// kSamplerStartCommand's argv with [shell] as the sampler instead of
/// `sh`, so each installed shell is exercised under the same environment.
List<String> _samplerCommand(String shell) {
  final words = kSamplerStartCommand.split(' ');
  expect(words.first, 'exec');
  expect(words.sublist(words.length - 2), ['sh', '-s']);
  return [...words.sublist(1, words.length - 2), shell, '-s'];
}

/// Quotes a word for the on-demand line; part-1 collectors take no
/// arguments, so this is only a placeholder for the injected function.
String _quote(String word) => "'${word.replaceAll("'", "'\\''")}'";

String? _shellPath(String name) {
  for (final dir in ['/bin', '/usr/bin']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

final _shells = <String, String>{
  for (final name in ['dash', 'bash'])
    if (_shellPath(name) case final p?) name: p,
};

/// One assembled run: the READY version, the replies by request
/// sequence, the raw reply bytes and the nonce they were framed with.
final class _Reply {
  _Reply(this.ready, this.ticks, this.raw, this.nonce);

  final String? ready;
  final Map<int, HwsTick> ticks;
  final List<int> raw;
  final String nonce;
}

Future<_Reply> _run(
  List<String> command,
  SamplerKind kind,
  List<Collector> tickCollectors,
  Collector onDemand,
) async {
  final nonce = generateNonce(Random.secure());
  final program = buildSamplerProgram(kind: kind, nonce: nonce);
  final proc = await Process.start(command.first, command.sublist(1));
  final out = <int>[];
  final err = StringBuffer();
  final outDone = proc.stdout.forEach(out.addAll);
  final errDone = proc.stderr.transform(utf8.decoder).forEach(err.write);

  proc.stdin.write(program);
  proc.stdin.write(encodeTickRequest(1, tickCollectors));
  proc.stdin.write(encodeTickRequest(2, tickCollectors));
  await proc.stdin.flush();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  proc.stdin.write(encodeOnDemandRequest(3, onDemand, const [], quote: _quote));
  await proc.stdin.flush();
  await proc.stdin.close();

  await outDone.timeout(const Duration(seconds: 20));
  await errDone.timeout(const Duration(seconds: 20));
  final code = await proc.exitCode.timeout(const Duration(seconds: 20));
  expect(code, 0, reason: 'shell stderr: ${err.toString().trim()}');

  String? ready;
  final ticks = <int, HwsTick>{};
  for (final e in HwsTickAssembler(nonce: nonce).push(out)) {
    switch (e) {
      case HwsSessionReady(:final version):
        ready = version;
      case HwsTick(:final seq):
        ticks[seq] = e;
      case HwsTickLost(:final seq, :final detail):
        fail('reply $seq lost: $detail');
      case HwsSessionFailed(:final fault, :final detail):
        fail('session failed (${fault.name}): $detail');
    }
  }
  return _Reply(ready, ticks, out, nonce);
}

/// Splits a section payload into its `== name ==` blocks (03 §6.4).
Map<String, List<String>> _blocks(HwsSection s) =>
    splitBlocks(utf8.decode(s.payload), kTimeoutAbsentMarker).blocks;

/// Independently re-reads the raw reply and checks that every `S` marker's
/// declared byte count is exactly the payload length and is followed by a
/// newline (03 §6.2 "byte counts exact").
void _expectDeclaredByteCounts(List<int> raw, String nonce) {
  final prefix = [0x1e, ...latin1.encode(nonce), 0x20, 0x53, 0x20];
  var found = 0;
  var i = 0;
  while (i + prefix.length <= raw.length) {
    if (!_matchAt(raw, prefix, i)) {
      i++;
      continue;
    }
    final nl = _indexOf(raw, 0x0a, i + prefix.length);
    expect(nl, greaterThan(0), reason: 'S marker has no newline');
    final parts = latin1.decode(raw.sublist(i + prefix.length, nl)).split(' ');
    expect(parts, hasLength(3), reason: 'S marker fields');
    final declared = int.parse(parts[2]);
    expect(
      nl + 1 + declared,
      lessThan(raw.length),
      reason: 'payload of ${parts[0]} runs past the reply',
    );
    expect(
      raw[nl + 1 + declared],
      0x0a,
      reason: 'payload of ${parts[0]} is not followed by a newline',
    );
    found++;
    i = nl + 1 + declared + 1;
  }
  expect(found, greaterThan(0), reason: 'no S markers in the reply');
}

bool _matchAt(List<int> haystack, List<int> needle, int at) {
  for (var j = 0; j < needle.length; j++) {
    if (haystack[at + j] != needle[j]) return false;
  }
  return true;
}

int _indexOf(List<int> bytes, int byte, int from) {
  for (var i = from; i < bytes.length; i++) {
    if (bytes[i] == byte) return i;
  }
  return -1;
}

void _expectAllStatusesOkOrMissing(_Reply r) {
  for (final entry in r.ticks.entries) {
    for (final s in entry.value.sections) {
      expect(
        s.status,
        anyOf(SectionStatus.ok, SectionStatus.missing),
        reason: 'seq ${entry.key} ${s.collector} reported ${s.status.name}',
      );
    }
  }
}

void _expectMetricBlocks(HwsSection s, {required bool core}) {
  final b = _blocks(s);
  final stat = b['stat'];
  expect(stat, isNotNull, reason: '${s.collector} stat block');
  expect(stat!.first.trim(), matches(RegExp(r'^cpu(\s+\d+)+$')));
  expect(
    b['meminfo']!.any((l) => l.startsWith('MemTotal:')),
    isTrue,
    reason: 'meminfo carries MemTotal',
  );
  expect(
    b['loadavg']!.first.trim(),
    matches(RegExp(r'^\d+\.\d+ \d+\.\d+ \d+\.\d+ \d+/\d+ \d+$')),
  );
  if (core) {
    expect(stat.any((l) => l.startsWith('btime ')), isTrue);
    expect(b['diskstats'], isNotEmpty);
    expect(b['uptime'], isNotEmpty);
  }
}

void _expectIdentity(HwsSection s) {
  final b = _blocks(s);
  final osr = b['os-release'];
  expect(osr, isNotNull, reason: 'identity os-release block');
  final local = File('/etc/os-release').readAsStringSync();
  expect(
    osr!.join('\n'),
    local.endsWith('\n') ? local.substring(0, local.length - 1) : local,
    reason: 'os-release bytes match the local file',
  );
  final uname = b['uname']!.first.trim();
  final localUname = Process.runSync('uname', [
    '-s',
    '-r',
    '-m',
  ]).stdout.toString().trim();
  expect(uname, localUname);
}

void _expectFs(HwsSection s) {
  if (s.status == SectionStatus.missing) return;
  final b = _blocks(s);
  expect(b['blocks']!.first, startsWith('Filesystem'));
  expect(b['inodes']!.first, startsWith('Filesystem'));
}

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    group(name, () {
      test('fast program: two ticks and an on-demand core', () async {
        final r = await _run(_samplerCommand(path), SamplerKind.fast, [
          Collector.overview,
          Collector.core,
        ], Collector.core);
        expect(r.ready, kCollectorSetVersion);
        expect(r.ticks.keys, containsAll(<int>[1, 2, 3]));
        _expectAllStatusesOkOrMissing(r);
        for (final seq in [1, 2]) {
          final names = r.ticks[seq]!.sections.map((s) => s.collector).toSet();
          expect(names, containsAll(<String>['overview', 'core']));
        }
        expect(r.ticks[3]!.sections.map((s) => s.collector), contains('core'));
        _expectDeclaredByteCounts(r.raw, r.nonce);

        final overview = r.ticks[1]!.section('overview')!;
        expect(overview.status, SectionStatus.ok);
        _expectMetricBlocks(overview, core: false);

        final core = r.ticks[1]!.section('core')!;
        expect(core.status, SectionStatus.ok);
        _expectMetricBlocks(core, core: true);

        // The aggregate cpu line carries the same fields as the local
        // /proc/stat line the sampler read (03 §6.4).
        final localStat = File('/proc/stat').readAsLinesSync().first;
        final localFields = localStat.trim().split(RegExp(r'\s+')).length;
        final statLine = _blocks(core)['stat']!.first.trim();
        expect(statLine, startsWith('cpu '));
        expect(statLine.split(RegExp(r'\s+')), hasLength(localFields));
      });

      test('slow program: two ticks and an on-demand probe', () async {
        final r = await _run(_samplerCommand(path), SamplerKind.slow, [
          Collector.fs,
          Collector.identity,
        ], Collector.probe);
        expect(r.ready, kCollectorSetVersion);
        expect(r.ticks.keys, containsAll(<int>[1, 2, 3]));
        _expectAllStatusesOkOrMissing(r);
        for (final seq in [1, 2]) {
          final names = r.ticks[seq]!.sections.map((s) => s.collector).toSet();
          expect(names, containsAll(<String>['fs', 'identity']));
        }
        expect(
          r.ticks[3]!.sections.map((s) => s.collector),
          contains('probe_kernel'),
        );
        _expectDeclaredByteCounts(r.raw, r.nonce);

        final identity = r.ticks[1]!.section('identity')!;
        expect(identity.status, SectionStatus.ok);
        _expectIdentity(identity);
        _expectFs(r.ticks[1]!.section('fs')!);

        final kernel = r.ticks[3]!.section('probe_kernel')!;
        if (kernel.status == SectionStatus.ok) {
          final localUname = Process.runSync('uname', [
            '-s',
            '-r',
            '-m',
          ]).stdout.toString().trim();
          expect(utf8.decode(kernel.payload).trim(), localUname);
        }

        // The probe sections decode into a profile whose kernel fields match
        // the local /proc (03 §6.1).
        final profile = parseProbe(
          r.ticks[3]!.sections
              .map(ProbeSection.fromEvent)
              .whereType<ProbeSection>()
              .toList(),
          ParseContext.standard,
        ).value;
        expect(profile.kernelSys, isNotNull);
        expect(profile.tools, isNotEmpty);
        final ostype = File('/proc/sys/kernel/ostype');
        if (ostype.existsSync()) {
          expect(profile.kernelSys, ostype.readAsStringSync().trim());
        }
        final osrelease = File('/proc/sys/kernel/osrelease');
        if (osrelease.existsSync()) {
          expect(profile.kernelRelease, osrelease.readAsStringSync().trim());
        }
      });

      test('slow program: procs, units, timers and cron', () async {
        final r = await _run(_samplerCommand(path), SamplerKind.slow, [
          Collector.procs,
          Collector.units,
          Collector.timers,
          Collector.cron,
        ], Collector.procs);
        expect(r.ready, kCollectorSetVersion);
        expect(r.ticks.keys, containsAll(<int>[1, 2, 3]));
        _expectAllStatusesOkOrMissing(r);
        for (final seq in [1, 2]) {
          final names = r.ticks[seq]!.sections.map((s) => s.collector).toSet();
          expect(
            names,
            containsAll(<String>['procs', 'units', 'timers', 'cron']),
          );
        }
        _expectDeclaredByteCounts(r.raw, r.nonce);

        // The local /proc exists, so procs must parse into the process
        // table with pid 1 present and no fabricated framing.
        final procs = r.ticks[1]!.section('procs')!;
        expect(procs.status, SectionStatus.ok);
        final parsed = parseProcs(
          utf8.decode(procs.payload),
          ParseContext.standard,
        );
        expect(parsed.value.processes, isNotEmpty);
        if (File('/proc/1/stat').existsSync()) {
          expect(parsed.value.processes.any((p) => p.pid == 1), isTrue);
        }

        // units and timers are `missing` where systemd is absent; when
        // present their payload parses into a snapshot.
        final units = r.ticks[1]!.section('units')!;
        if (units.status == SectionStatus.ok) {
          final u = parseUnits(
            utf8.decode(units.payload),
            ParseContext.standard,
          );
          expect(u.value.format, isNot(UnitListFormat.none));
        }
        final timers = r.ticks[1]!.section('timers')!;
        if (timers.status == SectionStatus.ok) {
          final t = parseTimers(
            utf8.decode(timers.payload),
            ParseContext.standard,
          );
          expect(t.value.format, isNot(TimerListFormat.none));
        }

        // cron succeeds without a personal crontab; ownCrontabPresent is
        // unknown when the `crontab` tool is absent (03 §7.7).
        final cron = r.ticks[1]!.section('cron')!;
        expect(cron.status, SectionStatus.ok);
        expect(
          () => parseCron(utf8.decode(cron.payload), ParseContext.standard),
          returnsNormally,
        );
      });

      test('the start command runs from it as the login shell', () async {
        // Startup files may print before the command runs; the reply
        // assembler skips that output up to READY.
        final r = await _run(
          [path, '-c', 'printf "banner\\r\\npartial"; $kSamplerStartCommand'],
          SamplerKind.fast,
          [Collector.overview],
          Collector.overview,
        );
        expect(r.ready, kCollectorSetVersion);
        expect(r.ticks.keys, containsAll(<int>[1, 2, 3]));
        expect(r.ticks[1]!.section('overview')!.status, SectionStatus.ok);
        expect(r.ticks[1]!.uptimeSeconds, isNotNull);
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
