import 'package:klabautermann_docker/klabautermann_docker.dart'
    show EnvVar, MaskedValue;
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        AnacronJob,
        BootEnd,
        CpuTopology,
        InterfacesRead,
        JournalBootEntry,
        KernelCheck,
        ListeningPortsRead,
        LogFileEntry,
        LoggedCronRun,
        MountsRead,
        OomKillsRead,
        ProcessDetail,
        TimerLastRun,
        UnitResources,
        UnitSocket;
import 'package:meta/meta.dart';

/// What a [UnitQuery] reads.
@immutable
sealed class UnitQuerySpec {
  const UnitQuerySpec({this.scope = UnitScope.system});

  final UnitScope scope;
}

/// [unit]'s file and drop-ins (`systemctl cat`, SVC-07), answered by
/// [UnitFilePayload].
final class UnitFileQuery extends UnitQuerySpec {
  const UnitFileQuery(this.unit, {super.scope});

  final String unit;
}

/// [unit]'s resources (`systemctl show`, SVC-08), answered by
/// [UnitResourcesPayload].
final class UnitResourcesQuery extends UnitQuerySpec {
  const UnitResourcesQuery(this.unit, {super.scope});

  final String unit;
}

/// The manager's sockets (`systemctl list-sockets`, SVC-10), answered by
/// [UnitSocketsPayload].
final class SocketsQuery extends UnitQuerySpec {
  const SocketsQuery({super.scope});
}

/// What a [JobHistoryQuery] reads.
@immutable
sealed class JobHistorySpec {
  const JobHistorySpec();
}

/// `/etc/anacrontab` with each job's stamp (JOB-04), answered by
/// [AnacronPayload].
final class AnacronQuery extends JobHistorySpec {
  const AnacronQuery();
}

/// [timer]'s last trigger and how [service]'s run ended (JOB-05),
/// answered by [TimerLastRunPayload].
final class TimerLastRunQuery extends JobHistorySpec {
  const TimerLastRunQuery({required this.timer, required this.service});

  final String timer;
  final String service;
}

/// The newest [lines] job starts cron logged (JOB-05), answered by
/// [CronRunsPayload].
final class CronRunsQuery extends JobHistorySpec {
  const CronRunsQuery({this.lines = 50});

  final int lines;
}

/// What a [HostQuery] reads.
@immutable
sealed class HostQuerySpec {
  const HostQuerySpec();
}

/// The regular files under `/var/log`, two levels deep (LOG-08), as
/// [VarLogFiles].
final class VarLogQuery extends HostQuerySpec {
  const VarLogQuery();
}

/// The journal's boots (LOG-09), as [JournalBoots]: `journalctl
/// --list-boots` as JSON on systemd 251 and later, the text table on
/// older ones and where the probe found no version.
final class BootsQuery extends HostQuerySpec {
  const BootsQuery();
}

/// One process's details and what owns it (PRC-04, PRC-05), as
/// [ProcessDetails], read as the login user. [startTicks] guards against
/// a reused PID: a process that ended, or whose PID now names another,
/// answers [ProcessEnded].
final class ProcessDetailQuery extends HostQuerySpec {
  const ProcessDetailQuery({required this.pid, required this.startTicks});

  final int pid;
  final int startTicks;
}

/// The kills since boot and the current boot's OOM kills the kernel log
/// names (MEM-03), as [OomKills].
final class OomKillsQuery extends HostQuerySpec {
  const OomKillsQuery();
}

/// The listening TCP and bound UDP sockets with their processes and
/// those processes' units and containers (NET-04), as [ListeningPorts].
final class ListeningPortsQuery extends HostQuerySpec {
  const ListeningPortsQuery();
}

/// How the boots before the current one ended (BOOT-02), as [BootEnds]:
/// the last [kBootEndsRead] of them, read from their journals.
final class BootEndsQuery extends HostQuerySpec {
  const BootEndsQuery();
}

/// The running kernel against the installed ones (BOOT-03), as
/// [Kernels].
final class KernelsQuery extends HostQuerySpec {
  const KernelsQuery();
}

