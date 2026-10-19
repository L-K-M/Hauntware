/// Parser for the `ops` collector (03 §7.17): the detached-operation
/// records of the login user's and the root-owned operation directory,
/// which re-attach reads on connect.
///
/// The payload is two listings, one per directory, in the framing the
/// fragment's doc comment gives: `rec <kind> <id> <status> <bytes>`
/// lines each followed by exactly `<bytes>` bytes of the record and a
/// newline, then one `dir <kind> <state> <count> <path>` line. The byte
/// counts are trusted only up to [kOpsRecordBytes]; a count past the cap
/// or past the payload, or a record not followed by its newline, ends the
/// parse with a warning, because nothing after it can be framed again.
///
/// A record is the one-line JSON object the operation wrapper of E08
/// (`commands/operations.dart`) writes with `printf` to `<id>.json`,
/// through `.<id>.tmp` and `mv -f`, with every key present:
///
///     {"v":1,"id":"<id>","state":"running"|"done","pid":<pid>,
///      "startTicks":<ticks>|null,"unit":"klabautermann-op-<id>.service"|null,
///      "exit":<0-255>|null,"startedAt":<epoch s>|null,
///      "endedAt":<epoch s>|null}
///
/// `pid` is the wrapper shell's `$$` and `startTicks` field 22 of its
/// `/proc/<pid>/stat` (null when unreadable), so a PID the kernel reused
/// tells apart. `unit` is null for the `setsid` runner rows. `exit` and
/// `endedAt` are null while running; `exit` is set once done. The times
/// come from `date +%s` and are null where it has no `%s`. Unknown keys
/// are ignored; a missing one is malformed. The file name is the record's
/// identity: a record whose `id` differs from it, or whose `unit` names
/// another unit, is rejected as forged, never read as the operation it
/// claims to be.
///
/// The key names and the version below repeat E08's `OpRecordField`,
/// `OpRecordState` and `kOpRecordVersion`, privately, until both land and
/// share them.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../hws/program.dart' show kOpsRecordBytes, kTimeoutAbsentMarker;
import 'parse_result.dart';

/// The record format version this parser reads (E08's
/// `kOpRecordVersion`).
const _kVersion = 1;

/// The record's keys (E08's `OpRecordField`), all always present.
const _kVersionKey = 'v';
const _kIdKey = 'id';
const _kStateKey = 'state';
const _kPidKey = 'pid';
const _kStartTicksKey = 'startTicks';
const _kUnitKey = 'unit';
const _kExitKey = 'exit';
const _kStartedAtKey = 'startedAt';
const _kEndedAtKey = 'endedAt';
const _kKeys = [
  _kVersionKey,
  _kIdKey,
  _kStateKey,
  _kPidKey,
  _kStartTicksKey,
  _kUnitKey,
  _kExitKey,
  _kStartedAtKey,
  _kEndedAtKey,
];

/// Which operation directory a listing or record comes from (03 §7.17).
enum OpDirectoryKind {
  /// `${XDG_STATE_HOME:-~/.local/state}/klabautermann/ops/`, 0700.
  user,

  /// `/var/lib/klabautermann/ops/`, root-owned 0755.
  root,
}

/// What listing an operation directory found.
enum OpDirectoryState {
  /// The directory was listed to the end.
  ok,

  /// The directory does not exist: no operation has used it.
  absent,

  /// The directory exists but is not a directory the user can list.
  denied,

  /// The listing has no `dir` line: its timeout or a framing error cut it
  /// short, so records may be missing.
  incomplete,
}

/// One directory's listing.
@immutable
final class OpDirectoryListing {
  const OpDirectoryListing({
    required this.state,
    this.path,
    this.count,
    this.listed = 0,
  });

  /// Whether the listing reached its end.
  final OpDirectoryState state;

  /// The directory the host resolved; null when the listing is
  /// [OpDirectoryState.incomplete]. The user directory's path is the one a
  /// launch passes to the wrapper (03 §7.17).
  final String? path;

  /// The well-named records the directory holds; null when incomplete.
  final int? count;

  /// The records the listing sent, read or rejected.
  final int listed;

  /// Whether the directory holds more records than the collector sends
  /// (`kOpsRecordCap`).
  bool get capped => count != null && count! > listed;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'path': path,
    'count': count,
    'listed': listed,
  };
}

/// A record's state (03 §7.17): the wrapper writes `running` before the
/// command starts and `done` after it ends.
enum OpState { running, done }

/// One detached operation's record.
@immutable
final class OpRecord {
  const OpRecord({
    required this.directory,
    required this.id,
    required this.state,
    required this.pid,
    this.startTicks,
    this.startedAt,
    this.unit,
    this.exitCode,
    this.endedAt,
  }) : assert(
         (state == OpState.done) == (exitCode != null),
         'exitCode is set exactly for done records',
       ),
       assert(
         state == OpState.done || endedAt == null,
         'a running record has no end time',
       );

  /// The directory the record was read from.
  final OpDirectoryKind directory;

  /// The operation id, 16 lowercase hex digits, equal to the file name.
  final String id;

  final OpState state;

  /// The wrapper's PID.
  final int pid;

