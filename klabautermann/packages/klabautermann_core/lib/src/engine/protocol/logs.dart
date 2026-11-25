import 'package:klabautermann_host/klabautermann_host.dart' show JournalBoot;
import 'package:meta/meta.dart';

import 'equality.dart' show sameItems;

/// What an [OpenLogStream] reads, on which server, and how much (03 §7.6,
/// §10.1).
///
/// A window ([follow] false) reads the newest [window] records, older than
/// [afterCursor] when it is set, and ends. They arrive newest first, so
/// the last one's cursor reads on to older records (LOG-01's "load
/// older"; SVC-04's unit logs are one window), except a container's,
/// which arrive oldest first as Docker's `tail` sends them. A follow
/// delivers up to [window] earlier records oldest first, then each new
/// record as the host writes it, until [CloseStream]. With [afterCursor]
/// it resumes after a record the app already holds instead (LOG-02): it
/// delivers every record after that one, so a reconnect leaves no gap,
/// and [window] does not apply.
@immutable
final class LogStreamSpec {
  LogStreamSpec({
    required this.serverId,
    required this.source,
    required this.window,
    required this.follow,
    this.afterCursor,
  }) : assert(window >= 0, 'window counts records'),
       assert(
         afterCursor == null ||
             (source is! FileLogSource && source is! ContainerLogSource),
         'a file tail and a container log have no cursor',
       ),
       assert(
         !follow ||
             switch (source) {
               JournalLogSource(:final until) ||
               ContainerLogSource(:final until) => until == null,
               _ => true,
             },
         'a follow reads up to the present',
       );

  final String serverId;
  final LogSource source;

  /// How many records: a window's size (LOG-01's pages hold 500, SVC-04's
  /// unit logs 50), or how many earlier records a follow without
  /// [afterCursor] delivers before the new ones.
  final int window;

  /// Whether the stream follows new records instead of ending after its
  /// window.
  final bool follow;

  /// A [JournalRecord.cursor] the read continues after, in the stream's
  /// order: a window reads older records, a follow the ones written after
  /// it. File tails, `dmesg` and container logs have no cursor: a
  /// container follow resumes after its newest line itself, as long as
  /// the stream stays open. Null starts at the newest
  /// record. journalctl refuses `--since` together with a cursor, so with
  /// one the engine applies [JournalLogSource.since] itself: a window ends
  /// with [LogStreamEndReason.oldestReached] at the first record older
  /// than it, and a follow skips such records, as it does without one.
  final String? afterCursor;
}

/// Where an [OpenLogStream] reads (03 §7.6, §7.12): the host's journal,
/// kernel log or a file over its link, or a container's logs over its
/// Docker endpoint.
@immutable
sealed class LogSource {
  const LogSource();
}

/// The systemd journal through `journalctl -o json`, read as
/// [JournalRecord]s, with LOG-01's filters; SVC-04's unit logs filter by
/// [unit]. A null filter matches every record. LOG-05 searches the
/// records the view holds; [grep] has journalctl match them (LOG-06).
final class JournalLogSource extends LogSource {
  const JournalLogSource({
    this.unit,
    this.identifier,
    this.priority,
    this.currentBootOnly = false,
    this.boot,
    this.since,
    this.until,
    this.grep,
  });

  /// A systemd unit name (`-u`).
  final String? unit;

  /// A syslog identifier (`-t`).
  final String? identifier;

  /// The least urgent priority shown (`-p`): records at it or more urgent.
  final LogPriority? priority;

  /// Only the current boot's records (`-b`).
  final bool currentBootOnly;

  /// Only [boot]'s records (`-b <boot>`, LOG-09), picked from a
  /// [BootsQuery]; not with [currentBootOnly]. A follow reads the
  /// current boot, so it takes no [boot].
  final JournalBoot? boot;

  /// The time range (`--since`, `--until`). A follow takes no [until],
  /// since it reads up to the present.
  final DateTime? since, until;

