// The device audit log (03 §8.10, SAF-11; M4 plan M12): one append-only
// JSONL file per server under the support directory's `audit/`, a record
// per finished run, steps redacted. Records older than 90 days [E] are
// pruned at engine start. Like the engine's other files it is written
// only while this process has the support directory to itself (03 §4.10);
// otherwise the log lives in memory for this run. Not synced (D28).
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:seance_core/seance_core.dart' show SecretRedactor;

import '../engine/protocol.dart';
import '../fleet/server_file_stem.dart';
import '../operations/operation_runner.dart' show OperationResult;
import '../settings/device_settings_store.dart'
    show unusedCorruptCopyPath, writeFileAtomically;

/// How long records stay [E] (03 §8.10).
const kAuditRetention = Duration(days: 90);

/// The audit log's directory under the support directory (03 §4.10).
const auditDirectoryName = 'audit';

/// The record format's version, bumped when a field changes meaning.
const _auditVersion = 1;

const _newline = 0x0A;

/// One line of a log file as read: [text] without its newline, and its
/// [record], which is null for a line a newer record version wrote. Such
/// a line is kept as it is and never answered.
typedef _Line = ({String text, AuditRecord? record});

/// Where the log keeps its records.
enum AuditStorage {
  /// `audit/<server>.jsonl`, appended per record.
  files,

  /// This process's memory: another instance may write the support
  /// directory.
  memory,
}

/// The device audit log.
final class AuditLog {
  AuditLog(
    this._directory, {
    required this.storage,
    this._deviceId,
    SecretRedactor? redactor,
    DateTime Function()? now,
  }) : _redactor = redactor ?? SecretRedactor(),
       _now = now ?? DateTime.now;

  final Directory _directory;
  final AuditStorage storage;
  final String? _deviceId;
  final SecretRedactor _redactor;
  final DateTime Function() _now;
  final Map<String, List<AuditRecord>> _memory = {};

  // File operations run one after another ([_inTurn]), so lines never
  // interleave and a rewrite never drops an append.
  Future<void> _tail = Future.value();

  /// The record of [result], redacted, appended to its server's log.
  Future<void> recordRun(OperationResult result) {
    final plan = result.plan;
    final finished = result.finished;
    return append(
      AuditRecord(
        serverId: plan.intent.serverId,
        action: '${plan.intent.runtimeType}',
        targetName: plan.targetName,
        steps: [for (final step in plan.steps) _redactor.redact(step.display)],
        tier: plan.tier,
        outcome: finished.outcome,
        startedAt: result.startedAt,
        endedAt: result.endedAt,
        deviceId: _deviceId,
        failure: finished.failure,
        failedStep: finished.failedStep,
        exitCode: finished.exitCode,
        httpStatus: finished.httpStatus,
        skippedSteps: finished.skippedSteps,
      ),
    );
  }

  /// Appends [record]. A file that cannot be written loses this record
  /// only; the failure propagates to the caller.
  Future<void> append(AuditRecord record) {
    final file = _fileOf(record.serverId);
    if (storage == AuditStorage.memory || file == null) {
      (_memory[record.serverId] ??= []).add(record);
      return Future.value();
    }
    return _inTurn(() async {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(_encode(record))}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
  }

  /// A page of [serverId]'s records: at most [limit] from [after] on, in
  /// end order, newest first, and records that ended together newest
  /// append first; and the cursor of the next page, null when none
  /// remain. A file that cannot be read is [unreadable]: the answer then
  /// holds only this run's memory.
  Future<({List<AuditRecord> records, AuditCursor? next, bool unreadable})>
  query(String serverId, {AuditCursor? after, int limit = 100}) async {
    final file = _fileOf(serverId);
    var unreadable = false;
    final stored = <AuditRecord>[];
    if (storage == AuditStorage.files && file != null) {
      try {
        stored.addAll(_recordsOf(await _inTurn(() => _read(file))));
      } on FileSystemException {
        unreadable = true;
      }
    }
    final all = [...stored, ...?_memory[serverId]];
    // Appends are not in end order (see AuditCursor), so the log is
    // sorted; the append index orders records that ended together.
    final ordered =
        [for (var i = 0; i < all.length; i++) (index: i, record: all[i])]
          ..sort((a, b) {
            final byEnd = b.record.endedAt.compareTo(a.record.endedAt);
            return byEnd != 0 ? byEnd : b.index.compareTo(a.index);
          });
    bool endsAt(int i, DateTime at) =>
        ordered[i].record.endedAt.isAtSameMomentAs(at);

    var start = 0;
    if (after != null) {
      while (start < ordered.length &&
          ordered[start].record.endedAt.isAfter(after.endedAt)) {
        start++;
      }
      for (var tied = 0; tied < after.seen; tied++) {
        if (start == ordered.length || !endsAt(start, after.endedAt)) break;
        start++;
      }
    }
    final end = min(start + limit, ordered.length);
    AuditCursor? next;
    if (end < ordered.length) {
      // Counted from the first record that ended with the page's last,
      // which may be on an earlier page.
      final last = ordered[end - 1].record.endedAt;
      var seen = 0;
      while (seen < end && endsAt(end - 1 - seen, last)) {
        seen++;
      }
      next = AuditCursor(last, seen: seen);
    }
    return (
      records: [for (var i = start; i < end; i++) ordered[i].record],
      next: next,
      unreadable: unreadable,
    );
  }

  /// Drops records older than [kAuditRetention] from every file, at
  /// engine start. Memory starts empty, so it has nothing to prune.
  Future<void> prune() async {
    if (storage == AuditStorage.memory) return;
    await _inTurn(_prune);
  }

  Future<void> _prune() async {
    if (!await _directory.exists()) return;
    final cutoff = _now().subtract(kAuditRetention);
    await for (final entity in _directory.list()) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      final lines = await _read(entity);
      // A newer build's line is its own to prune.
      final kept = [
        for (final line in lines)
          if (line.record?.endedAt.isBefore(cutoff) != true) line,
      ];
      if (kept.length == lines.length) continue;
      await _rewrite(entity, kept);
    }
  }

