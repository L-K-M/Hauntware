import 'package:klabautermann_core/klabautermann_core.dart';

/// What part of CPU time a [CpuHint] explains (CPU-04).
enum CpuHintKind {
  /// The hypervisor ran other guests on this machine's CPUs.
  steal,

  /// Cores sat idle while tasks waited for storage.
  iowait,

  /// Hardware and soft interrupt handling, `irq` plus `softirq`.
  interrupts,
}

/// One plain-language hint on a CPU share, with the share it explains in
/// percent.
typedef CpuHint = ({CpuHintKind kind, double percent});

/// The share of all CPU time from which a part earns its hint. Below it
/// steal, iowait and interrupts are ordinary noise on a busy host; at a
/// quarter of a core's worth on a four-core VPS they are worth saying.
const double kCpuHintPercent = 10;

/// [cpu]'s hints, most telling first: steal says the host is short of CPU
/// it was sold, iowait that storage holds it back, interrupts that
/// devices keep it busy.
List<CpuHint> cpuHints(CpuPercentages cpu) => [
  for (final (kind, percent) in [
    (CpuHintKind.steal, cpu.steal),
    (CpuHintKind.iowait, cpu.iowait),
    (CpuHintKind.interrupts, cpu.irq + cpu.softirq),
  ])
    if (percent >= kCpuHintPercent) (kind: kind, percent: percent),
];