  /// A PCRE2 pattern journalctl matches against each record's message
  /// (`-g`, LOG-06), case-insensitive while it is all lower case. A
  /// journalctl built without pattern matching ends the read
  /// [LogStreamEndReason.searchUnsupported].
  final String? grep;
}

/// The kernel's messages for the current boot (LOG-03), or for [boot]
/// (LOG-09): `journalctl -k`, read as [JournalRecord]s, with
/// `dmesg --json --decode` only as the current boot's fallback, read as
/// [KernelRecord]s.
final class KernelLogSource extends LogSource {
  const KernelLogSource({this.boot});

  /// A past boot, picked from a [BootsQuery]; null for the current one.
  /// A follow reads the current boot, so it takes none.
  final JournalBoot? boot;
}

/// One file's lines as [FileRecord]s (LOG-22): `tail -n` for a window,
/// and `tail -F`, which follows the file by name across rotation, for a
/// follow. A [compressed] rotated file (LOG-08) reads as a window only.
final class FileLogSource extends LogSource {
  const FileLogSource(
    this.path, {
    this.redacted = false,
    this.elevated = false,
    this.compressed = false,
  });

  /// The absolute path, typed or picked from the common paths; the engine
  /// validates it (03 §8.8) before it quotes it into the command.
  final String path;

  /// Each line passes the secret redactor before it crosses, as a
  /// detached operation's output does.
  final bool redacted;

  /// The read runs through admin mode's elevation (LOG-22, M4 E16b), for
  /// a file only root may read; the app asks for it after a read ended
  /// [LogStreamEndReason.denied]. Without admin mode it ends denied, and
  /// a follow ends so when admin mode does.
  final bool elevated;

  /// [path] is a rotated `.gz` or `.xz` file, read through `zcat` or
  /// `xzcat` (LOG-08): its last [LogStreamSpec.window] lines, within the
  /// engine's output cap, never followed. A decompressor the host lacks
  /// ends the read [LogStreamEndReason.missing].
  final bool compressed;
}

/// A detached operation's output (03 §7.17): the engine reads its
/// `<id>.log` in the directory the latest `ops` read listed it in, as a
/// [FileLogSource] whose lines are redacted, so a follow keeps showing
/// output across the operation's end. An operation the engine does not
/// list ends the stream as [LogStreamEndReason.invalid].
final class OperationLogSource extends LogSource {
  const OperationLogSource(this.operationId);

  final String operationId;
}

/// One container's logs through the Docker Engine API (CTX-01, 03 §5.6),
/// read as [ContainerRecord]s: `GET /containers/{id}/logs` with
/// `timestamps=1`, its last [LogStreamSpec.window] lines, then the new
/// ones for a follow. A follow outlasts the container's stops: it reads
/// on, after the newest line it delivered, once the container runs
/// again. The read waits for the server's Docker endpoint
/// ([DockerEndpointState]) as [LogStreamWaitReason.link].
///
/// With a time range (CTX-03), the read is every line from [since] to
/// [until] instead of the last [LogStreamSpec.window]: Docker applies
/// `tail` before the range, so the two together would read only the
/// window's lines that fall in it.
final class ContainerLogSource extends LogSource {
  const ContainerLogSource(this.containerId, {this.since, this.until});

  /// The container's id, or its name; the engine validates it before it
  /// puts it in a path.
  final String containerId;

  /// The time range (`since`, `until`), both inclusive. A follow takes no
  /// [until], since it reads up to the present.
  final DateTime? since, until;

  /// Whether the read has a time range.
  bool get ranged => since != null || until != null;
}

/// A syslog severity as journald and the kernel record it, most urgent
/// first, so a value's [Enum.index] is its number (0 to 7, RFC 5424).
enum LogPriority {
  emergency,
  alert,
  critical,
  error,
  warning,
  notice,
  info,
  debug,
}