  /// Field 22 of the wrapper's `/proc/<pid>/stat`: its start time in clock
  /// ticks after boot, which tells a reused PID apart; null when the
  /// wrapper could not read it.
  final int? startTicks;

  /// `klabautermann-op-<id>.service` for a systemd runner; null for a
  /// `setsid` one.
  final String? unit;

  /// The command's exit status, 0 to 255; set exactly when [state] is
  /// [OpState.done].
  final int? exitCode;

  /// When the command started, UTC; null where the host's `date` has no
  /// `%s`.
  final DateTime? startedAt;

  /// When the command ended, UTC; null while running and where the host's
  /// `date` has no `%s`.
  final DateTime? endedAt;

  Map<String, Object?> toJson() => {
    'directory': directory.name,
    'id': id,
    'state': state.name,
    'pid': pid,
    'startTicks': startTicks,
    'unit': unit,
    'exitCode': exitCode,
    'startedAt': startedAt?.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
  };
}

/// Why a listed record was not read.
enum OpRejection {
  /// The file is longer than [kOpsRecordBytes]; the wrapper never writes
  /// one that long.
  truncated,

  /// The file is not readable to the login user.
  denied,

  /// Reading the file failed.
  unreadable,

  /// Not a record of this format: not UTF-8 JSON, a field missing or of
  /// the wrong type or range, or an unknown state.
  malformed,

  /// A record of another format version.
  unsupportedVersion,

  /// The record's `id` differs from its file name, or its `unit` names a
  /// unit other than `klabautermann-op-<id>.service`.
  forged,
}

/// A listed record that was not read, with the file name's id.
@immutable
final class OpRejected {
  const OpRejected(this.directory, this.id, this.reason);

  final OpDirectoryKind directory;
  final String id;
  final OpRejection reason;

  Map<String, Object?> toJson() => {
    'directory': directory.name,
    'id': id,
    'reason': reason.name,
  };
}

/// Both directories' listings and their records.
@immutable
final class OpsListing {
  OpsListing({
    required Map<OpDirectoryKind, OpDirectoryListing> directories,
    required List<OpRecord> records,
    required List<OpRejected> rejected,
  }) : directories = Map.unmodifiable(directories),
       records = List.unmodifiable(records),
       rejected = List.unmodifiable(rejected);

  /// Every [OpDirectoryKind], each with its listing.
  final Map<OpDirectoryKind, OpDirectoryListing> directories;

  /// The records read, in payload order.
  final List<OpRecord> records;

  /// The listed records that were not read, in payload order.
  final List<OpRejected> rejected;

  Map<String, Object?> toJson() => {
    'directories': {
      for (final k in OpDirectoryKind.values) k.name: directories[k]!.toJson(),
    },
    'records': [for (final r in records) r.toJson()],
    'rejected': [for (final r in rejected) r.toJson()],
  };
}

final _idPattern = RegExp(r'^[0-9a-f]{16}$');

/// The kernel's PID ceiling (`PID_MAX_LIMIT` on 64-bit, 2^22).
const _pidMax = 1 << 22;

/// Seconds after the epoch that `DateTime` still represents.
const _epochMax = 8640000000000;

/// Parses an `ops` payload; never throws.
ParseResult<OpsListing> parseOps(List<int> payload) {
  final warnings = <String>[];
  final dirs = <OpDirectoryKind, OpDirectoryListing>{};
  final listed = {for (final k in OpDirectoryKind.values) k: 0};
  final records = <OpRecord>[];
  final rejected = <OpRejected>[];

  var at = 0;
  while (at < payload.length) {
    var nl = payload.indexOf(0x0a, at);
    if (nl < 0) nl = payload.length;
    final line = latin1.decode(payload.sublist(at, nl));
    at = nl + 1;

    if (line.isEmpty || line == kTimeoutAbsentMarker) continue;

    if (line.startsWith('dir ')) {
      final dir = _dirLine(line);
      if (dir == null) {
        warnings.add('ops: malformed dir line');
        continue;
      }
      dirs[dir.$1] = dir.$2;
      continue;
    }

    if (!line.startsWith('rec ')) {
      warnings.add('ops: unexpected line ignored');
      continue;
    }

    final head = _recLine(line);
    if (head == null) {
      warnings.add('ops: malformed rec line; the rest is unframed');
      break;
    }
    final (kind, id, status, bytes) = head;
    final end = at + bytes;
    final framed = end < payload.length
        ? payload[end] == 0x0a
        : end == payload.length;
    if (!framed) {
      warnings.add('ops: record $id is not framed; the rest is unframed');
      break;
    }
    final body = payload.sublist(at, end);
    at = end + 1;
    listed[kind] = listed[kind]! + 1;

    final reason = switch (status) {
      'ok' => null,
      'truncated' => OpRejection.truncated,
      'denied' => OpRejection.denied,
      _ => OpRejection.unreadable,
    };
    if (reason != null) {
      rejected.add(OpRejected(kind, id, reason));
      continue;
    }
    switch (_record(kind, id, body)) {
      case final OpRecord r:
        records.add(r);
      case final OpRejection r:
        rejected.add(OpRejected(kind, id, r));
        if (r == OpRejection.unsupportedVersion) {
          warnings.add('ops: record $id has an unknown format version');
        }
    }
  }

  for (final k in OpDirectoryKind.values) {
    final d = dirs[k];
    if (d == null) {
      warnings.add('ops: the ${k.name} listing has no dir line');
      dirs[k] = OpDirectoryListing(
        state: OpDirectoryState.incomplete,
        listed: listed[k]!,
      );
    } else {
      dirs[k] = OpDirectoryListing(
        state: d.state,
        path: d.path,
        count: d.count,
        listed: listed[k]!,
      );
    }
  }
  return ParseResult(
    OpsListing(directories: dirs, records: records, rejected: rejected),
    warnings,
  );
}

