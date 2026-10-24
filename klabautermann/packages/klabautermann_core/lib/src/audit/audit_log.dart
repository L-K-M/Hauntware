// The device audit log (03 §8.10, SAF-11; M4 plan M12): one append-only
// JSONL file per server under the support directory's `audit/`, a record
// per finished run, steps redacted. Records older than 90 days [E] are
// pruned at engine start. Like the engine's other files it is written
// only while this process has the support directory to itself (03 §4.10);
// otherwise the log lives in memory for this run. Not synced (D28).
import 'dart:convert';
import 'dart:io';

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

  /// [serverId]'s records that ended before [before], newest first, at
  /// most [limit], and whether older ones remain.
  Future<({List<AuditRecord> records, bool more})> query(
    String serverId, {
    DateTime? before,
    int limit = 100,
  }) async {
    final file = _fileOf(serverId);
    final all = [
      if (storage == AuditStorage.files && file != null)
        ...await _inTurn(() => _read(file)),
      ...?_memory[serverId],
    ];
    final matching = [
      for (final record in all.reversed)
        if (before == null || record.endedAt.isBefore(before)) record,
    ];
    return (
      records: matching.take(limit).toList(),
      more: matching.length > limit,
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
      final records = await _read(entity);
      final kept = [
        for (final record in records)
          if (!record.endedAt.isBefore(cutoff)) record,
      ];
      if (kept.length == records.length) continue;
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

  /// The records of [file]. A line that does not decode marks the file
  /// damaged: it is copied aside (`.corrupt-<time>`) and rewritten with
  /// the lines that do, so one bad write never hides the rest.
  Future<List<AuditRecord>> _read(File file) async {
    if (!await file.exists()) return [];
    final records = <AuditRecord>[];
    var damaged = false;
    for (final line in const LineSplitter().convert(
      await file.readAsString(),
    )) {
      if (line.isEmpty) continue;
      final record = _decode(line);
      if (record == null) {
        damaged = true;
      } else {
        records.add(record);
      }
    }
    if (damaged) {
      await file.copy(await unusedCorruptCopyPath(file, _now()));
      await _rewrite(file, records);
    }
    return records;
  }

  Future<void> _rewrite(File file, List<AuditRecord> records) =>
      writeFileAtomically(
        file,
        utf8.encode(records.map((r) => '${jsonEncode(_encode(r))}\n').join()),
      );

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

  static AuditRecord? _decode(String line) {
    try {
      final json = jsonDecode(line);
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
