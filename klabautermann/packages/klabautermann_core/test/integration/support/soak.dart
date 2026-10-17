/// The soak's budgets, configuration and arithmetic (03 §11.4, K28b), kept
/// apart from `soak_test.dart` so that `soak_test.dart` beside this file
/// can check them without the fixture.
library;

import 'dart:io';
import 'dart:math' as math;

/// 03 §11.4: "Fast tick at most 2.5 KB, plus 30 B for each CPU beyond 32
/// (D48)". Bytes of one fast-sampler reply, as S2, S5 and
/// `payload_filter_test.dart` count them.
const kFastTickBytes = 2500;
const kFastTickBytesPerExtraCpu = 30;
const kFastTickCpusIncluded = 32;

/// 03 §11.4: "and 5 ms of server CPU on the reference VM [E]": the
/// sampler shell's CPU per fast tick, as S2 measured it. The soak records
/// it against this figure and does not fail on it: 03 sets it for its
/// reference VM as an estimate, and the fixture's sampler is BusyBox ash
/// in a container on a shared runner, which S2 and S5 already call
/// neither that VM nor a phone. Device and reference-VM figures stay
/// manual (06).
const kFastTickServerCpuMs = 5.0;

/// 03 §11.4: "10 monitored hosts at default phone cadence: under 1 KB/s
/// in total", in reply bytes (S5's reading, with one server open).
const kSoakHosts = 10;
const kTenHostBytesPerSecond = 1000;

/// What a series may grow by, from the median of the window's first
/// third to that of its last third, and still count as "no growth"
/// (03 §11.4). The numbers are provisional, chosen for shared CI runners:
///
/// - Channels: none. Each link holds its two samplers and nothing else.
/// - Descriptors: two, for one the VM or the test runner happens to hold
///   at a reading; one leaked per tick or per minute passes them within
///   the first minutes of a 10-minute window.
/// - Live heap after a full collection: 1 MiB. S5's JIT run held it within
///   0.26 MB for 300 s; one retained sample per tick (about 1 KB) for 10
///   minutes is about 0.8 MB at the Phone cadence, so this catches leaks
///   per reading only over a longer run, and anything larger here.
/// - Resident set: 32 MiB. The JIT VM's resident set (S5: 367 to 402 MB)
///   moves with compilation and the pages the VM keeps; this catches
///   native leaks, which the heap does not show, at a coarse grain.
const kChannelGrowth = 0;
const kDescriptorGrowth = 2;
const kHeapGrowthBytes = 1 << 20;
const kRssGrowthBytes = 32 << 20;

/// The 03 §11.4 budget for one fast tick's reply on a host with [cpus]
/// CPUs.
int fastTickByteBudget(int cpus) =>
    kFastTickBytes +
    kFastTickBytesPerExtraCpu * math.max(0, cpus - kFastTickCpusIncluded);

/// Why the soak skips.
const soakSkipReason =
    'needs the sshd fixture and KLABAUTERMANN_SOAK_SECONDS: run '
    'klabautermann/test/integration/run.sh, whose soak block sets both';

/// How long the soak runs and where its numbers go, from the variables
/// run.sh's soak block exports.
final class SoakConfig {
  SoakConfig._(this.window, this.evidenceDirectory)
    : warmup = Duration(
        seconds: (window.inSeconds ~/ 10).clamp(
          _minWarmupSeconds,
          _maxWarmupSeconds,
        ),
      ),
      interval = Duration(
        milliseconds: math.max(
          1000,
          window.inMilliseconds ~/ readingsPerWindow,
        ),
      );

  /// The configuration, or null when `KLABAUTERMANN_SOAK_SECONDS` is
  /// unset. Throws [FormatException] for a value run.sh would refuse, or
  /// a missing or relative `KLABAUTERMANN_SOAK_DIR`.
  static SoakConfig? fromEnvironment([Map<String, String>? environment]) {
    environment ??= Platform.environment;
    final seconds = environment['KLABAUTERMANN_SOAK_SECONDS'];
    if (seconds == null) return null;

    final parsed = int.tryParse(seconds);
    if (parsed == null || parsed < 1 || '$parsed' != seconds) {
      throw FormatException(
        'KLABAUTERMANN_SOAK_SECONDS takes a whole number of seconds',
        seconds,
      );
    }
    final directory = environment['KLABAUTERMANN_SOAK_DIR'] ?? '';
    if (!directory.startsWith('/')) {
      throw FormatException(
        'KLABAUTERMANN_SOAK_DIR must be an absolute directory',
        directory,
      );
    }
    return SoakConfig._(Duration(seconds: parsed), directory);
  }

  static const _minWarmupSeconds = 10, _maxWarmupSeconds = 60;

  /// Readings in the window after its first, so the thirds of
  /// [growthOf] hold seven each.
  static const readingsPerWindow = 20;

  /// The measured window: 03 §11.4's ten minutes on CI.
  final Duration window;

