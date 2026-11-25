part of 'commands.dart';

/// SYS-03's power verbs (03 §7.11).
enum PowerVerb {
  /// Restart the host.
  reboot,

  /// Turn the host off; it answers again only once someone starts it.
  poweroff,
}

/// The markers before the usable CPU count, `lscpu`'s JSON and the
/// `/proc/cpuinfo` lines in [HostCommands.cpuTopology]' output.
const kCpuNprocMarker = '== nproc';
const kCpuLscpuMarker = '== lscpu';
const kCpuInfoMarker = '== cpuinfo';

/// How many earlier boots [HostCommands.bootEnds] reads the ends of.
const kBootEndsRead = 10;

/// The marker between the running release and the installed kernels in
/// [HostCommands.kernels]' output.
const kKernelsMarker = '== modules';

/// [HostCommands.oomKills]' section markers: the `oom_kill` count of
/// `/proc/vmstat`, which kernel log was read, and how many of its lines.
const kOomVmstatMarker = '== vmstat';
const kOomSourceMarker = '== source';
const kOomReadMarker = '== read';

/// How many of the current boot's OOM kill lines [HostCommands.oomKills]
/// keeps, the newest.
const kOomLinesKept = 50;