/// The processor's model and topology (CPU-07), as [CpuTopologyRead].
final class CpuTopologyQuery extends HostQuerySpec {
  const CpuTopologyQuery();
}

/// The network interfaces and socket counts (NET-02, NET-03), as
/// [NetInterfaces].
final class InterfacesQuery extends HostQuerySpec {
  const InterfacesQuery();
}

/// Every mount's source, type and options (DSK-05) and the swap devices
/// (DSK-14), as [Mounts].
final class MountsQuery extends HostQuerySpec {
  const MountsQuery();
}

/// A diagnostic bundle (CN-18, 03 §6.5), as [DiagnosticBundle]: the raw
/// output of the probe and of every collector that takes no arguments
/// but `ops`, each read once on its own sampler, for a parser bug report
/// that can become a fixture. Read only while the server is sampled.
final class DiagnosticBundleQuery extends HostQuerySpec {
  const DiagnosticBundleQuery();
}

/// What a [UnitQuery] found.
@immutable
sealed class UnitPayload {
  const UnitPayload();
}

/// A unit's file and drop-ins as `systemctl cat` prints them, each after
/// a `# <path>` line, with `Environment=` values and secrets in `Exec`
/// lines masked (03 §8.9).
final class UnitFilePayload extends UnitPayload {
  UnitFilePayload(Iterable<MaskedValue> text) : text = List.unmodifiable(text);

  final List<MaskedValue> text;
}

final class UnitResourcesPayload extends UnitPayload {
  const UnitResourcesPayload(this.resources);

  final UnitResources resources;
}

final class UnitSocketsPayload extends UnitPayload {
  UnitSocketsPayload(Iterable<UnitSocket> sockets)
    : sockets = List.unmodifiable(sockets);

  final List<UnitSocket> sockets;
}

/// Why a [UnitQuery] read nothing.
enum UnitQueryFailure {
  /// The server is not in the fleet, or has no ready link or probe.
  noLink,

  /// The unit name is not a unit's (03 §8.8).
  invalidUnit,

  /// The manager has no such unit.
  notFound,

  /// The login user's manager could not be reached: no user session and
  /// no linger (SVC-09).
  managerUnavailable,

  /// The command failed otherwise; the detail says how.
  failed,
}

final class UnitQueryFailed extends UnitPayload {
  const UnitQueryFailed(this.failure, {this.detail});

  final UnitQueryFailure failure;

  /// The host's error text, for [UnitQueryFailure.failed].
  final String? detail;
}

/// What a [JobHistoryQuery] found.
@immutable
sealed class JobHistoryPayload {
  const JobHistoryPayload();
}

/// anacron's jobs, their commands masked (03 §8.9).
final class AnacronPayload extends JobHistoryPayload {
  AnacronPayload(Iterable<AnacronJob> jobs) : jobs = List.unmodifiable(jobs);

  final List<AnacronJob> jobs;
}

final class TimerLastRunPayload extends JobHistoryPayload {
  const TimerLastRunPayload(this.lastRun);

  final TimerLastRun lastRun;
}

/// cron's logged job starts, newest first, their commands masked.
final class CronRunsPayload extends JobHistoryPayload {
  CronRunsPayload(Iterable<LoggedCronRun> runs)
    : runs = List.unmodifiable(runs);

  final List<LoggedCronRun> runs;
}

/// Why a [JobHistoryQuery] read nothing.
enum JobHistoryFailure {
  /// The server is not in the fleet, or has no ready link.
  noLink,

  /// A timer or unit name is not a unit's (03 §8.8).
  invalidTarget,

  /// The host has no `/etc/anacrontab`, so anacron is not installed.
  notInstalled,

  /// The command failed otherwise; the detail says how.
  failed,
}

final class JobHistoryFailed extends JobHistoryPayload {
  const JobHistoryFailed(this.failure, {this.detail});

  final JobHistoryFailure failure;
  final String? detail;
}

/// What a [HostResult] carries.
@immutable
sealed class HostPayload {
  const HostPayload();
}

/// [VarLogQuery]'s files, sorted by path.
final class VarLogFiles extends HostPayload {
  const VarLogFiles(this.files);