/// One record of a [LogBatch]; the stream's [LogSource] decides the
/// variant. Each is plain data the engine resolved from what the host sent
/// (D52, 03 §6.5), so the app parses nothing.
@immutable
sealed class LogRecord {
  const LogRecord();
}

/// One journal entry from `journalctl -o json` (LOG-01 to LOG-03, SVC-04).
/// The engine reads its columns once; a value the host sent that does not
/// fit its column, such as a time beyond [DateTime]'s range or a priority
/// outside 0 to 7, is null, as a missing one is.
final class JournalRecord extends LogRecord {
  const JournalRecord({
    this.cursor,
    this.at,
    this.priority,
    this.unit,
    this.identifier,
    this.pid,
    this.message,
    this.fields = const {},
  });

  /// `__CURSOR`, which [LogStreamSpec.afterCursor] continues after.
  final String? cursor;

  /// `__REALTIME_TIMESTAMP`: when journald received the entry, by the
  /// host's clock.
  final DateTime? at;

  /// `PRIORITY`.
  final LogPriority? priority;

  /// `_SYSTEMD_UNIT`, or `_SYSTEMD_USER_UNIT` or `UNIT` without one.
  final String? unit;

  /// `SYSLOG_IDENTIFIER`.
  final String? identifier;

  /// `_PID`, when it is a positive number.
  final int? pid;

  /// `MESSAGE`; null when the entry has none or journalctl sent it as
  /// null, which `-o json` does for a field over 4,096 bytes unless it
  /// runs with `--all`.
  final String? message;

  /// Every field as `klabautermann_host`'s journal parser decoded it, the
  /// ones above included, for the row's expandable fields (03 §10.8); null
  /// where journalctl sent null. Pass an unmodifiable map.
  final Map<String, String?> fields;
}

/// One kernel ring-buffer record from `dmesg --json --decode`, LOG-03's
/// fallback.
final class KernelRecord extends LogRecord {
  const KernelRecord({required this.message, this.sinceBoot, this.priority});

  /// `msg`.
  final String message;

  /// `time`: how long after boot the kernel logged it.
  final Duration? sinceBoot;

  /// The level that `pri` names; null when dmesg sent no level name.
  final LogPriority? priority;
}

/// One line of a tailed file (LOG-22), without its line break.
final class FileRecord extends LogRecord {
  const FileRecord(this.text);

  final String text;
}

/// One line of a container's log (CTX-01), as the engine assembled it
/// from the API's frames (03 §5.6): a line the engine split across
/// frames arrives whole, without its line break.
final class ContainerRecord extends LogRecord {
  const ContainerRecord({required this.stream, required this.text, this.at});

  final ContainerLogStream stream;

  /// When the engine received the line, by the daemon's clock, to the
  /// microsecond; null when the line carried no timestamp.
  final DateTime? at;
  final String text;
}

/// The container stream a [ContainerRecord] came from. A TTY container
/// has one stream, read as [stdout].
enum ContainerLogStream { stdout, stderr }

/// A log stream's state behind [LogStreamState]. Compares by value, as
/// [LinkStatus] does, because a status that crosses the boundary may
/// arrive as a copy.
@immutable
sealed class LogStreamStatus {
  const LogStreamStatus();

  /// The values that tell two statuses of one variant apart.
  List<Object?> get _values => const [];

  @override
  bool operator ==(Object other) =>
      other is LogStreamStatus &&
      other.runtimeType == runtimeType &&
      sameItems(other._values, _values);

  @override
  int get hashCode => Object.hash(runtimeType, Object.hashAll(_values));
}

/// The read waits for [reason] to clear, then runs on its own: a window
/// starts, and a follow starts or resumes after its last record.
final class LogStreamWaiting extends LogStreamStatus {
  const LogStreamWaiting(this.reason);

  final LogStreamWaitReason reason;