/// `dir <kind> <state> <count> <path>`; the path may hold spaces.
(OpDirectoryKind, OpDirectoryListing)? _dirLine(String line) {
  final parts = line.split(' ');
  if (parts.length < 5) return null;

  final kind = _kind(parts[1]);
  final state = switch (parts[2]) {
    'ok' => OpDirectoryState.ok,
    'absent' => OpDirectoryState.absent,
    'denied' => OpDirectoryState.denied,
    _ => null,
  };
  final count = _uint(parts[3]);
  final path = parts.sublist(4).join(' ');
  if (kind == null || state == null || count == null || path.isEmpty) {
    return null;
  }
  return (kind, OpDirectoryListing(state: state, path: path, count: count));
}

/// `rec <kind> <id> <status> <bytes>`.
(OpDirectoryKind, String, String, int)? _recLine(String line) {
  final parts = line.split(' ');
  if (parts.length != 5) return null;

  final kind = _kind(parts[1]);
  final id = parts[2];
  final status = parts[3];
  final bytes = _uint(parts[4]);
  const statuses = {'ok', 'truncated', 'denied', 'error'};
  if (kind == null ||
      !_idPattern.hasMatch(id) ||
      !statuses.contains(status) ||
      bytes == null ||
      bytes > kOpsRecordBytes) {
    return null;
  }
  return (kind, id, status, bytes);
}

OpDirectoryKind? _kind(String name) => switch (name) {
  'user' => OpDirectoryKind.user,
  'root' => OpDirectoryKind.root,
  _ => null,
};

int? _uint(String s) {
  if (s.isEmpty || s.length > 18) return null;
  for (final c in s.codeUnits) {
    if (c < 0x30 || c > 0x39) return null;
  }
  return int.parse(s);
}

/// The record in [body], or why it is rejected.
Object _record(OpDirectoryKind kind, String id, List<int> body) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(body));
  } on FormatException {
    return OpRejection.malformed;
  }
  if (json is! Map<String, Object?>) return OpRejection.malformed;

  final version = json[_kVersionKey];
  if (version is! int) return OpRejection.malformed;
  if (version != _kVersion) return OpRejection.unsupportedVersion;
  if (!_kKeys.every(json.containsKey)) return OpRejection.malformed;

  final claimed = json[_kIdKey];
  if (claimed is! String) return OpRejection.malformed;
  if (claimed != id) return OpRejection.forged;

  final unit = json[_kUnitKey];
  if (unit != null && unit is! String) return OpRejection.malformed;
  if (unit != null && unit != 'klabautermann-op-$id.service') {
    return OpRejection.forged;
  }

  final state = switch (json[_kStateKey]) {
    'running' => OpState.running,
    'done' => OpState.done,
    _ => null,
  };
  final pid = _int(json[_kPidKey], 2, _pidMax);
  if (state == null || pid == null) return OpRejection.malformed;

  final (startTicks, ticksOk) = _nullable(json[_kStartTicksKey], _ticks);
  final (startedAt, startOk) = _nullable(json[_kStartedAtKey], _time);
  final (endedAt, endOk) = _nullable(json[_kEndedAtKey], _time);
  final (exitCode, exitOk) = _nullable(json[_kExitKey], _exit);
  if (!ticksOk || !startOk || !endOk || !exitOk) return OpRejection.malformed;

  final consistent = switch (state) {
    OpState.running => exitCode == null && endedAt == null,
    OpState.done => exitCode != null,
  };
  if (!consistent) return OpRejection.malformed;

  return OpRecord(
    directory: kind,
    id: id,
    state: state,
    pid: pid,
    startTicks: startTicks,
    unit: unit as String?,
    exitCode: exitCode,
    startedAt: startedAt,
    endedAt: endedAt,
  );
}

/// [v] read by [read]: null stays null, and anything [read] refuses is
/// reported as not ok.
(T?, bool) _nullable<T>(Object? v, T? Function(Object?) read) {
  if (v == null) return (null, true);
  final value = read(v);
  return (value, value != null);
}

int? _ticks(Object? v) => _int(v, 0, null);

int? _exit(Object? v) => _int(v, 0, 255);

int? _int(Object? v, int min, int? max) {
  if (v is! int || v < min || (max != null && v > max)) return null;
  return v;
}

DateTime? _time(Object? v) => switch (_int(v, 0, _epochMax)) {
  final s? => DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true),
  null => null,
};