  /// Runs [operation] after every file operation asked for before it.
  /// A read rewrites a damaged file and a prune rewrites old records
  /// away, so neither may overlap an append whose line it would drop.
  Future<T> _inTurn<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// [serverId]'s log file, or null when the id names no per-server
  /// file (03 §4.10): such a server's records stay in memory.
  File? _fileOf(String serverId) => switch (serverFileStem(serverId)) {
    final stem? => File(
      '${_directory.path}${Platform.pathSeparator}$stem.jsonl',
    ),
    null => null,
  };

  /// The lines of [file]. A line that does not decode, whether its bytes
  /// are not UTF-8 (an append torn inside a character) or its text is not
  /// a record, marks the file damaged: it is copied aside
  /// (`.corrupt-<time>`) and rewritten with the lines that do, so one bad
  /// write never hides the rest. A failure to read the file propagates.
  Future<List<_Line>> _read(File file) async {
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on PathNotFoundException {
      return [];
    }
    final lines = <_Line>[];
    var damaged = false;
    var start = 0;
    while (start < bytes.length) {
      var end = bytes.indexOf(_newline, start);
      if (end < 0) end = bytes.length;
      final line = bytes.sublist(start, end);
      start = end + 1;
      if (line.isEmpty) continue;
      switch (_lineOf(line)) {
        case final read?:
          lines.add(read);
        case null:
          damaged = true;
      }
    }
    if (damaged) {
      // The lines read are answered even when the file cannot be healed
      // now, say on a full disk; the next read tries again.
      try {
        await file.copy(await unusedCorruptCopyPath(file, _now()));
        await _rewrite(file, lines);
      } on FileSystemException {
        // Healed by a later read.
      }
    }
    return lines;
  }

  static List<AuditRecord> _recordsOf(List<_Line> lines) => [
    for (final line in lines) ?line.record,
  ];

  /// Rewrites [file] with [lines] as they were read, so a newer build's
  /// lines survive byte for byte.
  Future<void> _rewrite(File file, List<_Line> lines) => writeFileAtomically(
    file,
    utf8.encode(lines.map((line) => '${line.text}\n').join()),
  );

  /// The line [bytes] hold, or null when they are damaged.
  static _Line? _lineOf(List<int> bytes) {
    final String text;
    final Object? json;
    try {
      text = utf8.decode(bytes);
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json case {'v': final int v} when v > _auditVersion) {
      return (text: text, record: null);
    }
    return switch (_decode(json)) {
      final record? => (text: text, record: record),
      null => null,
    };
  }

  static Map<String, Object?> _encode(AuditRecord r) => {
    'v': _auditVersion,
    'serverId': r.serverId,
    'action': r.action,
    'target': r.targetName,
    'steps': r.steps,
    'tier': r.tier.name,
    'outcome': r.outcome.name,
    'startedAt': r.startedAt.toUtc().toIso8601String(),
    'endedAt': r.endedAt.toUtc().toIso8601String(),
    'deviceId': ?r.deviceId,
    'failure': ?r.failure?.name,
    'failedStep': ?r.failedStep,
    'exit': ?r.exitCode,
    'http': ?r.httpStatus,
    if (r.skippedSteps.isNotEmpty) 'skipped': r.skippedSteps,
  };

  static AuditRecord? _decode(Object? json) {
    try {
      if (json is! Map<String, Object?> || json['v'] != _auditVersion) {
        return null;
      }
      final failure = json['failure'];
      return AuditRecord(
        serverId: json['serverId']! as String,
        action: json['action']! as String,
        targetName: json['target']! as String,
        steps: [for (final step in json['steps']! as List) step as String],
        tier: ConfirmationTier.values.byName(json['tier']! as String),
        outcome: ActionOutcome.values.byName(json['outcome']! as String),
        startedAt: DateTime.parse(json['startedAt']! as String),
        endedAt: DateTime.parse(json['endedAt']! as String),
        deviceId: json['deviceId'] as String?,
        failure: failure == null
            ? null
            : ActionFailure.values.byName(failure as String),
        failedStep: json['failedStep'] as int?,
        exitCode: json['exit'] as int?,
        httpStatus: json['http'] as int?,
        skippedSteps: [
          for (final step in json['skipped'] as List? ?? const []) step as int,
        ],
      );
    } on Object {
      return null;
    }
  }
}