  @override
  List<Object?> get _values => [reason];
}

/// The read runs on the host: a window until it ends, a follow live.
/// [reader] says which of its source's readers serves it, so the view can
/// name where a kernel log came from (LOG-03), and [continuity] whether a
/// follow that waited may lack records written meanwhile (LOG-02).
final class LogStreamRunning extends LogStreamStatus {
  const LogStreamRunning({
    this.reader = LogReader.primary,
    this.continuity = LogContinuity.complete,
  });

  final LogReader reader;
  final LogContinuity continuity;

  @override
  List<Object?> get _values => [reader, continuity];
}

/// Whether a running stream holds every record since it opened (03 §7.6).
enum LogContinuity {
  /// Every record arrived or was counted in a [LogBatch.dropped]: a
  /// window, a follow on its first run, or one that resumed after its
  /// newest journal cursor.
  complete,

  /// A follow without a cursor to resume after, such as a file's `tail
  /// -F`, started again after it waited and delivers only new records:
  /// records written while it waited may be missing, uncounted.
  gap,
}

/// Which reader a [LogStreamRunning] stream reads with (03 §7.6).
enum LogReader {
  /// The source's own: `journalctl` for the journal and the kernel log,
  /// `tail` for a file.
  primary,

  /// The kernel log's fallback, `dmesg --json --decode`, read as
  /// [KernelRecord]s when `journalctl -k -b` gives no kernel record.
  fallback,
}

/// The stream ended for [reason], and nothing more arrives for it.
/// [detail] is the host's error output when the host ended it, control
/// characters stripped, the daemon's message for a container's logs, the
/// driver's name for [LogStreamEndReason.logDriverUnreadable], or null.
final class LogStreamEnded extends LogStreamStatus {
  const LogStreamEnded(this.reason, {this.detail});

  final LogStreamEndReason reason;
  final String? detail;

  @override
  List<Object?> get _values => [reason, detail];
}

/// What a [LogStreamWaiting] stream waits for.
enum LogStreamWaitReason {
  /// The server's link; [LinkState] says why it is not ready. Container
  /// logs also wait here for the Docker endpoint over it, which
  /// [DockerEndpointState] reports.
  link,

  /// A free session channel: reads of its kind already hold their share
  /// of the budget (03 §5.2), or the server allows fewer sessions than
  /// the budget ([LinkDegraded]).
  channel,

  /// The app's return to the foreground ([SetAppActivity]): 03 §6.4
  /// pauses everything while it is in the background.
  background,
}

/// Why a [LogStreamEnded] stream ended.
enum LogStreamEndReason {
  /// A window delivered [LogStreamSpec.window] records, or fewer when the
  /// engine's output cap for the read stopped it first. Older records may
  /// remain; a journal window after the last record's cursor reads on.
  windowFilled,

  /// A window reached the oldest record its source holds within its
  /// filters: nothing older remains.
  oldestReached,

  /// [CloseStream] closed it.
  closed,

  /// The engine refused the spec without running anything, such as a
  /// unit name or path its validation rejects (03 §8.8).
  invalid,

  /// The tool, file or container the source reads is absent on the
  /// host.
  missing,

  /// The host refused the read, such as a file only `adm` or root may
  /// read; with admin mode on, an elevated [FileLogSource] reads it.
  denied,

  /// The read failed otherwise.
  failed,

  /// The container's logging driver keeps no logs the API can read (03
  /// §7.12 CTX-01): `none`, or a remote driver with Docker's dual-logging
  /// cache disabled, or on Podman, which has no such cache, any but
  /// `k8s-file`, `json-file` and `journald`. [LogStreamEnded.detail] names the driver.
  logDriverUnreadable,

  /// The host's journalctl cannot match a [JournalLogSource.grep]
  /// pattern: it was built without PCRE2, or cannot load it (LOG-06).
  /// The view's own search (LOG-05) still works.
  searchUnsupported,
}