  /// Before the window: links up, the JIT VM compiled and the samplers
  /// settled. A tenth of the window, from 10 to 60 seconds.
  final Duration warmup;

  /// Between readings.
  final Duration interval;

  /// Where `soak.json` and the engine's event log go.
  final String evidenceDirectory;
}

/// One series' "no growth" check.
final class Growth {
  const Growth({
    required this.series,
    required this.first,
    required this.last,
    required this.tolerance,
  });

  final String series;

  /// The medians of the window's first and last thirds.
  final num first, last;
  final num tolerance;

  num get growth => last - first;
  bool get ok => growth <= tolerance;

  Map<String, Object?> toJson() => {
    'series': series,
    'firstThirdMedian': first,
    'lastThirdMedian': last,
    'growth': growth,
    'tolerance': tolerance,
    'ok': ok,
  };
}

/// [series]' growth over the window: the median of its last third against
/// that of its first. Medians keep one odd reading from deciding, and a
/// leak grows every third. Needs three readings.
Growth growthOf(String series, List<num> values, {required num tolerance}) {
  if (values.length < 3) {
    throw ArgumentError.value(values, 'values', 'needs three readings');
  }
  final third = values.length ~/ 3;
  return Growth(
    series: series,
    first: median(values.take(third)),
    last: median(values.skip(values.length - third)),
    tolerance: tolerance,
  );
}

/// The lower median of [values], which must not be empty.
num median(Iterable<num> values) {
  final sorted = [...values]..sort();
  return sorted[(sorted.length - 1) ~/ 2];
}

/// Count, smallest, median, largest and mean of [values], or an empty map.
Map<String, num> countStats(List<int> values) {
  if (values.isEmpty) return const {};

  final sum = values.fold(0, (a, b) => a + b);
  return {
    'count': values.length,
    'min': values.reduce(math.min),
    'median': median(values),
    'max': values.reduce(math.max),
    'mean': round3(sum / values.length),
  };
}

double round3(num value) => (value * 1000).round() / 1000;

/// One sampler shell on the fixture: its PID, its parent (the sshd
/// process of its connection) and its CPU so far in clock ticks, with
/// that of the children it has waited for, since a tick's cost includes
/// whatever it forks (03 §6.2's fork budget expects none on the fast
/// sampler).
typedef ShellCpu = ({int pid, int ppid, int cpuTicks});

/// The `/proc/<pid>/stat` lines in [text], one per line. comm (field 2)
/// may hold spaces and parentheses and ends at the last `)` (proc(5)).
List<ShellCpu> parseShellStats(String text) => [
  for (final line in text.split('\n'))
    if (line.lastIndexOf(')') case final end when end > 0)
      if (line.substring(end + 2).split(' ') case final fields
          when fields.length > 14)
        (
          pid: int.parse(line.substring(0, line.indexOf(' '))),
          // Field 4 is ppid; 14 to 17 utime, stime, cutime and cstime.
          ppid: int.parse(fields[1]),
          cpuTicks: [
            for (final field in fields.sublist(11, 15)) int.parse(field),
          ].fold(0, (a, b) => a + b),
        ),
];

/// The fast sampler of each connection in [shells]: of a connection's
/// shells, the one started last, since a link opens its slow sampler and
/// then its fast one (`SamplingScheduler._start`, `sshd/samplers.sh`).
Set<int> fastShells(Iterable<ShellCpu> shells) {
  final newest = <int, int>{};
  for (final shell in shells) {
    newest.update(
      shell.ppid,
      (pid) => math.max(pid, shell.pid),
      ifAbsent: () => shell.pid,
    );
  }
  return newest.values.toSet();
}

/// One TCP connection's payload bytes, from the kernel's `tcp_info`.
typedef WireBytes = ({int sent, int received});

/// `ss -tinH` output: each connection's local address and its payload
/// bytes sent and received (`bytes_sent`, `bytes_received`; ss(8),
/// `tcp_info` since Linux 4.19). The socket's line comes first and its
/// indented `tcp_info` line after.
Map<String, WireBytes> parseSsTcpInfo(String text) {
  final connections = <String, WireBytes>{};
  String? local;
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      // State, Recv-Q, Send-Q, local, peer; with `state established`
      // ss leaves the state column out.
      final columns = line.trim().split(RegExp(r'\s+'));
      local = columns.length >= 4 ? columns[columns.length - 2] : null;
      continue;
    }
    final sent = _ssSent.firstMatch(line);
    final received = _ssReceived.firstMatch(line);
    if (local == null || sent == null || received == null) continue;
    connections[local] = (
      sent: int.parse(sent[1]!),
      received: int.parse(received[1]!),
    );
    local = null;
  }
  return connections;
}

final _ssSent = RegExp(r'\bbytes_sent:(\d+)');
final _ssReceived = RegExp(r'\bbytes_received:(\d+)');