  final List<LogFileEntry> files;
}

/// [BootsQuery]'s boots, oldest first, as journalctl lists them.
final class JournalBoots extends HostPayload {
  const JournalBoots(this.boots);

  final List<JournalBootEntry> boots;
}

/// [ProcessDetailQuery]'s answer: the process's details, without its
/// environment, which crosses in [environment] with each value masked by
/// its key (03 §8.9); null where the login user may not read it.
final class ProcessDetails extends HostPayload {
  ProcessDetails(this.detail, {List<EnvVar>? environment})
    : environment = environment == null ? null : List.unmodifiable(environment);

  final ProcessDetail detail;
  final List<EnvVar>? environment;
}

/// Why a [ProcessDetailQuery] read no process.
enum ProcessEnd {
  /// The process has exited.
  gone,

  /// Its PID names another process now.
  reused,
}

/// [ProcessDetailQuery]'s answer for a process no longer there.
final class ProcessEnded extends HostPayload {
  const ProcessEnded(this.end);

  final ProcessEnd end;
}

/// [OomKillsQuery]'s kills.
final class OomKills extends HostPayload {
  const OomKills(this.read);

  final OomKillsRead read;
}

/// [ListeningPortsQuery]'s sockets.
final class ListeningPorts extends HostPayload {
  const ListeningPorts(this.read);

  final ListeningPortsRead read;
}

/// [BootEndsQuery]'s ends by boot ID; a boot it did not read is absent.
final class BootEnds extends HostPayload {
  BootEnds(Map<String, BootEnd> ends) : ends = Map.unmodifiable(ends);

  final Map<String, BootEnd> ends;
}

/// [KernelsQuery]'s kernels.
final class Kernels extends HostPayload {
  const Kernels(this.check);

  final KernelCheck check;
}

/// [CpuTopologyQuery]'s processor.
final class CpuTopologyRead extends HostPayload {
  const CpuTopologyRead(this.topology);

  final CpuTopology topology;
}

/// [InterfacesQuery]'s interfaces and sockets.
final class NetInterfaces extends HostPayload {
  const NetInterfaces(this.read);

  final InterfacesRead read;
}

/// [MountsQuery]'s mounts and swap devices.
final class Mounts extends HostPayload {
  const Mounts(this.read);

  final MountsRead read;
}

/// One collector's section of a [DiagnosticBundle], as the host sent it:
/// [collector] is its wire name, [status] its section status, and [text]
/// its payload, decoded leniently and not yet redacted.
@immutable
final class DiagnosticSection {
  const DiagnosticSection({
    required this.collector,
    required this.status,
    required this.text,
  });

  final String collector;
  final String status;
  final String text;
}

/// [DiagnosticBundleQuery]'s sections, the probe's first, then the fast
/// sampler's and the slow one's in collector order. A sampler that
/// answered nothing leaves its collectors out; [missing] names them.
final class DiagnosticBundle extends HostPayload {
  const DiagnosticBundle(this.sections, {this.missing = const []});

  final List<DiagnosticSection> sections;

  /// The wire names of the collectors whose sampler gave no answer.
  final List<String> missing;
}

/// A [HostQuery] that read nothing; [detail] is the end of its stderr,
/// or the text of an error the read threw (a timeout or a lost link).
final class HostQueryFailed extends HostPayload {
  const HostQueryFailed(this.failure, {this.detail});

  final HostQueryFailure failure;
  final String? detail;
}

/// Why a [HostQuery] read nothing.
enum HostQueryFailure {
  /// The server has no ready link.
  noLink,

  /// The host refused the read.
  denied,

  /// The tool the query runs is absent on the host.
  missing,

  /// The read failed otherwise: a timeout, a lost link, or an exit the
  /// query does not expect.
  failed,
}

/// Which systemd manager a unit action or query addresses (03 §7.5,
/// SVC-09).
enum UnitScope {
  /// The system manager.
  system,

  /// The login user's own manager (`systemctl --user`). Its actions run
  /// as the login user, never through sudo, which would address root's
  /// manager instead.
  user,
}
