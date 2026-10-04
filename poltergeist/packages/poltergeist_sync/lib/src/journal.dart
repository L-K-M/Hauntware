// The run journal (05 §8 rail 9): one JSONL file per run at
// `<app-support>/sync_runs/<runId>.jsonl`. A `SyncRunRecord` header line,
// one line per executed item, one `trash` line per file a rule-4
// pre-delete removed, one `rmdir` line per emptied directory, one
// `remove` line per permanent file deletion, a summary line, and the
// `purged` marker rail 5's purge stamps. Every append flushes
// immediately — no userspace buffering — so a killed process loses at
// most the line it was mid-writing; replay drops a torn final line
// (03 §4.6's recovery pattern). The journal is the package's one
// legitimate `dart:io` user (05 §11): the JSONL file under app-support
// is local-disk bookkeeping, while every sync filesystem operation
// flows through the two injected RemoteFileSystems (D3).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'plan.dart';
import 'trash_root.dart';

/// Base schema version. Replay also accepts the fail-closed restore records
/// declared below and rejects every other version.
const int syncJournalSchemaVersion = 1;

// Restore transactions are v2 lines inside an otherwise-v1 journal. An older
// reader refuses the journal after a staged mutation instead of replaying it
// without the recovery state.
const int _replaceRestoreJournalSchemaVersion = 2;
const int _replaceRestoreIdBytes = 16;
const int _replaceRestoreStageAttempts = 3;
const String _currentDirectorySegment = '.';
const String _parentDirectorySegment = '..';
const String _slashUncPrefix = '//';
const String _windowsUncPrefix = r'\\';
const String _replaceRestoreStagePrefix = '.poltergeist-restore-';
const String _replaceRestorePreparedType = 'replaceRestorePrepared';
const String _replaceRestoreStartedType = 'replaceRestoreStarted';
const String _replaceRestoreStagedType = 'replaceRestoreStaged';
const String _replaceRestoreEntryType = 'replaceRestoreEntry';
const String _replaceRestoreChildrenType = 'replaceRestoreChildren';
const String _replaceRestoreCompleteType = 'replaceRestoreComplete';
final RegExp _replaceRestoreIdPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
const Set<String> _replaceRestoreRecordTypes = {
  _replaceRestorePreparedType,
  _replaceRestoreStartedType,
  _replaceRestoreStagedType,
  _replaceRestoreEntryType,
  _replaceRestoreChildrenType,
  _replaceRestoreCompleteType,
};

enum _ReplaceRestoreTransition { staged, childrenRestored, complete }

/// Directory name under app-support (05 §8 rail 9).
const String syncRunsDirectoryName = 'sync_runs';

/// Journals are pruned to the newest [syncJournalRetention] per pair —
/// except a run whose journal records trash entries without a `purged`
/// marker: Undo must never lose its source while the trash it reverses
/// is still there (05 §8 rail 9).
const int syncJournalRetention = 20;

/// One executed-item line. [attempt] starts at 1 and increments on any
/// re-execution of the same (runId, relativePath, side, action) key —
/// `Retry Failed` or crash-resume (05 §11's uniqueness contract).
final class SyncJournalItemLine {
  const SyncJournalItemLine({
    required this.relativePath,
    required this.side,
    required this.action,
    required this.outcome,
    required this.attempt,
    this.bytes = 0,
    this.durationMs = 0,
    this.userOverridden = false,
    this.trashLocation,
    this.trashBytes,
    this.trashContentSha256,
    this.observedMtimeAfterWrite,
    this.setstatIgnored = false,
    this.error,
  });

  final String relativePath;
  final SyncSide side;
  final SyncActionType action;
  final SyncItemStatus outcome;
  final int attempt;
  final int bytes;
  final int durationMs;
  final bool userOverridden;

  /// Where a delete-phase file/symlink went under `deletions: trash`.
  /// Older journals also stored update backups here; new updates write
  /// a separate trash line before starting the replacement.
  final String? trashLocation;

  /// The size of the file that went to [trashLocation] — distinct from
  /// [bytes] on update lines, where [bytes] is the new version's
  /// payload. Restore size-checks the trash entry against this.
  final int? trashBytes;

  /// Only for rail 5's copy-fallback trash entries — the restore path
  /// hash-verifies those (a rename cannot truncate; an interrupted copy
  /// can).
  final String? trashContentSha256;

  /// The destination's mtime re-stat after `setTimes` (whole seconds).
  final int? observedMtimeAfterWrite;
  final bool setstatIgnored;
  final String? error;
}

/// One file backed up before an update or moved by a rule-4 pre-delete.
/// Its recovery mapping survives even if the parent item's later write
/// fails (05 §6 rule 4: one line per removed file under the parent item).
final class SyncJournalTrashLine {
  const SyncJournalTrashLine({
    required this.parentPath,
    required this.relativePath,
    required this.side,
    required this.trashLocation,
    required this.bytes,
    this.trashContentSha256,
  });

  /// The plan item whose backup or removal step produced this line.
  final String parentPath;
  final String relativePath;
  final SyncSide side;
  final String trashLocation;
  final int bytes;
  final String? trashContentSha256;
}

/// One file permanently removed (under `deletions: permanent`, or a
/// rule-4 pre-delete in a Mirror-permanent pair). Recorded so the run
/// history stays complete — there is nothing to restore.
final class SyncJournalRemoveLine {
  const SyncJournalRemoveLine({
    required this.parentPath,
    required this.relativePath,
    required this.side,
    required this.bytes,
  });

  /// The plan item whose removal step produced this line; equal to
  /// [relativePath] for delete-phase items.
  final String parentPath;
  final String relativePath;
  final SyncSide side;
  final int bytes;
}

/// One emptied directory removed during a run — pre-delete trees and
/// delete-phase cleanup alike. The restore path recreates these chains
/// shallowest-first (05 §8 rail 9).
final class SyncJournalRmdirLine {
  const SyncJournalRmdirLine({
    required this.relativePath,
    required this.side,
    required this.parentPath,
  });

  final String relativePath;
  final SyncSide side;

  /// The plan item the removal ran under; equal to [relativePath] for
  /// delete-phase cleanup items.
  final String parentPath;
}

/// The run's closing line.
final class SyncJournalSummary {
  const SyncJournalSummary({
    required this.counts,
    required this.bytesTransferred,
    required this.cancelled,
    required this.mtimeUnreliableLeft,
    required this.mtimeUnreliableRight,
  });

  /// Items per terminal status.
  final Map<SyncItemStatus, int> counts;
  final int bytesTransferred;
  final bool cancelled;

  /// The §4 flags as they stand at run end — the sync_state writer
  /// persists them.
  final bool mtimeUnreliableLeft;
  final bool mtimeUnreliableRight;
}

final class _ReplaceRestoreEntryState {
  const _ReplaceRestoreEntryState({
    required this.transactionId,
    required this.side,
    required this.parentPath,
    required this.relativePath,
    required this.trashLocation,
    required this.bytes,
    required this.sha256,
  });

  final String transactionId;
  final SyncSide side;
  final String parentPath;
  final String relativePath;
  final String trashLocation;
  final int bytes;
  final String sha256;

  String get key => _replaceRestoreEntryKey(relativePath, trashLocation);
}

final class _ReplaceRestoreState {
  _ReplaceRestoreState({
    required this.transactionId,
    required this.side,
    required this.parentPath,
    required Iterable<_ReplaceRestoreEntryState> entries,
  }) : entries = {for (final entry in entries) entry.key: entry};

  final String transactionId;
  final SyncSide side;
  final String parentPath;
  final Map<String, _ReplaceRestoreEntryState> entries;
  final Set<String> restoredEntryKeys = {};
  var staged = false;
  var childrenRestored = false;
  var complete = false;

  String get groupKey => _replaceRestoreGroupKey(side, parentPath);

  bool get _allEntriesRestored =>
      entries.keys.every(restoredEntryKeys.contains);

  bool _replayEntry(String key) {
    if (!staged ||
        childrenRestored ||
        complete ||
        !entries.containsKey(key) ||
        restoredEntryKeys.contains(key)) {
      return false;
    }

    restoredEntryKeys.add(key);
    return true;
  }

  bool _replayTransition(_ReplaceRestoreTransition transition) {
    switch (transition) {
      case _ReplaceRestoreTransition.staged:
        if (staged ||
            childrenRestored ||
            complete ||
            restoredEntryKeys.isNotEmpty) {
          return false;
        }
        staged = true;
      case _ReplaceRestoreTransition.childrenRestored:
        if (!staged || childrenRestored || complete || !_allEntriesRestored) {
          return false;
        }
        childrenRestored = true;
      case _ReplaceRestoreTransition.complete:
        if (!staged || !childrenRestored || complete || !_allEntriesRestored) {
          return false;
        }
        complete = true;
    }

    return true;
  }
}

String _replaceRestoreGroupKey(SyncSide side, String parentPath) =>
    '${side.name}:$parentPath';

String _replaceRestoreEntryKey(String relativePath, String trashLocation) =>
    '$relativePath\u0000$trashLocation';

bool _createsEntry(SyncActionType action) => switch (action) {
  SyncActionType.copyLeftToRight ||
  SyncActionType.copyRightToLeft ||
  SyncActionType.updateLeftToRight ||
  SyncActionType.updateRightToLeft ||
  SyncActionType.makeDirLeft ||
  SyncActionType.makeDirRight => true,
  _ => false,
};

bool _createsDirectory(SyncActionType action) =>
    action == SyncActionType.makeDirLeft ||
    action == SyncActionType.makeDirRight;

/// Work the restore confirmation must disclose before mutating either side.
final class SyncRestoreImpact {
  const SyncRestoreImpact({
    required this.restoredItemCount,
    required this.removedCreatedFileCount,
  });

  /// Original files and directories the restore puts back.
  final int restoredItemCount;

  /// Files this run created that a rule-4 restore must remove.
  final int removedCreatedFileCount;
}

/// Whether a journal contains recovery work that blocks destructive actions.
enum SyncRestoreJournalState { none, incomplete, unreadableRecovery }

/// A journal may own staged restore state but cannot be replayed safely.
final class SyncRestoreJournalUnreadableException implements Exception {
  const SyncRestoreJournalUnreadableException(this.path);

  final String path;

  @override
  String toString() => 'sync restore journal is unreadable: $path';
}

/// Result of looking for restart recovery across pre-probe pair ids.
sealed class SyncIncompleteRestoreLookup {
  const SyncIncompleteRestoreLookup();
}

/// No candidate pair has an incomplete restore.
final class SyncIncompleteRestoreAbsent extends SyncIncompleteRestoreLookup {
  const SyncIncompleteRestoreAbsent();
}

/// A readable incomplete restore can resume.
final class SyncIncompleteRestoreFound extends SyncIncompleteRestoreLookup {
  const SyncIncompleteRestoreFound(this.journals);

  /// Every readable candidate, newest first. Endpoint/root binding decides
  /// which journal belongs to the current pair before any restore resumes.
  final List<SyncRunJournal> journals;
}

/// A candidate pair owns recovery state that cannot be replayed safely.
final class SyncIncompleteRestoreBlocked extends SyncIncompleteRestoreLookup {
  const SyncIncompleteRestoreBlocked({
    required this.journalPath,
    required this.pairId,
  });

  final String journalPath;
  final String pairId;
}

final class SyncIncompleteRestoreOverlap {
  const SyncIncompleteRestoreOverlap({
    required this.runId,
    required this.pairId,
    required this.journalPath,
    required this.journalState,
  });

  final String runId;
  final String? pairId;
  final String journalPath;

  /// Whether ordinary replay can safely open the recovery journal.
  final SyncRestoreJournalState journalState;
}

/// One parsed JSONL run journal: the append target during a run and the
/// replay source for the report, `Retry Failed`, and
/// `Restore Trashed Files…`.
final class SyncRunJournal {
  SyncRunJournal._(this.path, this.record);

  /// Absolute path of the JSONL file.
  final String path;

  /// The header line's record.
  final SyncRunRecord record;

  final List<SyncJournalItemLine> items = [];
  final List<SyncJournalTrashLine> trashLines = [];
  final List<SyncJournalRemoveLine> removeLines = [];
  final List<SyncJournalRmdirLine> rmdirLines = [];
  SyncJournalSummary? summary;

  var _legacyPurged = false;
  final Set<String> _purgedTrashScopes = {};
  final Map<String, Map<String, _ReplaceRestoreEntryState>>
  _replaceRestorePreparations = {};
  final Map<String, _ReplaceRestoreState> _replaceRestoresById = {};
  final Map<String, String> _replaceRestoreIdsByGroup = {};

  /// Whether every root carrying this journal's trash has been purged.
  /// Legacy markers without a root retain their original run-wide meaning.
  bool get purged {
    if (_legacyPurged) return true;
    final scopes = _recordedTrashScopes;
    return scopes.isNotEmpty && scopes.every(_purgedTrashScopes.contains);
  }

  /// Any purge marker forbids retry from appending new trash behind an
  /// already-purged root marker in the same journal.
  bool get hasPurgeMarker => _legacyPurged || _purgedTrashScopes.isNotEmpty;

  /// Whether a durable rule-4 restore started but has not completed.
  bool get hasIncompleteRestore =>
      _replaceRestoresById.values.any((state) => !state.complete);

  /// Remaining journaled work offered by `Restore Trashed Files…`.
  bool get hasRestorableChanges {
    if (hasIncompleteRestore) return true;

    final impact = restoreImpact;
    return impact.restoredItemCount > 0 || impact.removedCreatedFileCount > 0;
  }

  /// Counts the original items restored and run-created files removed.
  SyncRestoreImpact get restoreImpact {
    final created = <String, SyncJournalItemLine>{};
    for (final line in items) {
      if (line.outcome != SyncItemStatus.done || !_createsEntry(line.action)) {
        continue;
      }
      created[_replaceRestoreGroupKey(line.side, line.relativePath)] = line;
    }

    final restoredItems = <String>{};
    final replaceGroups = <String>{};

    void countTrash(
      SyncSide side,
      String relativePath,
      String parentPath,
      String trashLocation,
    ) {
      if (isTrashEntryPurged(side, trashLocation)) return;

      final state = _replaceRestoreFor(side, parentPath);
      final entryKey = _replaceRestoreEntryKey(relativePath, trashLocation);
      if (state?.complete == true ||
          state?.restoredEntryKeys.contains(entryKey) == true) {
        return;
      }

      restoredItems.add(_replaceRestoreGroupKey(side, relativePath));
      final createdLine = created[_replaceRestoreGroupKey(side, parentPath)];
      final createdDirectory =
          createdLine != null &&
          (createdLine.action == SyncActionType.makeDirLeft ||
              createdLine.action == SyncActionType.makeDirRight);
      if (parentPath != relativePath || createdDirectory) {
        replaceGroups.add(_replaceRestoreGroupKey(side, parentPath));
      }
    }

    for (final line in items) {
      final location = line.trashLocation;
      if (location == null) continue;
      countTrash(line.side, line.relativePath, line.relativePath, location);
    }
    for (final line in trashLines) {
      countTrash(
        line.side,
        line.relativePath,
        line.parentPath,
        line.trashLocation,
      );
    }
    for (final line in rmdirLines) {
      if (_isTrashSidePurged(line.side)) continue;

      final state = _replaceRestoreFor(line.side, line.parentPath);
      if (state?.complete == true) continue;

      restoredItems.add(_replaceRestoreGroupKey(line.side, line.relativePath));
      final groupKey = _replaceRestoreGroupKey(line.side, line.parentPath);
      if (line.parentPath == line.relativePath &&
          created.containsKey(groupKey)) {
        replaceGroups.add(groupKey);
      }
    }

    final removedCreatedFiles = <String>{};
    for (final groupKey in replaceGroups) {
      final separator = groupKey.indexOf(':');
      final sideName = groupKey.substring(0, separator);
      final parentPath = groupKey.substring(separator + 1);
      final state = _replaceRestoresById[_replaceRestoreIdsByGroup[groupKey]];
      if (state?.complete == true) continue;

      for (final entry in created.entries) {
        final createdSeparator = entry.key.indexOf(':');
        if (entry.key.substring(0, createdSeparator) != sideName) continue;

        final relativePath = entry.key.substring(createdSeparator + 1);
        final insideGroup =
            relativePath == parentPath ||
            relativePath.startsWith('$parentPath/');
        if (!insideGroup || _createsDirectory(entry.value.action)) continue;
        removedCreatedFiles.add(entry.key);
      }
    }

    return SyncRestoreImpact(
      restoredItemCount: restoredItems.length,
      removedCreatedFileCount: removedCreatedFiles.length,
    );
  }

  File get _file => File(path);

  /// Whether any recorded trash entry is still unrestored — the
  /// live-trash retention exception (05 §8 rail 9). Evaluated locally,
  /// no existence probe of the trash itself.
  bool get hasUnpurgedTrash {
    if (_legacyPurged) return false;
    return _recordedTrashScopes.any(
      (scope) => !_purgedTrashScopes.contains(scope),
    );
  }

  Set<String> get _recordedTrashScopes => {
    for (final line in items)
      if (line.trashLocation != null)
        _trashScopeKey(trashScopeForEntry(line.side, line.trashLocation!)),
    for (final line in trashLines)
      _trashScopeKey(trashScopeForEntry(line.side, line.trashLocation)),
  };

  String trashScopeForEntry(SyncSide side, String trashLocation) =>
      trashScopeForSide(side) ?? _trashRootFromLocation(trashLocation);

  String? trashScopeForSide(SyncSide side) {
    final scope = switch (side) {
      SyncSide.left => record.trashScopeLeft,
      SyncSide.right => record.trashScopeRight,
    };
    return scope == null ? null : _normalizeTrashScope(scope);
  }

  String? _legacyTrashScopeForSide(SyncSide side) {
    for (final line in items) {
      if (line.side == side && line.trashLocation != null) {
        return _trashRootFromLocation(line.trashLocation!);
      }
    }
    for (final line in trashLines) {
      if (line.side == side) return _trashRootFromLocation(line.trashLocation);
    }

    return null;
  }

  bool isTrashEntryPurged(SyncSide side, String trashLocation) =>
      _legacyPurged ||
      _purgedTrashScopes.contains(
        _trashScopeKey(trashScopeForEntry(side, trashLocation)),
      );

  bool isTrashScopePurged(String trashScope) =>
      _legacyPurged || _purgedTrashScopes.contains(_trashScopeKey(trashScope));

  bool _isTrashSidePurged(SyncSide side) {
    if (_legacyPurged) return true;

    final scope = trashScopeForSide(side) ?? _legacyTrashScopeForSide(side);
    return scope != null && isTrashScopePurged(scope);
  }

  /// Mirrors a marker appended through another journal instance.
  void noteTrashScopePurged(String trashScope) {
    _purgedTrashScopes.add(_trashScopeKey(trashScope));
  }

  /// Creates the journal file for a run and writes its header line.
  static Future<SyncRunJournal> create(
    String syncRunsDirectory,
    SyncRunRecord record,
  ) async {
    // runId becomes a file name — reject anything that could escape
    // the runs directory.
    if (record.runId.isEmpty ||
        record.runId == '.' ||
        record.runId == '..' ||
        record.runId.contains('/') ||
        record.runId.contains('\\')) {
      throw ArgumentError.value(
        record.runId,
        'record.runId',
        'must be a non-empty path-safe run id',
      );
    }
    final journal = SyncRunJournal._(
      p.join(syncRunsDirectory, '${record.runId}.jsonl'),
      record,
    );
    await Directory(syncRunsDirectory).create(recursive: true);
    await journal._append(<String, Object?>{
      'type': 'header',
      ..._recordToJson(record),
    });
    return journal;
  }

  /// Replays a journal file. Undecodable lines — the torn tail a kill
  /// can leave mid-write, or one stranded mid-file when a resumed run
  /// appended past it — are skipped, never misparsed.
  static Future<SyncRunJournal> open(String path) async {
    final file = File(path);
    // Malformed-tolerant decode: a kill can sever a multi-byte UTF-8
    // character inside the torn write — strict decoding would throw
    // before the skip-undecodable-lines logic ever runs.
    final bytes = await file.readAsBytes();
    final lines = const LineSplitter().convert(
      utf8.decode(bytes, allowMalformed: true),
    );
    SyncRunRecord? record;
    SyncRunJournal? journal;
    for (final raw in lines) {
      if (raw.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        // A kill loses the line it was mid-writing — and a resumed
        // run can append *after* the tear, so skip the torn line and
        // keep replaying rather than truncating everything after it.
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      final version = decoded['v'];
      final type = decoded['type'];
      final restoreRecord = _replaceRestoreRecordTypes.contains(type);
      final expectedVersion = restoreRecord
          ? _replaceRestoreJournalSchemaVersion
          : syncJournalSchemaVersion;
      if (version != expectedVersion) {
        throw FormatException(
          'unsupported sync journal schema version $version in $path',
        );
      }
      if (restoreRecord && journal == null) {
        throw FormatException(
          'replace restore record before the header in $path',
        );
      }
      switch (type) {
        case 'header':
          if (journal != null) {
            throw FormatException('duplicate header line in $path');
          }
          record = _recordFromJson(decoded);
          journal = SyncRunJournal._(path, record);
        case 'item':
          journal?.items.add(_itemFromJson(decoded));
        case 'trash':
          journal?.trashLines.add(_trashFromJson(decoded));
        case 'remove':
          journal?.removeLines.add(_removeFromJson(decoded));
        case 'rmdir':
          journal?.rmdirLines.add(_rmdirFromJson(decoded));
        case 'summary':
          journal?.summary = _summaryFromJson(decoded);
        case 'purged':
          journal?._legacyPurged = true;
        case 'trashScopePurged':
          final trashScope = decoded['trashScope'];
          if (trashScope is String && trashScope.isNotEmpty) {
            journal?.noteTrashScopePurged(trashScope);
          }
        case _replaceRestorePreparedType:
          journal!._replayReplaceRestorePrepared(decoded);
        case _replaceRestoreStartedType:
          journal!._replayReplaceRestoreStarted(decoded);
        case _replaceRestoreStagedType:
          journal!._replayReplaceRestoreTransition(
            decoded,
            _ReplaceRestoreTransition.staged,
          );
        case _replaceRestoreEntryType:
          journal!._replayReplaceRestoreEntry(decoded);
        case _replaceRestoreChildrenType:
          journal!._replayReplaceRestoreTransition(
            decoded,
            _ReplaceRestoreTransition.childrenRestored,
          );
        case _replaceRestoreCompleteType:
          journal!._replayReplaceRestoreTransition(
            decoded,
            _ReplaceRestoreTransition.complete,
          );
        default:
          // Unknown line kinds are skipped so a newer writer never
          // wedges an older reader's restore path.
          break;
      }
    }
    if (record == null || journal == null) {
      throw FormatException('sync journal at $path has no header line');
    }
    return journal;
  }

  /// Inspects [path] without exposing local journal I/O to package callers.
  /// Recognizable recovery records fail closed when ordinary replay cannot
  /// safely open the journal.
  static Future<SyncRestoreJournalState> inspectRestoreRecovery(
    String path,
  ) async {
    try {
      final journal = await open(path);
      return journal.hasIncompleteRestore
          ? SyncRestoreJournalState.incomplete
          : SyncRestoreJournalState.none;
    } on Object {
      return await _mayContainIncompleteRestore(File(path))
          ? SyncRestoreJournalState.unreadableRecovery
          : SyncRestoreJournalState.none;
    }
  }

  /// The highest attempt number journaled for one
  /// (relativePath, side, action) key — `Retry Failed` journals the
  /// re-execution at attempt n+1 (05 §11's uniqueness contract).
  int lastAttempt(String relativePath, SyncSide side, SyncActionType action) {
    var last = 0;
    for (final line in items) {
      if (line.relativePath == relativePath &&
          line.side == side &&
          line.action == action &&
          line.attempt > last) {
        last = line.attempt;
      }
    }
    return last;
  }

  Future<void> appendItem(SyncJournalItemLine line) async {
    // Durable first — a failed write must not leave in-memory state
    // claiming lines the file never received (retention and
    // lastAttempt read these lists).
    await _append(<String, Object?>{
      'type': 'item',
      'path': line.relativePath,
      'side': line.side.name,
      'action': line.action.name,
      'outcome': line.outcome.name,
      'attempt': line.attempt,
      'bytes': line.bytes,
      'durationMs': line.durationMs,
      'userOverridden': line.userOverridden,
      if (line.trashLocation != null) 'trashLocation': line.trashLocation,
      if (line.trashBytes != null) 'trashBytes': line.trashBytes,
      if (line.trashContentSha256 != null)
        'trashContentSha256': line.trashContentSha256,
      if (line.observedMtimeAfterWrite != null)
        'observedMtimeAfterWrite': line.observedMtimeAfterWrite,
      if (line.setstatIgnored) 'setstatIgnored': true,
      if (line.error != null) 'error': line.error,
    });
    items.add(line);
  }

  Future<void> appendTrash(SyncJournalTrashLine line) async {
    await _append(<String, Object?>{
      'type': 'trash',
      'parent': line.parentPath,
      'path': line.relativePath,
      'side': line.side.name,
      'trashLocation': line.trashLocation,
      'bytes': line.bytes,
      if (line.trashContentSha256 != null)
        'trashContentSha256': line.trashContentSha256,
    });
    trashLines.add(line);
  }

  Future<void> appendRemove(SyncJournalRemoveLine line) async {
    await _append(<String, Object?>{
      'type': 'remove',
      'parent': line.parentPath,
      'path': line.relativePath,
      'side': line.side.name,
      'bytes': line.bytes,
    });
    removeLines.add(line);
  }

  Future<void> appendRmdir(SyncJournalRmdirLine line) async {
    await _append(<String, Object?>{
      'type': 'rmdir',
      'path': line.relativePath,
      'side': line.side.name,
      'parent': line.parentPath,
    });
    rmdirLines.add(line);
  }

  Future<void> appendSummary(SyncJournalSummary value) async {
    await _append(<String, Object?>{
      'type': 'summary',
      'counts': {
        for (final entry in value.counts.entries) entry.key.name: entry.value,
      },
      'bytesTransferred': value.bytesTransferred,
      'cancelled': value.cancelled,
      'mtimeUnreliableLeft': value.mtimeUnreliableLeft,
      'mtimeUnreliableRight': value.mtimeUnreliableRight,
    });
    summary = value;
  }

  /// Rail 5's purge marker. New writers scope it to one physical
  /// host/root identity; null preserves the legacy run-wide marker.
  Future<void> markPurged({String? trashScope}) async {
    final normalizedScope = trashScope == null
        ? null
        : _normalizeTrashScope(trashScope);
    await _append(<String, Object?>{
      'type': trashScope == null ? 'purged' : 'trashScopePurged',
      if (normalizedScope != null) 'trashScope': normalizedScope,
    });
    if (trashScope == null) {
      _legacyPurged = true;
    } else {
      _purgedTrashScopes.add(_trashScopeKey(normalizedScope!));
    }
  }

  _ReplaceRestoreState? _replaceRestoreFor(SyncSide side, String parentPath) {
    final transactionId =
        _replaceRestoreIdsByGroup[_replaceRestoreGroupKey(side, parentPath)];
    return transactionId == null ? null : _replaceRestoresById[transactionId];
  }

  Future<_ReplaceRestoreState> _beginReplaceRestore(
    String transactionId,
    SyncSide side,
    String parentPath,
    List<_ReplaceRestoreEntryState> entries,
  ) async {
    for (final entry in entries) {
      await _append(<String, Object?>{
        'type': _replaceRestorePreparedType,
        'transactionId': transactionId,
        'side': side.name,
        'parent': parentPath,
        'path': entry.relativePath,
        'trashLocation': entry.trashLocation,
        'bytes': entry.bytes,
        'sha256': entry.sha256,
      }, version: _replaceRestoreJournalSchemaVersion);
    }
    await _append(<String, Object?>{
      'type': _replaceRestoreStartedType,
      'transactionId': transactionId,
      'side': side.name,
      'parent': parentPath,
    }, version: _replaceRestoreJournalSchemaVersion);

    final state = _ReplaceRestoreState(
      transactionId: transactionId,
      side: side,
      parentPath: parentPath,
      entries: entries,
    );
    _replaceRestoresById[transactionId] = state;
    _replaceRestoreIdsByGroup[state.groupKey] = transactionId;
    return state;
  }

  Future<void> _markReplaceRestoreStaged(_ReplaceRestoreState state) async {
    if (state.staged) return;
    await _appendReplaceRestoreTransition(_replaceRestoreStagedType, state);
    state.staged = true;
  }

  Future<void> _markReplaceRestoreEntry(
    _ReplaceRestoreState state,
    _ReplaceRestoreEntryState entry,
  ) async {
    if (state.restoredEntryKeys.contains(entry.key)) return;
    await _append(<String, Object?>{
      'type': _replaceRestoreEntryType,
      'transactionId': state.transactionId,
      'path': entry.relativePath,
      'trashLocation': entry.trashLocation,
    }, version: _replaceRestoreJournalSchemaVersion);
    state.restoredEntryKeys.add(entry.key);
  }

  Future<void> _markReplaceRestoreChildren(_ReplaceRestoreState state) async {
    if (state.childrenRestored) return;
    await _appendReplaceRestoreTransition(_replaceRestoreChildrenType, state);
    state.childrenRestored = true;
  }

  Future<void> _markReplaceRestoreComplete(_ReplaceRestoreState state) async {
    if (state.complete) return;
    await _appendReplaceRestoreTransition(_replaceRestoreCompleteType, state);
    state.complete = true;
  }

  Future<void> _appendReplaceRestoreTransition(
    String type,
    _ReplaceRestoreState state,
  ) => _append(<String, Object?>{
    'type': type,
    'transactionId': state.transactionId,
  }, version: _replaceRestoreJournalSchemaVersion);

  void _replayReplaceRestorePrepared(Map<String, Object?> json) {
    final entry = _replaceRestoreEntryFromJson(json);
    if (entry == null ||
        _replaceRestoresById.containsKey(entry.transactionId)) {
      throw FormatException('malformed replace restore preparation in $path');
    }

    _replaceRestorePreparations.putIfAbsent(
      entry.transactionId,
      () => {},
    )[entry.key] = entry;
  }

  void _replayReplaceRestoreStarted(Map<String, Object?> json) {
    final transactionId = json['transactionId'];
    final side = _restoreSideFromJson(json['side']);
    final parentPath = json['parent'];
    if (transactionId is! String ||
        !_replaceRestoreIdPattern.hasMatch(transactionId) ||
        side == null ||
        parentPath is! String ||
        parentPath.isEmpty) {
      throw FormatException('malformed replace restore start in $path');
    }

    final prepared =
        _replaceRestorePreparations[transactionId] ??
        const <String, _ReplaceRestoreEntryState>{};
    final groupKey = _replaceRestoreGroupKey(side, parentPath);
    final malformedStart =
        _replaceRestoresById.containsKey(transactionId) ||
        _replaceRestoreIdsByGroup.containsKey(groupKey) ||
        prepared.values.any(
          (entry) => entry.side != side || entry.parentPath != parentPath,
        );
    if (malformedStart) {
      throw FormatException('out-of-order replace restore start in $path');
    }

    final state = _ReplaceRestoreState(
      transactionId: transactionId,
      side: side,
      parentPath: parentPath,
      entries: prepared.values,
    );
    _replaceRestoresById[transactionId] = state;
    _replaceRestoreIdsByGroup[groupKey] = transactionId;
  }

  void _replayReplaceRestoreEntry(Map<String, Object?> json) {
    final transactionId = json['transactionId'];
    final relativePath = json['path'];
    final trashLocation = json['trashLocation'];
    if (transactionId is! String ||
        !_replaceRestoreIdPattern.hasMatch(transactionId) ||
        relativePath is! String ||
        relativePath.isEmpty ||
        trashLocation is! String ||
        trashLocation.isEmpty) {
      throw FormatException('malformed replace restore entry in $path');
    }

    final state = _replaceRestoresById[transactionId];
    final key = _replaceRestoreEntryKey(relativePath, trashLocation);
    if (state == null || !state._replayEntry(key)) {
      throw FormatException('out-of-order replace restore entry in $path');
    }
  }

  void _replayReplaceRestoreTransition(
    Map<String, Object?> json,
    _ReplaceRestoreTransition transition,
  ) {
    final transactionId = json['transactionId'];
    if (transactionId is! String ||
        !_replaceRestoreIdPattern.hasMatch(transactionId)) {
      throw FormatException('malformed replace restore transition in $path');
    }

    final state = _replaceRestoresById[transactionId];
    if (state == null || !state._replayTransition(transition)) {
      throw FormatException('out-of-order replace restore transition in $path');
    }
  }

  /// Appends one complete line with an immediate flush. A fresh open
  /// per append is deliberate (03 §4.6's pattern): no userspace
  /// buffering, so a kill loses at most the line it was mid-writing.
  /// The record is preceded by `\n` too — a torn tail write has no
  /// terminator of its own, and without the leading break it would
  /// glue onto the next record and corrupt that line as well.
  Future<void> _append(
    Map<String, Object?> fields, {
    int version = syncJournalSchemaVersion,
  }) {
    final line = jsonEncode(<String, Object?>{'v': version, ...fields});
    return _file.writeAsString('\n$line\n', mode: FileMode.append, flush: true);
  }

  /// Finds an unfinished restore that overlaps [pairId] or a trash scope.
  static Future<SyncIncompleteRestoreOverlap?> findIncompleteRestoreOverlap(
    String syncRunsDirectory, {
    required String pairId,
    required Iterable<String?> trashScopes,
  }) async {
    final directory = Directory(syncRunsDirectory);
    if (!await directory.exists()) return null;

    final currentScopes = {
      for (final scope in trashScopes)
        if (scope != null) _trashScopeKey(scope),
    };
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;

      final SyncRunJournal journal;
      try {
        journal = await open(entity.path);
      } on Object {
        if (await _mayContainIncompleteRestore(entity)) {
          return SyncIncompleteRestoreOverlap(
            runId: p.basenameWithoutExtension(entity.path),
            pairId: null,
            journalPath: entity.path,
            journalState: SyncRestoreJournalState.unreadableRecovery,
          );
        }
        continue;
      }
      if (!journal.hasIncompleteRestore) continue;
      final overlap = SyncIncompleteRestoreOverlap(
        runId: journal.record.runId,
        pairId: journal.record.pairId,
        journalPath: journal.path,
        journalState: SyncRestoreJournalState.incomplete,
      );
      if (journal.record.pairId == pairId) return overlap;

      final journalScopes = <String>{};
      for (final side in SyncSide.values) {
        final scope = journal.trashScopeForSide(side);
        if (scope != null) journalScopes.add(_trashScopeKey(scope));
      }
      if (journalScopes.any(currentScopes.contains)) return overlap;
    }

    return null;
  }

  /// Opens every incomplete restore for [pairId], newest first.
  /// A recognizable recovery journal that cannot be replayed throws rather
  /// than treating potentially staged work as absent.
  static Future<List<SyncRunJournal>> findIncompleteRestoresForPair(
    String syncRunsDirectory,
    String pairId,
  ) async {
    final lookup = await findIncompleteRestoreForPairs(syncRunsDirectory, {
      pairId,
    });
    return switch (lookup) {
      SyncIncompleteRestoreAbsent() => const [],
      SyncIncompleteRestoreFound(:final journals) => journals,
      SyncIncompleteRestoreBlocked(:final journalPath) =>
        throw SyncRestoreJournalUnreadableException(journalPath),
    };
  }

  /// Finds restart recovery belonging to any pre-probe [pairIds].
  ///
  /// Corrupt recovery blocks only when its valid header attributes it to a
  /// candidate. Run admission uses [findIncompleteRestoreOverlap] for its
  /// broader fail-closed policy.
  static Future<SyncIncompleteRestoreLookup> findIncompleteRestoreForPairs(
    String syncRunsDirectory,
    Set<String> pairIds,
  ) async {
    final directory = Directory(syncRunsDirectory);
    if (!await directory.exists() || pairIds.isEmpty) {
      return const SyncIncompleteRestoreAbsent();
    }

    final matches = <SyncRunJournal>[];
    SyncIncompleteRestoreBlocked? blocker;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;

      final SyncRunJournal journal;
      try {
        journal = await open(entity.path);
      } on Object {
        if (!await _mayContainIncompleteRestore(entity)) continue;

        final journalPairId = await _pairIdForAttribution(entity);
        if (journalPairId == null || !pairIds.contains(journalPairId)) continue;
        blocker ??= SyncIncompleteRestoreBlocked(
          journalPath: entity.path,
          pairId: journalPairId,
        );
        continue;
      }
      if (pairIds.contains(journal.record.pairId) &&
          journal.hasIncompleteRestore) {
        matches.add(journal);
      }
    }
    if (blocker != null) return blocker;
    if (matches.isEmpty) return const SyncIncompleteRestoreAbsent();

    matches.sort((a, b) => b.record.startedAt.compareTo(a.record.startedAt));
    return SyncIncompleteRestoreFound(List.unmodifiable(matches));
  }

  static Future<String?> _pairIdForAttribution(File file) async {
    final List<String> lines;
    try {
      final bytes = await file.readAsBytes();
      lines = const LineSplitter().convert(
        utf8.decode(bytes, allowMalformed: true),
      );
    } on Object {
      return null;
    }

    SyncRunRecord? header;
    for (final line in lines) {
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?> || decoded['type'] != 'header') {
        continue;
      }
      if (decoded['v'] != syncJournalSchemaVersion || header != null) {
        return null;
      }
      try {
        header = _recordFromJson(decoded);
      } on Object {
        return null;
      }
    }

    return header?.pairId;
  }

  static Future<bool> _mayContainIncompleteRestore(File file) async {
    final List<String> lines;
    try {
      final bytes = await file.readAsBytes();
      lines = const LineSplitter().convert(
        utf8.decode(bytes, allowMalformed: true),
      );
    } on Object {
      // A retained journal that cannot even be inspected stays fail-closed.
      return true;
    }

    final preparations = <String, Map<String, _ReplaceRestoreEntryState>>{};
    final states = <String, _ReplaceRestoreState>{};
    final transactionIdsByGroup = <String, String>{};
    var hasHeader = false;
    for (final line in lines) {
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;

      final type = decoded['type'];
      if (type == 'header' && decoded['v'] == syncJournalSchemaVersion) {
        hasHeader = true;
        continue;
      }
      if (!_replaceRestoreRecordTypes.contains(type)) continue;
      if (decoded['v'] != _replaceRestoreJournalSchemaVersion || !hasHeader) {
        return true;
      }

      if (type == _replaceRestorePreparedType) {
        final entry = _replaceRestoreEntryFromJson(decoded);
        if (entry == null || states.containsKey(entry.transactionId)) {
          return true;
        }
        preparations.putIfAbsent(entry.transactionId, () => {})[entry.key] =
            entry;
        continue;
      }

      final transactionId = decoded['transactionId'];
      if (transactionId is! String ||
          !_replaceRestoreIdPattern.hasMatch(transactionId)) {
        return true;
      }

      if (type == _replaceRestoreStartedType) {
        final side = _restoreSideFromJson(decoded['side']);
        final parentPath = decoded['parent'];
        if (side == null || parentPath is! String || parentPath.isEmpty) {
          return true;
        }

        final prepared =
            preparations[transactionId] ??
            const <String, _ReplaceRestoreEntryState>{};
        final groupKey = _replaceRestoreGroupKey(side, parentPath);
        final malformedStart =
            states.containsKey(transactionId) ||
            transactionIdsByGroup.containsKey(groupKey) ||
            prepared.values.any(
              (entry) => entry.side != side || entry.parentPath != parentPath,
            );
        if (malformedStart) return true;

        states[transactionId] = _ReplaceRestoreState(
          transactionId: transactionId,
          side: side,
          parentPath: parentPath,
          entries: prepared.values,
        );
        transactionIdsByGroup[groupKey] = transactionId;
        continue;
      }

      final state = states[transactionId];
      if (state == null) return true;

      if (type == _replaceRestoreEntryType) {
        final relativePath = decoded['path'];
        final trashLocation = decoded['trashLocation'];
        if (relativePath is! String ||
            relativePath.isEmpty ||
            trashLocation is! String ||
            trashLocation.isEmpty) {
          return true;
        }
        final key = _replaceRestoreEntryKey(relativePath, trashLocation);
        if (!state._replayEntry(key)) return true;
        continue;
      }

      final transition = switch (type) {
        _replaceRestoreStagedType => _ReplaceRestoreTransition.staged,
        _replaceRestoreChildrenType =>
          _ReplaceRestoreTransition.childrenRestored,
        _replaceRestoreCompleteType => _ReplaceRestoreTransition.complete,
        _ => null,
      };
      if (transition == null || !state._replayTransition(transition)) {
        return true;
      }
    }
    return states.values.any((state) => !state.complete);
  }

  /// Prunes [syncRunsDirectory] to the newest [keep] journals per pair —
  /// except any journal still guarding live trash (trash entries, no
  /// `purged` marker), which is retained no matter its age (05 §8
  /// rail 9's locally-evaluable exception). Unparseable files are left
  /// alone.
  static Future<void> prune(
    String syncRunsDirectory,
    String pairId, {
    int keep = syncJournalRetention,
  }) async {
    final directory = Directory(syncRunsDirectory);
    if (!await directory.exists()) return;
    final journals = <SyncRunJournal>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      try {
        final journal = await open(entity.path);
        if (journal.record.pairId == pairId) journals.add(journal);
      } on Object {
        // A foreign or corrupt file is never prunable by pattern.
        continue;
      }
    }
    journals.sort((a, b) => a.record.startedAt.compareTo(b.record.startedAt));
    // Live-trash journals are exempt from the cap entirely — the
    // newest `keep` applies only to the prunable population.
    bool protected(SyncRunJournal journal) =>
        journal.hasUnpurgedTrash || journal.hasIncompleteRestore;

    final prunable =
        journals.where((journal) => !protected(journal)).length - keep;
    if (prunable <= 0) return;
    var removed = 0;
    for (final journal in journals) {
      if (removed >= prunable) break;
      if (protected(journal)) continue;
      try {
        await File(journal.path).delete();
        removed++;
      } on Object {
        // Best-effort hygiene — a stubborn file retries next run.
      }
    }
  }
}

String _trashRootFromLocation(String trashLocation) {
  final context = _journalTrashPathContext(trashLocation);
  final normalizedLocation = context.normalize(
    _normalizeSlashUncPrefix(trashLocation),
  );
  return _normalizeJournalTrashRoot(
    context.dirname(context.dirname(normalizedLocation)),
  );
}

String _normalizeJournalTrashRoot(String path) {
  final context = _journalTrashPathContext(path);
  final normalized = context.normalize(_normalizeSlashUncPrefix(path));
  if (normalized == context.rootPrefix(normalized)) return normalized;

  final trailingSeparators = RegExp('${RegExp.escape(context.separator)}+\$');
  return normalized.replaceFirst(trailingSeparators, '');
}

String _normalizeTrashScope(String scope) =>
    isSyncTrashIdentityKey(scope) ? scope : _normalizeJournalTrashRoot(scope);

String _trashScopeKey(String scope) {
  if (isSyncTrashIdentityKey(scope)) return scope;

  final normalized = _normalizeJournalTrashRoot(scope);
  return _usesWindowsTrashPath(scope) ? normalized.toLowerCase() : normalized;
}

p.Context _journalTrashPathContext(String path) {
  return _usesWindowsTrashPath(path) ? p.windows : p.posix;
}

bool _usesWindowsTrashPath(String path) {
  final hasWindowsDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  final hasWindowsUncPrefix =
      path.startsWith(_windowsUncPrefix) || path.startsWith(_slashUncPrefix);
  final hasOnlyWindowsSeparators = path.contains(r'\') && !path.contains('/');
  return hasWindowsDrive || hasWindowsUncPrefix || hasOnlyWindowsSeparators;
}

String _normalizeSlashUncPrefix(String path) => path.startsWith(_slashUncPrefix)
    ? '$_windowsUncPrefix${path.substring(_slashUncPrefix.length)}'
    : path;

/// One entry the restore path must put back.
final class _TrashedEntry {
  _TrashedEntry({
    required this.relativePath,
    required this.side,
    required this.trashLocation,
    required this.bytes,
    required this.sha256,
    required this.parentPath,
  });

  final String relativePath;
  final SyncSide side;
  final String trashLocation;
  final int bytes;
  final String? sha256;
  final String parentPath;

  String get key => _replaceRestoreEntryKey(relativePath, trashLocation);
}

_ReplaceRestoreEntryState? _replaceRestoreEntryFromJson(
  Map<String, Object?> json,
) {
  final transactionId = json['transactionId'];
  final side = _restoreSideFromJson(json['side']);
  final parentPath = json['parent'];
  final relativePath = json['path'];
  final trashLocation = json['trashLocation'];
  final bytes = json['bytes'];
  final digest = json['sha256'];
  if (transactionId is! String ||
      !_replaceRestoreIdPattern.hasMatch(transactionId) ||
      side == null ||
      parentPath is! String ||
      parentPath.isEmpty ||
      relativePath is! String ||
      relativePath.isEmpty ||
      trashLocation is! String ||
      trashLocation.isEmpty ||
      bytes is! int ||
      bytes < 0 ||
      digest is! String ||
      !_sha256Pattern.hasMatch(digest)) {
    return null;
  }

  return _ReplaceRestoreEntryState(
    transactionId: transactionId,
    side: side,
    parentPath: parentPath,
    relativePath: relativePath,
    trashLocation: trashLocation,
    bytes: bytes,
    sha256: digest,
  );
}

SyncSide? _restoreSideFromJson(Object? value) {
  for (final side in SyncSide.values) {
    if (side.name == value) return side;
  }
  return null;
}

/// Resolves a journal source back through its owned root and real run
/// directory. Repeating this check around restore mutations narrows the
/// path-only VFS race without ever following a substituted parent link.
Future<String> _verifiedRestoreTrashPath(
  SyncRunJournal journal,
  _TrashedEntry entry,
  RemoteFileSystem fileSystem,
) async {
  final journalContext = _journalTrashPathContext(entry.trashLocation);
  final journalPathStyle = journalContext.style == p.Style.windows
      ? SyncTrashPathStyle.windows
      : SyncTrashPathStyle.posix;
  final normalizedLocation = journalContext.normalize(entry.trashLocation);
  final runPath = journalContext.dirname(normalizedLocation);
  final trashRoot = journalContext.dirname(runPath);
  final runId = journalContext.basename(runPath);
  final fileName = journalContext.basename(normalizedLocation);
  if (runId != journal.record.runId || fileName.isEmpty) {
    throw _unsafeRestoreTrashPath(entry.trashLocation);
  }

  final expectedScope = journal.trashScopeForSide(entry.side);
  final String canonicalRoot;
  final String? expectedRootId;
  if (expectedScope == null) {
    canonicalRoot = await _verifiedLegacyTrashRoot(
      fileSystem,
      trashRoot,
      journalContext,
      entry.trashLocation,
    );
    expectedRootId = null;
  } else {
    final identity = await resolveSyncTrashRoot(
      fileSystem,
      trashRoot,
      pathStyle: journalPathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    if (identity.scopeKey != expectedScope) {
      throw _unsafeRestoreTrashPath(entry.trashLocation);
    }

    canonicalRoot = identity.canonicalRoot;
    expectedRootId = identity.rootId;
  }

  // Relative legacy paths have no grammar signal. Once resolved, use the
  // filesystem's canonical spelling for every containment check.
  final canonicalContext = _journalTrashPathContext(canonicalRoot);
  final canonicalPathStyle = canonicalContext.style == p.Style.windows
      ? SyncTrashPathStyle.windows
      : SyncTrashPathStyle.posix;
  final normalizedCanonicalRoot = canonicalContext.normalize(canonicalRoot);
  final canonicalRunPath = canonicalContext.join(
    normalizedCanonicalRoot,
    journal.record.runId,
  );
  final runEntry = await fileSystem.stat(canonicalRunPath, followLinks: false);
  if (!runEntry.isDirectory) {
    throw _unsafeRestoreTrashPath(entry.trashLocation);
  }
  final resolvedRunPath = canonicalContext.normalize(
    await fileSystem.canonicalize(canonicalRunPath),
  );
  if (!_journalTrashPathsEqual(
    canonicalContext,
    resolvedRunPath,
    canonicalRunPath,
  )) {
    throw _unsafeRestoreTrashPath(entry.trashLocation);
  }

  final verifiedLocation = canonicalContext.join(canonicalRunPath, fileName);
  final resolvedLocation = canonicalContext.normalize(
    await fileSystem.canonicalize(verifiedLocation),
  );
  if (!_journalTrashPathsEqual(
    canonicalContext,
    resolvedLocation,
    verifiedLocation,
  )) {
    throw _unsafeRestoreTrashPath(entry.trashLocation);
  }

  if (expectedRootId == null) {
    await _verifiedLegacyTrashRoot(
      fileSystem,
      normalizedCanonicalRoot,
      canonicalContext,
      entry.trashLocation,
    );
  } else {
    final verifiedRoot = await resolveSyncTrashRoot(
      fileSystem,
      normalizedCanonicalRoot,
      pathStyle: canonicalPathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    if (verifiedRoot.rootId != expectedRootId ||
        !_journalTrashPathsEqual(
          canonicalContext,
          verifiedRoot.canonicalRoot,
          normalizedCanonicalRoot,
        )) {
      throw _unsafeRestoreTrashPath(entry.trashLocation);
    }
  }

  return verifiedLocation;
}

Future<String> _verifiedLegacyTrashRoot(
  RemoteFileSystem fileSystem,
  String trashRoot,
  p.Context context,
  String unsafePath,
) async {
  final root = await fileSystem.stat(trashRoot, followLinks: false);
  if (!root.isDirectory) throw _unsafeRestoreTrashPath(unsafePath);

  final normalizedRoot = context.normalize(trashRoot);
  final canonicalRoot = context.normalize(
    await fileSystem.canonicalize(normalizedRoot),
  );
  if (context.isAbsolute(normalizedRoot) &&
      !_journalTrashPathsEqual(context, canonicalRoot, normalizedRoot)) {
    throw _unsafeRestoreTrashPath(unsafePath);
  }

  return canonicalRoot;
}

bool _journalTrashPathsEqual(p.Context context, String left, String right) {
  final normalizedLeft = context.normalize(left);
  final normalizedRight = context.normalize(right);
  if (context.style == p.Style.windows) {
    return normalizedLeft.toLowerCase() == normalizedRight.toLowerCase();
  }

  return normalizedLeft == normalizedRight;
}

RemoteFileException _unsafeRestoreTrashPath(String path) => RemoteFileException(
  kind: RemoteFileErrorKind.conflict,
  operation: 'restore sync trash',
  path: path,
  message: 'The trashed copy moved outside its owned run directory.',
);

RemoteFileException _unsafeRestoreDestination(String path, String message) =>
    RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'restore sync trash',
      path: path,
      message: message,
    );

Iterable<({SyncSide side, String path})> _journalRestorePaths(
  SyncRunJournal journal,
) sync* {
  for (final line in journal.items) {
    yield (side: line.side, path: line.relativePath);
  }
  for (final line in journal.trashLines) {
    yield (side: line.side, path: line.parentPath);
    yield (side: line.side, path: line.relativePath);
  }
  for (final line in journal.removeLines) {
    yield (side: line.side, path: line.parentPath);
    yield (side: line.side, path: line.relativePath);
  }
  for (final line in journal.rmdirLines) {
    yield (side: line.side, path: line.parentPath);
    yield (side: line.side, path: line.relativePath);
  }
  for (final preparations in journal._replaceRestorePreparations.values) {
    for (final entry in preparations.values) {
      yield (side: entry.side, path: entry.parentPath);
      yield (side: entry.side, path: entry.relativePath);
    }
  }
  for (final state in journal._replaceRestoresById.values) {
    yield (side: state.side, path: state.parentPath);
    for (final entry in state.entries.values) {
      yield (side: entry.side, path: entry.parentPath);
      yield (side: entry.side, path: entry.relativePath);
    }
  }
}

Set<SyncSide> _journalRestoreSides(SyncRunJournal journal) => {
  for (final line in journal.items)
    if (line.trashLocation != null &&
        !journal.isTrashEntryPurged(line.side, line.trashLocation!))
      line.side,
  for (final line in journal.trashLines)
    if (!journal.isTrashEntryPurged(line.side, line.trashLocation)) line.side,
  for (final line in journal.rmdirLines) line.side,
  for (final state in journal._replaceRestoresById.values)
    if (!state.complete) state.side,
};

String? _recordedRestoreRoot(SyncRunJournal journal, SyncSide side) =>
    switch (side) {
      SyncSide.left => journal.record.canonicalRootLeft,
      SyncSide.right => journal.record.canonicalRootRight,
    };

String? _restoreRelativePathError(String root, String relativePath) {
  final context = _journalTrashPathContext(root);
  final windowsRoot = _usesWindowsTrashPath(root);
  final segments = relativePath.split('/');
  final invalidRelativePath =
      relativePath.isEmpty ||
      context.isAbsolute(relativePath) ||
      (windowsRoot && relativePath.contains(r'\')) ||
      segments.any(
        (segment) =>
            segment.isEmpty ||
            segment == _currentDirectorySegment ||
            segment == _parentDirectorySegment,
      );
  if (invalidRelativePath) {
    return '"$relativePath" is outside the sync root';
  }

  final normalizedRoot = context.normalize(_normalizeSlashUncPrefix(root));
  final destination = context.normalize(
    context.joinAll([normalizedRoot, ...segments]),
  );
  if (!context.isWithin(normalizedRoot, destination)) {
    return '"$relativePath" is outside the sync root';
  }

  return null;
}

String? _restoreRootBindingError(String root, String? recordedRoot) {
  final context = _journalTrashPathContext(root);
  final normalizedRoot = context.normalize(_normalizeSlashUncPrefix(root));
  if (!context.isAbsolute(normalizedRoot)) {
    return 'the sync root is not canonical';
  }
  if (recordedRoot == null) return null;

  final recordedContext = _journalTrashPathContext(recordedRoot);
  if (recordedContext.style != context.style ||
      !_journalTrashPathsEqual(context, root, recordedRoot)) {
    return 'the sync root no longer matches the recorded canonical root';
  }

  return null;
}

Future<String?> _restoreRootError(RemoteFileSystem fs, String root) async {
  try {
    final rootEntry = await fs.stat(root, followLinks: false);
    if (rootEntry.isSymbolicLink || !rootEntry.isDirectory) {
      return 'the sync root changed before restore';
    }

    final context = _journalTrashPathContext(root);
    final normalizedRoot = context.normalize(_normalizeSlashUncPrefix(root));
    final canonicalRoot = context.normalize(await fs.canonicalize(root));
    if (!_journalTrashPathsEqual(context, canonicalRoot, normalizedRoot)) {
      return 'the sync root changed before restore';
    }
  } on RemoteFileException catch (error) {
    return 'could not validate the sync root: ${error.message}';
  }

  return null;
}

final class _RestoreBinding {
  const _RestoreBinding({required this.fs, required this.root});

  final RemoteFileSystem fs;
  final String root;
}

Future<Map<SyncSide, _RestoreBinding>> _validateJournalRestoreInputs(
  SyncRunJournal journal, {
  required RemoteFileSystem Function(SyncSide side) fsFor,
  required String Function(SyncSide side) rootFor,
}) async {
  final roots = <SyncSide, String>{};
  final fileSystems = <SyncSide, RemoteFileSystem>{};
  String root(SyncSide side) => roots.putIfAbsent(side, () => rootFor(side));
  RemoteFileSystem fs(SyncSide side) =>
      fileSystems.putIfAbsent(side, () => fsFor(side));

  // Validate the full journal before the first filesystem call. One unsafe
  // line must block the whole restore, not leave a partly-restored prefix.
  for (final entry in _journalRestorePaths(journal)) {
    final error = _restoreRelativePathError(root(entry.side), entry.path);
    if (error != null) {
      throw _unsafeRestoreDestination(entry.path, error);
    }
  }

  final restoreSides = _journalRestoreSides(journal);
  for (final side in restoreSides) {
    final sideRoot = root(side);
    final error = _restoreRootBindingError(
      sideRoot,
      _recordedRestoreRoot(journal, side),
    );
    if (error != null) throw _unsafeRestoreDestination(sideRoot, error);
  }

  for (final side in restoreSides) {
    final sideRoot = root(side);
    final error = await _restoreRootError(fs(side), sideRoot);
    if (error != null) throw _unsafeRestoreDestination(sideRoot, error);
  }

  return {
    for (final side in restoreSides)
      side: _RestoreBinding(fs: fs(side), root: root(side)),
  };
}

/// One restore outcome line for a skipped entry — the path and why.
final class SyncRestoreSkip {
  const SyncRestoreSkip(this.relativePath, this.reason);

  final String relativePath;
  final String reason;
}

/// The result of `Restore Trashed Files…` (05 §8 rail 9).
final class SyncRestoreReport {
  const SyncRestoreReport({required this.restored, required this.skipped});

  /// Origins successfully restored.
  final List<String> restored;

  /// Entries skipped with reasons — post-state changed, a truncated
  /// copy-fallback trash entry, or a blocked parent chain.
  final List<SyncRestoreSkip> skipped;
}

/// `Restore Trashed Files…` (05 §8 rail 9): reverses the recorded
/// renames for every trashed/backed-up file in [journal], restoring
/// each to its origin — after a per-file conflict check against the
/// run's recorded post-state, never the pre-run snapshot. A destination
/// that no longer matches is skipped and listed; Undo never overwrites
/// newer changes. `fsFor`/`rootFor` resolve each side's filesystem and
/// canonical sync root. [cancellation] stops between independent restore
/// steps and returns the completed prefix.
Future<SyncRestoreReport> restoreTrashedFiles(
  SyncRunJournal journal, {
  required RemoteFileSystem Function(SyncSide side) fsFor,
  required String Function(SyncSide side) rootFor,
  RemoteTransferCancellation? cancellation,
}) async {
  if (cancellation?.isCancelled ?? false) {
    return const SyncRestoreReport(restored: [], skipped: []);
  }

  final bindings = await _validateJournalRestoreInputs(
    journal,
    fsFor: fsFor,
    rootFor: rootFor,
  );

  // The recorded post-state for every path the run created or updated:
  // size + observedMtimeAfterWrite for files. Deletions expect absence.
  final created = <String, SyncJournalItemLine>{};
  for (final line in journal.items) {
    switch (line.action) {
      case SyncActionType.copyLeftToRight ||
          SyncActionType.copyRightToLeft ||
          SyncActionType.updateLeftToRight ||
          SyncActionType.updateRightToLeft ||
          SyncActionType.makeDirLeft ||
          SyncActionType.makeDirRight:
        if (line.outcome == SyncItemStatus.done) {
          created['${line.side.name}:${line.relativePath}'] = line;
        }
      default:
        break;
    }
  }

  final trashed = <_TrashedEntry>[
    for (final line in journal.items)
      if (line.trashLocation != null &&
          !journal.isTrashEntryPurged(line.side, line.trashLocation!))
        _TrashedEntry(
          relativePath: line.relativePath,
          side: line.side,
          trashLocation: line.trashLocation!,
          bytes: line.trashBytes ?? line.bytes,
          sha256: line.trashContentSha256,
          parentPath: line.relativePath,
        ),
    for (final line in journal.trashLines)
      if (!journal.isTrashEntryPurged(line.side, line.trashLocation))
        _TrashedEntry(
          relativePath: line.relativePath,
          side: line.side,
          trashLocation: line.trashLocation,
          bytes: line.bytes,
          sha256: line.trashContentSha256,
          parentPath: line.parentPath,
        ),
  ];

  final restored = <String>[];
  final skipped = <SyncRestoreSkip>[];
  final replaceGroups =
      <
        String,
        ({SyncSide side, String parentPath, List<_TrashedEntry> entries})
      >{};
  for (final entry in trashed) {
    final groupKey = _replaceRestoreGroupKey(entry.side, entry.parentPath);
    final createdLine = created[groupKey];
    final createdDirectory =
        createdLine != null &&
        (createdLine.action == SyncActionType.makeDirLeft ||
            createdLine.action == SyncActionType.makeDirRight);
    if (entry.parentPath == entry.relativePath && !createdDirectory) continue;

    final group = replaceGroups.putIfAbsent(
      groupKey,
      () => (
        side: entry.side,
        parentPath: entry.parentPath,
        entries: <_TrashedEntry>[],
      ),
    );
    group.entries.add(entry);
  }
  for (final line in journal.rmdirLines) {
    if (line.parentPath != line.relativePath) continue;

    final groupKey = _replaceRestoreGroupKey(line.side, line.parentPath);
    if (!created.containsKey(groupKey)) continue;
    replaceGroups.putIfAbsent(
      groupKey,
      () => (
        side: line.side,
        parentPath: line.parentPath,
        entries: <_TrashedEntry>[],
      ),
    );
  }
  final handledReplaceGroups = <String>{};

  Future<void> restoreReplaceGroup(
    String groupKey,
    ({SyncSide side, String parentPath, List<_TrashedEntry> entries}) group,
  ) async {
    if (cancellation?.isCancelled ?? false) return;
    if (!handledReplaceGroups.add(groupKey)) return;

    final binding = bindings[group.side]!;
    final outcomes = await _restoreReplaceGroup(
      journal: journal,
      side: group.side,
      parentPath: group.parentPath,
      entries: group.entries,
      fs: binding.fs,
      root: binding.root,
      created: created,
      cancellation: cancellation,
    );
    if (group.entries.isEmpty) {
      final state = journal._replaceRestoreFor(group.side, group.parentPath);
      if (state?.complete == true) restored.add(group.parentPath);
      return;
    }
    for (final entry in group.entries) {
      if (!outcomes.containsKey(entry.key)) continue;

      final outcome = outcomes[entry.key];
      if (outcome == null) {
        restored.add(entry.relativePath);
      } else {
        skipped.add(SyncRestoreSkip(entry.relativePath, outcome));
      }
    }
  }

  for (final entry in trashed) {
    if (cancellation?.isCancelled ?? false) break;

    final binding = bindings[entry.side]!;
    final fs = binding.fs;
    final root = binding.root;
    final groupKey = _replaceRestoreGroupKey(entry.side, entry.parentPath);
    final replaceGroup = replaceGroups[groupKey];
    if (replaceGroup != null) {
      await restoreReplaceGroup(groupKey, replaceGroup);
      continue;
    }

    final origin = remoteJoin(root, entry.relativePath);
    final outcome = await _restoreOne(
      journal: journal,
      entry: entry,
      fs: fs,
      root: root,
      origin: origin,
      created: created,
    );
    if (outcome == null) {
      restored.add(entry.relativePath);
    } else {
      skipped.add(SyncRestoreSkip(entry.relativePath, outcome));
    }
  }
  for (final group in replaceGroups.entries) {
    if (cancellation?.isCancelled ?? false) break;
    await restoreReplaceGroup(group.key, group.value);
  }

  // Directories emptied and rmdir'd by the run that hold no restored
  // file — recreate them shallowest-first. EEXIST is fine; a path now
  // occupied by a file stays reported via its children's skips.
  final emptiedDirs = journal.rmdirLines.toList()
    ..sort(
      (a, b) =>
          a.relativePath.split('/').length - b.relativePath.split('/').length,
    );
  for (final line in emptiedDirs) {
    if (cancellation?.isCancelled ?? false) break;

    // Rule-4 directories are reconstructed inside the durable transaction.
    final groupKey = _replaceRestoreGroupKey(line.side, line.parentPath);
    if (replaceGroups.containsKey(groupKey)) continue;

    final binding = bindings[line.side]!;
    final trashScope =
        journal.trashScopeForSide(line.side) ??
        journal._legacyTrashScopeForSide(line.side) ??
        _normalizeJournalTrashRoot(
          _journalTrashRootForSide(journal, line.side, binding.root),
        );
    if (journal.isTrashScopePurged(trashScope)) continue;
    final fs = binding.fs;
    final root = binding.root;
    final rootError = await _restoreRootError(fs, root);
    if (rootError != null) {
      throw _unsafeRestoreDestination(root, rootError);
    }
    var chainError = await _validateReplaceParentChain(
      fs,
      root,
      line.relativePath,
    );
    if (chainError != null) continue;

    final abs = remoteJoin(root, line.relativePath);
    if (await _statOrNull(fs, abs) != null) continue;
    chainError = await _validateReplaceParentChain(fs, root, line.relativePath);
    if (chainError != null) continue;

    try {
      await fs.createDirectory(abs);
    } on RemoteFileException {
      // Best-effort — an unplaceable level leaves its children skipped.
    }
  }
  return SyncRestoreReport(
    restored: List.unmodifiable(restored),
    skipped: List.unmodifiable(skipped),
  );
}

/// Restores one rule-4 subtree as a durable transaction. The replacement is
/// first moved to a journaled sibling stage, so a disconnect can resume
/// without mistaking an already-restored child for changed post-state.
Future<Map<String, String?>> _restoreReplaceGroup({
  required SyncRunJournal journal,
  required SyncSide side,
  required String parentPath,
  required List<_TrashedEntry> entries,
  required RemoteFileSystem fs,
  required String root,
  required Map<String, SyncJournalItemLine> created,
  RemoteTransferCancellation? cancellation,
}) async {
  final createdLine = created[_replaceRestoreGroupKey(side, parentPath)];
  var state = journal._replaceRestoreFor(side, parentPath);

  if (state == null) {
    final prepared = <_ReplaceRestoreEntryState>[];
    for (final entry in entries) {
      if (cancellation?.isCancelled ?? false) return const {};

      final result = await _preflightReplaceEntry(journal, entry, fs);
      final error = result.error;
      if (error != null) return _replaceGroupFailure(entries, null, error);
      prepared.add(result.state!);
    }

    if (cancellation?.isCancelled ?? false) return const {};

    final parentError = await _verifyInitialReplaceParent(
      fs: fs,
      root: root,
      side: side,
      parentPath: parentPath,
      createdLine: createdLine,
      created: created,
    );
    if (parentError != null) {
      return _replaceGroupFailure(entries, null, parentError);
    }

    if (cancellation?.isCancelled ?? false) return const {};

    final allocation = await _allocateReplaceRestoreStage(fs, root, parentPath);
    final allocationError = allocation.error;
    if (allocationError != null) {
      return _replaceGroupFailure(entries, null, allocationError);
    }

    final transactionId = allocation.transactionId!;
    final transactionEntries = [
      for (final entry in prepared)
        _ReplaceRestoreEntryState(
          transactionId: transactionId,
          side: entry.side,
          parentPath: entry.parentPath,
          relativePath: entry.relativePath,
          trashLocation: entry.trashLocation,
          bytes: entry.bytes,
          sha256: entry.sha256,
        ),
    ];
    if (cancellation?.isCancelled ?? false) return const {};

    state = await journal._beginReplaceRestore(
      transactionId,
      side,
      parentPath,
      transactionEntries,
    );
  }

  final stateError = _replaceRestoreStateMismatch(state, entries);
  if (stateError != null) {
    return _replaceGroupFailure(entries, state, stateError);
  }
  if (state.complete) return _replaceGroupSuccess(entries);

  final outcomes = _completedReplaceOutcomes(entries, state);
  if (cancellation?.isCancelled ?? false) return outcomes;

  final stageError = await _ensureReplaceParentStaged(
    journal: journal,
    state: state,
    fs: fs,
    root: root,
    createdLine: createdLine,
    created: created,
  );
  if (stageError != null) {
    return _replaceGroupFailure(entries, state, stageError);
  }

  // A resumed transaction may share its destination only with entries it
  // already restored and the directory chain those entries require.
  final destinationError = await _replaceRestoreDestinationMismatch(
    journal: journal,
    state: state,
    fs: fs,
    root: root,
  );
  if (destinationError != null) {
    return _replaceGroupFailure(entries, state, destinationError);
  }

  for (final entry in entries) {
    if (cancellation?.isCancelled ?? false) return outcomes;

    final prepared = state.entries[entry.key]!;
    if (state.restoredEntryKeys.contains(entry.key)) {
      final restoredError = await _restoredEntryMismatch(
        fs,
        remoteJoin(root, entry.relativePath),
        prepared,
      );
      if (restoredError != null) {
        return _replaceGroupFailure(
          entries,
          state,
          restoredError,
          invalidEntryKey: entry.key,
        );
      }
      outcomes[entry.key] = null;
      continue;
    }

    final restoreError = await _restorePreparedReplaceEntry(
      journal: journal,
      state: state,
      entry: entry,
      prepared: prepared,
      fs: fs,
      root: root,
      cancellation: cancellation,
    );
    if (restoreError.cancelled) return outcomes;
    if (restoreError.error != null) {
      outcomes.addAll(
        _replaceGroupFailure(entries, state, restoreError.error!),
      );
      return outcomes;
    }
    outcomes[entry.key] = null;
  }

  if (cancellation?.isCancelled ?? false) return outcomes;

  await journal._markReplaceRestoreChildren(state);
  final directoryRestore = await _restoreReplaceDirectories(
    journal: journal,
    state: state,
    fs: fs,
    root: root,
    cancellation: cancellation,
  );
  if (directoryRestore.cancelled) return outcomes;
  if (directoryRestore.error != null) {
    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'restore sync trash',
      path: remoteJoin(root, parentPath),
      message: directoryRestore.error!,
    );
  }

  final finalDestinationError = await _replaceRestoreDestinationMismatch(
    journal: journal,
    state: state,
    fs: fs,
    root: root,
  );
  if (finalDestinationError != null) {
    return _replaceGroupFailure(entries, state, finalDestinationError);
  }

  final cleanupError = await _removeStagedReplacement(
    state: state,
    fs: fs,
    root: root,
    createdLine: createdLine,
    created: created,
    cancellation: cancellation,
  );
  if (cleanupError.cancelled) return outcomes;
  if (cleanupError.error != null) {
    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'restore sync trash',
      path: _replaceRestoreStagePath(root, parentPath, state.transactionId),
      message: cleanupError.error!,
    );
  }
  if (cancellation?.isCancelled ?? false) return outcomes;

  await journal._markReplaceRestoreComplete(state);
  return outcomes;
}

Future<({_ReplaceRestoreEntryState? state, String? error})>
_preflightReplaceEntry(
  SyncRunJournal journal,
  _TrashedEntry entry,
  RemoteFileSystem fs,
) async {
  try {
    final verifiedPath = await _verifiedRestoreTrashPath(journal, entry, fs);
    final live = await fs.stat(verifiedPath, followLinks: false);
    if (live.type != RemoteFileType.file || live.size != entry.bytes) {
      return (
        state: null,
        error: 'the trashed copy changed size since the run',
      );
    }

    final digest = await _hashFile(fs, verifiedPath);
    if (digest == null || !_sha256Pattern.hasMatch(digest)) {
      return (state: null, error: 'could not hash the trashed copy');
    }
    if (entry.sha256 != null && entry.sha256 != digest) {
      return (state: null, error: 'the trashed copy is truncated or changed');
    }

    return (
      state: _ReplaceRestoreEntryState(
        transactionId: '',
        side: entry.side,
        parentPath: entry.parentPath,
        relativePath: entry.relativePath,
        trashLocation: entry.trashLocation,
        bytes: entry.bytes,
        sha256: digest,
      ),
      error: null,
    );
  } on RemoteFileException catch (error) {
    return (
      state: null,
      error: error.kind == RemoteFileErrorKind.notFound
          ? 'the trashed copy is gone'
          : 'could not verify the trashed copy: ${error.message}',
    );
  }
}

Future<String?> _verifyInitialReplaceParent({
  required RemoteFileSystem fs,
  required String root,
  required SyncSide side,
  required String parentPath,
  required SyncJournalItemLine? createdLine,
  required Map<String, SyncJournalItemLine> created,
}) async {
  final chainError = await _validateReplaceParentChain(fs, root, parentPath);
  if (chainError != null) return chainError;

  final live = await _statOrNull(fs, remoteJoin(root, parentPath));
  if (createdLine == null) {
    return live == null
        ? null
        : '"$parentPath" exists again and was changed since the run';
  }

  return _createdPostStateMismatch(
    fs: fs,
    live: live,
    createdLine: createdLine,
    created: created,
    side: side,
    relativePath: parentPath,
  );
}

Future<({String? transactionId, String? error})> _allocateReplaceRestoreStage(
  RemoteFileSystem fs,
  String root,
  String parentPath,
) async {
  for (var attempt = 0; attempt < _replaceRestoreStageAttempts; attempt++) {
    final chainError = await _validateReplaceParentChain(fs, root, parentPath);
    if (chainError != null) {
      return (transactionId: null, error: chainError);
    }

    final transactionId = secureRandomBytes(
      _replaceRestoreIdBytes,
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final stagePath = _replaceRestoreStagePath(root, parentPath, transactionId);
    if (await _statOrNull(fs, stagePath) == null) {
      return (transactionId: transactionId, error: null);
    }
  }

  return (
    transactionId: null,
    error: 'could not reserve a private restore name for "$parentPath"',
  );
}

String? _replaceRestoreStateMismatch(
  _ReplaceRestoreState state,
  List<_TrashedEntry> entries,
) {
  if (state.entries.length != entries.length) {
    return 'the replace restore journal changed since it started';
  }
  for (final entry in entries) {
    final prepared = state.entries[entry.key];
    if (prepared == null ||
        prepared.side != entry.side ||
        prepared.parentPath != entry.parentPath ||
        prepared.relativePath != entry.relativePath ||
        prepared.trashLocation != entry.trashLocation ||
        prepared.bytes != entry.bytes ||
        (entry.sha256 != null && prepared.sha256 != entry.sha256)) {
      return 'the replace restore journal changed since it started';
    }
  }
  return null;
}

Future<String?> _ensureReplaceParentStaged({
  required SyncRunJournal journal,
  required _ReplaceRestoreState state,
  required RemoteFileSystem fs,
  required String root,
  required SyncJournalItemLine? createdLine,
  required Map<String, SyncJournalItemLine> created,
}) async {
  final parentPath = remoteJoin(root, state.parentPath);
  final stagePath = _replaceRestoreStagePath(
    root,
    state.parentPath,
    state.transactionId,
  );
  var chainError = await _validateReplaceParentChain(
    fs,
    root,
    state.parentPath,
  );
  if (chainError != null) return chainError;

  final stage = await _statOrNull(fs, stagePath);

  if (state.staged) {
    if (stage == null || createdLine == null || state.childrenRestored) {
      return null;
    }
    return _createdPostStateMismatch(
      fs: fs,
      live: stage,
      createdLine: createdLine,
      created: created,
      side: state.side,
      relativePath: state.parentPath,
    );
  }

  chainError = await _validateReplaceParentChain(fs, root, state.parentPath);
  if (chainError != null) return chainError;

  final parent = await _statOrNull(fs, parentPath);
  if (createdLine == null) {
    if (parent != null || stage != null) {
      return 'the replacement for "${state.parentPath}" changed after '
          'restore started';
    }
    await journal._markReplaceRestoreStaged(state);
    return null;
  }

  if (parent != null && stage == null) {
    final mismatch = await _createdPostStateMismatch(
      fs: fs,
      live: parent,
      createdLine: createdLine,
      created: created,
      side: state.side,
      relativePath: state.parentPath,
    );
    if (mismatch != null) return mismatch;

    chainError = await _validateReplaceParentChain(fs, root, state.parentPath);
    if (chainError != null) return chainError;

    try {
      await fs.rename(parentPath, stagePath);
    } on RemoteFileException catch (error) {
      return 'could not stage the replacement: ${error.message}';
    }
  } else if (parent == null && stage != null) {
    final mismatch = await _createdPostStateMismatch(
      fs: fs,
      live: stage,
      createdLine: createdLine,
      created: created,
      side: state.side,
      relativePath: state.parentPath,
    );
    if (mismatch != null) return mismatch;
  } else {
    return 'the replacement for "${state.parentPath}" changed after '
        'restore started';
  }

  await journal._markReplaceRestoreStaged(state);
  return null;
}

Future<({String? error, bool cancelled})> _restorePreparedReplaceEntry({
  required SyncRunJournal journal,
  required _ReplaceRestoreState state,
  required _TrashedEntry entry,
  required _ReplaceRestoreEntryState prepared,
  required RemoteFileSystem fs,
  required String root,
  RemoteTransferCancellation? cancellation,
}) async {
  if (cancellation?.isCancelled ?? false) {
    return (error: null, cancelled: true);
  }

  final chainError = await _ensureChain(
    fs,
    root,
    entry.relativePath,
    cancellation: cancellation,
  );
  if (cancellation?.isCancelled ?? false) {
    return (error: null, cancelled: true);
  }
  if (chainError != null) return (error: chainError, cancelled: false);

  final origin = remoteJoin(root, entry.relativePath);
  String? sourcePath;
  RemoteFileEntry? source;
  try {
    sourcePath = await _verifiedRestoreTrashPath(journal, entry, fs);
    source = await fs.stat(sourcePath, followLinks: false);
  } on RemoteFileException catch (error) {
    if (error.kind != RemoteFileErrorKind.notFound) {
      return (
        error: 'could not verify the trashed copy: ${error.message}',
        cancelled: false,
      );
    }
  }

  if (source == null) {
    final restoredError = await _restoredEntryMismatch(fs, origin, prepared);
    if (restoredError != null) {
      return (error: restoredError, cancelled: false);
    }

    await journal._markReplaceRestoreEntry(state, prepared);
    return (error: null, cancelled: false);
  }
  if (source.type != RemoteFileType.file || source.size != prepared.bytes) {
    return (
      error: 'the trashed copy changed size since restore started',
      cancelled: false,
    );
  }
  final sourceDigest = await _hashFile(fs, sourcePath!);
  if (sourceDigest != prepared.sha256) {
    return (
      error: 'the trashed copy changed since restore started',
      cancelled: false,
    );
  }
  if (await _statOrNull(fs, origin) != null) {
    return (
      error:
          '"${entry.relativePath}" exists again and was changed since '
          'restore started',
      cancelled: false,
    );
  }

  try {
    sourcePath = await _verifiedRestoreTrashPath(journal, entry, fs);
    if (cancellation?.isCancelled ?? false) {
      return (error: null, cancelled: true);
    }

    final chainError = await _validateReplaceParentChain(
      fs,
      root,
      entry.relativePath,
    );
    if (chainError != null) {
      return (error: chainError, cancelled: false);
    }
    if (cancellation?.isCancelled ?? false) {
      return (error: null, cancelled: true);
    }

    await fs.rename(sourcePath, origin);
  } on RemoteFileException catch (error) {
    return (
      error: 'could not move the trashed copy back: ${error.message}',
      cancelled: false,
    );
  }
  await journal._markReplaceRestoreEntry(state, prepared);
  return (error: null, cancelled: false);
}

Future<String?> _restoredEntryMismatch(
  RemoteFileSystem fs,
  String origin,
  _ReplaceRestoreEntryState expected,
) async {
  final live = await _statOrNull(fs, origin);
  if (live == null) return 'the trashed copy and restore destination are gone';
  if (live.type != RemoteFileType.file || live.size != expected.bytes) {
    return '"${expected.relativePath}" changed after it was restored';
  }
  final digest = await _hashFile(fs, origin);
  return digest == expected.sha256
      ? null
      : '"${expected.relativePath}" changed after it was restored';
}

Future<String?> _replaceRestoreDestinationMismatch({
  required SyncRunJournal journal,
  required _ReplaceRestoreState state,
  required RemoteFileSystem fs,
  required String root,
}) async {
  final parent = await _statOrNull(fs, remoteJoin(root, state.parentPath));
  if (parent == null) return null;

  final entriesByPath = {
    for (final entry in state.entries.values) entry.relativePath: entry,
  };
  final parentEntry = entriesByPath[state.parentPath];
  if (!parent.isDirectory) {
    if (parentEntry == null) {
      return '"${state.parentPath}" changed after restore staging';
    }

    return _transactionOwnedRestoreEntryMismatch(
      journal: journal,
      state: state,
      entry: parentEntry,
      fs: fs,
      origin: parent.path,
    );
  }
  if (parentEntry != null) {
    return '"${state.parentPath}" changed after restore staging';
  }

  final requiredDirectories = <String>{state.parentPath};
  void addRequiredParents(String relativePath) {
    final segments = relativePath.split('/');
    final parentDepth = state.parentPath.split('/').length;
    for (var depth = parentDepth; depth < segments.length; depth++) {
      requiredDirectories.add(segments.take(depth).join('/'));
    }
  }

  for (final entry in state.entries.values) {
    addRequiredParents(entry.relativePath);
  }
  for (final line in journal.rmdirLines) {
    if (line.side != state.side || line.parentPath != state.parentPath) {
      continue;
    }

    requiredDirectories.add(line.relativePath);
    addRequiredParents('${line.relativePath}/child');
  }

  final queue = <(String, String)>[(parent.path, state.parentPath)];
  while (queue.isNotEmpty) {
    final (directory, relativeDirectory) = queue.removeLast();
    final List<RemoteFileEntry> children;
    try {
      children = await fs.listDirectory(directory);
    } on RemoteFileException catch (error) {
      return 'could not verify "$relativeDirectory": ${error.message}';
    }

    for (final child in children) {
      final relativePath = remoteJoin(relativeDirectory, child.name);
      if (child.isDirectory) {
        if (!requiredDirectories.contains(relativePath)) {
          return '"$relativePath" is new since restore staging';
        }
        queue.add((child.path, relativePath));
        continue;
      }

      final entry = entriesByPath[relativePath];
      if (entry == null) return '"$relativePath" is new since restore staging';

      final mismatch = await _transactionOwnedRestoreEntryMismatch(
        journal: journal,
        state: state,
        entry: entry,
        fs: fs,
        origin: child.path,
      );
      if (mismatch != null) return mismatch;
    }
  }

  return null;
}

Future<String?> _transactionOwnedRestoreEntryMismatch({
  required SyncRunJournal journal,
  required _ReplaceRestoreState state,
  required _ReplaceRestoreEntryState entry,
  required RemoteFileSystem fs,
  required String origin,
}) async {
  if (state.restoredEntryKeys.contains(entry.key)) {
    return _restoredEntryMismatch(fs, origin, entry);
  }

  try {
    final trashPath = await _verifiedRestoreTrashPath(
      journal,
      _TrashedEntry(
        relativePath: entry.relativePath,
        side: entry.side,
        trashLocation: entry.trashLocation,
        bytes: entry.bytes,
        sha256: entry.sha256,
        parentPath: entry.parentPath,
      ),
      fs,
    );
    if (await _statOrNull(fs, trashPath) != null) {
      return '"${entry.relativePath}" exists again and was changed since '
          'restore staging';
    }
  } on RemoteFileException catch (error) {
    if (error.kind != RemoteFileErrorKind.notFound) {
      return 'could not verify "${entry.relativePath}": ${error.message}';
    }
  }

  return _restoredEntryMismatch(fs, origin, entry);
}

Future<({String? error, bool cancelled})> _removeStagedReplacement({
  required _ReplaceRestoreState state,
  required RemoteFileSystem fs,
  required String root,
  required SyncJournalItemLine? createdLine,
  required Map<String, SyncJournalItemLine> created,
  RemoteTransferCancellation? cancellation,
}) async {
  final stagePath = _replaceRestoreStagePath(
    root,
    state.parentPath,
    state.transactionId,
  );
  var chainError = await _validateReplaceParentChain(
    fs,
    root,
    state.parentPath,
  );
  if (chainError != null) return (error: chainError, cancelled: false);

  final stage = await _statOrNull(fs, stagePath);
  if (stage == null) return (error: null, cancelled: false);
  if (createdLine == null) {
    return (error: 'an unexpected restore stage appeared', cancelled: false);
  }

  final createdDirectory =
      createdLine.action == SyncActionType.makeDirLeft ||
      createdLine.action == SyncActionType.makeDirRight;
  if (stage.isDirectory != createdDirectory) {
    return (
      error: 'the staged replacement changed since restore started',
      cancelled: false,
    );
  }
  if (!createdDirectory) {
    final mismatch = await _createdPostStateMismatch(
      fs: fs,
      live: stage,
      createdLine: createdLine,
      created: created,
      side: state.side,
      relativePath: state.parentPath,
    );
    if (mismatch != null) return (error: mismatch, cancelled: false);

    chainError = await _validateReplaceParentChain(fs, root, state.parentPath);
    if (chainError != null) return (error: chainError, cancelled: false);
    if (cancellation?.isCancelled ?? false) {
      return (error: null, cancelled: true);
    }

    await fs.delete(stage);
    return (error: null, cancelled: false);
  }

  final verified = <String, RemoteFileEntry>{};
  final mismatch = await _remainingCreatedTreeMismatch(
    created,
    stage,
    fs,
    state.side,
    state.parentPath,
    verified,
  );
  if (mismatch != null) return (error: mismatch, cancelled: false);

  chainError = await _validateReplaceParentChain(fs, root, state.parentPath);
  if (chainError != null) return (error: chainError, cancelled: false);
  if (cancellation?.isCancelled ?? false) {
    return (error: null, cancelled: true);
  }

  final removed = await _removeVerifiedTree(
    fs,
    stage,
    verified,
    cancellation: cancellation,
  );
  return (error: null, cancelled: !removed);
}

Future<({String? error, bool cancelled})> _restoreReplaceDirectories({
  required SyncRunJournal journal,
  required _ReplaceRestoreState state,
  required RemoteFileSystem fs,
  required String root,
  RemoteTransferCancellation? cancellation,
}) async {
  final directories =
      journal.rmdirLines
          .where(
            (line) =>
                line.side == state.side && line.parentPath == state.parentPath,
          )
          .toList()
        ..sort(
          (a, b) =>
              a.relativePath.split('/').length -
              b.relativePath.split('/').length,
        );

  for (final line in directories) {
    if (cancellation?.isCancelled ?? false) {
      return (error: null, cancelled: true);
    }

    var chainError = await _validateReplaceParentChain(
      fs,
      root,
      line.relativePath,
    );
    if (chainError != null) return (error: chainError, cancelled: false);

    final path = remoteJoin(root, line.relativePath);
    final existing = await _statOrNull(fs, path);
    if (existing != null) {
      if (existing.isDirectory) continue;
      return (
        error: '"${line.relativePath}" is a file now; cannot restore it',
        cancelled: false,
      );
    }

    chainError = await _validateReplaceParentChain(fs, root, line.relativePath);
    if (chainError != null) return (error: chainError, cancelled: false);
    if (cancellation?.isCancelled ?? false) {
      return (error: null, cancelled: true);
    }

    try {
      await fs.createDirectory(path);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.conflict) {
        return (
          error: 'could not recreate "${line.relativePath}": ${error.message}',
          cancelled: false,
        );
      }
      final winner = await _statOrNull(fs, path);
      if (winner == null || !winner.isDirectory) {
        return (
          error: '"${line.relativePath}" is not a directory now',
          cancelled: false,
        );
      }
    }
  }

  return (error: null, cancelled: cancellation?.isCancelled ?? false);
}

Map<String, String?> _completedReplaceOutcomes(
  List<_TrashedEntry> entries,
  _ReplaceRestoreState state,
) => {
  for (final entry in entries)
    if (state.restoredEntryKeys.contains(entry.key)) entry.key: null,
};

Map<String, String?> _replaceGroupSuccess(List<_TrashedEntry> entries) => {
  for (final entry in entries) entry.key: null,
};

Map<String, String?> _replaceGroupFailure(
  List<_TrashedEntry> entries,
  _ReplaceRestoreState? state,
  String reason, {
  String? invalidEntryKey,
}) => {
  for (final entry in entries)
    entry.key:
        state != null &&
            state.restoredEntryKeys.contains(entry.key) &&
            entry.key != invalidEntryKey
        ? null
        : reason,
};

String _replaceRestoreStagePath(
  String root,
  String parentPath,
  String transactionId,
) {
  final absoluteParent = remoteJoin(root, parentPath);
  return remoteJoin(
    remoteParent(absoluteParent),
    '$_replaceRestoreStagePrefix$transactionId',
  );
}

String _journalTrashRootForSide(
  SyncRunJournal journal,
  SyncSide side,
  String syncRoot,
) {
  final configured = switch (side) {
    SyncSide.left => journal.record.rules.trashPathLeft,
    SyncSide.right => journal.record.rules.trashPathRight,
  };
  return configured ?? remoteJoin(syncRoot, RemoteTrash.rootDirectoryName);
}

/// Restores one non-grouped trashed entry; returns null on success or its
/// skip reason. Rule-4 replace children use [_restoreReplaceGroup].
Future<String?> _restoreOne({
  required SyncRunJournal journal,
  required _TrashedEntry entry,
  required RemoteFileSystem fs,
  required String root,
  required String origin,
  required Map<String, SyncJournalItemLine> created,
}) async {
  var verifiedTrashPath = entry.trashLocation;
  Future<String?> verifyTrashPath() async {
    try {
      verifiedTrashPath = await _verifiedRestoreTrashPath(journal, entry, fs);
      return null;
    } on RemoteFileException catch (error) {
      return 'could not verify the trashed copy: ${error.message}';
    }
  }

  // Verify the trashed entry itself: size always; the recorded digest
  // for copy-fallback entries (05 §8 rail 9 — a rename cannot
  // truncate, an interrupted copy can, and Undo must never resurrect a
  // truncated "previous version" over a good file).
  final RemoteFileEntry trashedEntry;
  try {
    final pathError = await verifyTrashPath();
    if (pathError != null) return pathError;
    trashedEntry = await fs.stat(verifiedTrashPath, followLinks: false);
  } on RemoteFileException catch (error) {
    return error.kind == RemoteFileErrorKind.notFound
        ? 'the trashed copy is gone'
        : 'could not inspect the trashed copy: ${error.message}';
  }
  if (trashedEntry.type != RemoteFileType.file ||
      trashedEntry.size != entry.bytes) {
    return 'the trashed copy changed size since the run';
  }
  final expectedHash = entry.sha256;
  if (expectedHash != null) {
    final pathError = await verifyTrashPath();
    if (pathError != null) return pathError;
    final digest = await _hashFile(fs, verifiedTrashPath);
    if (digest != expectedHash) {
      return 'the trashed copy is truncated or changed';
    }
  }

  final mutationPathError = await verifyTrashPath();
  if (mutationPathError != null) return mutationPathError;

  // Recreate the chain before clearing the destination, so a blocked
  // ancestor cannot strand the source after the post-state is removed.
  final chainError = await _ensureChain(fs, root, entry.relativePath);
  if (chainError != null) return chainError;
  final clearError = await _clearOwnPostState(
    entry: entry,
    fs: fs,
    origin: origin,
    createdLine: created['${entry.side.name}:${entry.relativePath}'],
    created: created,
  );
  if (clearError != null) return clearError;

  try {
    await fs.rename(verifiedTrashPath, origin);
  } on RemoteFileException catch (error) {
    return 'could not move the trashed copy back: ${error.message}';
  }
  return null;
}

/// Confirms the live entry at [origin] still matches the run's recorded
/// post-state for a self-path trash entry (deletion, update backup, or
/// same-path single-file replace) and removes it so the trashed
/// original can return. A mismatch is reported, never overwritten.
Future<String?> _clearOwnPostState({
  required _TrashedEntry entry,
  required RemoteFileSystem fs,
  required String origin,
  required SyncJournalItemLine? createdLine,
  required Map<String, SyncJournalItemLine> created,
}) async {
  final live = await _statOrNull(fs, origin);
  if (createdLine == null) {
    // A deletion's post-state is absence — anything present now is
    // newer work Undo must not touch.
    if (live != null) {
      return '"${entry.relativePath}" exists again and was changed '
          'since the run';
    }
    return null;
  }
  return _clearCreated(
    entry: entry,
    fs: fs,
    live: live,
    createdLine: createdLine,
    created: created,
    displayPath: entry.relativePath,
  );
}

/// The shared post-state check for a run-created entry: file → size +
/// observedMtimeAfterWrite; directory → the recorded end-of-run entry
/// set. Removes the entry once verified.
Future<String?> _clearCreated({
  required _TrashedEntry entry,
  required RemoteFileSystem fs,
  required RemoteFileEntry? live,
  required SyncJournalItemLine createdLine,
  required Map<String, SyncJournalItemLine> created,
  required String displayPath,
}) async {
  final verified = <String, RemoteFileEntry>{};
  final mismatch = await _createdPostStateMismatch(
    fs: fs,
    live: live,
    createdLine: createdLine,
    created: created,
    side: entry.side,
    relativePath: displayPath,
    verified: verified,
  );
  if (mismatch != null) return mismatch;

  switch (createdLine.action) {
    case SyncActionType.makeDirLeft || SyncActionType.makeDirRight:
      // A rule-4 replace that created a directory: the recorded
      // post-state is its end-of-run entry set. Verify the whole set,
      // then remove entry+set, then the caller's chain recreation and
      // reverse renames restore the original tree.
      // Delete exactly the verified snapshot — a re-list could catch
      // entries that arrived between check and removal.
      await _removeVerifiedTree(fs, live!, verified);
      return null;
    default:
      // Update/copy replace: the written file must still match its
      // recorded size + observed mtime.
      await fs.delete(live!);
      return null;
  }
}

Future<String?> _createdPostStateMismatch({
  required RemoteFileSystem fs,
  required RemoteFileEntry? live,
  required SyncJournalItemLine createdLine,
  required Map<String, SyncJournalItemLine> created,
  required SyncSide side,
  required String relativePath,
  Map<String, RemoteFileEntry>? verified,
}) async {
  if (live == null) return '"$relativePath" is missing since the run';

  switch (createdLine.action) {
    case SyncActionType.makeDirLeft || SyncActionType.makeDirRight:
      if (!live.isDirectory) return '"$relativePath" changed since the run';

      return _dirPostStateMismatch(
        created,
        live,
        fs,
        side,
        relativePath,
        verified ?? <String, RemoteFileEntry>{},
      );
    default:
      if (live.type != RemoteFileType.file ||
          live.size != createdLine.bytes ||
          _seconds(live.modifiedAt) != createdLine.observedMtimeAfterWrite) {
        return '"$relativePath" changed since the run';
      }
      return null;
  }
}

/// Whether the created directory's live contents diverge from the
/// run's recorded end-of-run entry set — any file that no longer
/// matches its post-state, or anything present the run did not
/// record, skips the whole revert (05 §8 rail 9).
Future<String?> _dirPostStateMismatch(
  Map<String, SyncJournalItemLine> created,
  RemoteFileEntry live,
  RemoteFileSystem fs,
  SyncSide side,
  String relativePath,
  Map<String, RemoteFileEntry> liveEntries,
) async {
  final prefix = '$relativePath/';
  final expected = <String, SyncJournalItemLine>{
    for (final e in created.entries)
      if (e.key.startsWith('${side.name}:$prefix'))
        e.key.substring(side.name.length + 1): e.value,
  };
  // Keys are plan-style relative paths — built from entry names, not
  // substring surgery on absolute paths (listed local paths carry
  // the platform separator, which must never leak into a key).
  final queue = <(String, String)>[(live.path, relativePath)];
  while (queue.isNotEmpty) {
    final (dir, rel) = queue.removeLast();
    final List<RemoteFileEntry> listing;
    try {
      listing = await fs.listDirectory(dir);
    } on RemoteFileException catch (error) {
      return 'could not list "$relativePath": ${error.message}';
    }
    for (final child in listing) {
      final relative = remoteJoin(rel, child.name);
      liveEntries[relative] = child;
      if (child.isDirectory) queue.add((child.path, relative));
    }
  }
  for (final expectedEntry in expected.entries) {
    final liveChild = liveEntries[expectedEntry.key];
    if (liveChild == null) {
      return '"${expectedEntry.key}" is missing since the run';
    }
    final line = expectedEntry.value;
    final isDirAction =
        line.action == SyncActionType.makeDirLeft ||
        line.action == SyncActionType.makeDirRight;
    if (isDirAction) {
      if (!liveChild.isDirectory) {
        return '"${expectedEntry.key}" changed kind since the run';
      }
    } else if (liveChild.type != RemoteFileType.file ||
        liveChild.size != line.bytes ||
        _seconds(liveChild.modifiedAt) != line.observedMtimeAfterWrite) {
      return '"${expectedEntry.key}" changed since the run';
    }
  }
  for (final path in liveEntries.keys) {
    if (!expected.containsKey(path)) {
      return '"$path" is new since the run';
    }
  }
  return null;
}

/// Validates the surviving subset of a staged created tree during cleanup.
/// Missing expected entries are allowed because an earlier cleanup attempt may
/// have deleted them; unknown or changed survivors are never removed.
Future<String?> _remainingCreatedTreeMismatch(
  Map<String, SyncJournalItemLine> created,
  RemoteFileEntry live,
  RemoteFileSystem fs,
  SyncSide side,
  String relativePath,
  Map<String, RemoteFileEntry> liveEntries,
) async {
  final prefix = '$relativePath/';
  final expected = <String, SyncJournalItemLine>{
    for (final entry in created.entries)
      if (entry.key.startsWith('${side.name}:$prefix'))
        entry.key.substring(side.name.length + 1): entry.value,
  };
  final queue = <(String, String)>[(live.path, relativePath)];
  while (queue.isNotEmpty) {
    final (directory, rel) = queue.removeLast();
    final List<RemoteFileEntry> listing;
    try {
      listing = await fs.listDirectory(directory);
    } on RemoteFileException catch (error) {
      return 'could not list "$relativePath": ${error.message}';
    }
    for (final child in listing) {
      final childRelative = remoteJoin(rel, child.name);
      liveEntries[childRelative] = child;
      if (child.isDirectory) queue.add((child.path, childRelative));
    }
  }

  for (final liveEntry in liveEntries.entries) {
    final line = expected[liveEntry.key];
    if (line == null) return '"${liveEntry.key}" is new since the run';

    final child = liveEntry.value;
    final isDirectory =
        line.action == SyncActionType.makeDirLeft ||
        line.action == SyncActionType.makeDirRight;
    if (isDirectory) {
      if (!child.isDirectory) {
        return '"${liveEntry.key}" changed kind since the run';
      }
      continue;
    }
    if (child.type != RemoteFileType.file ||
        child.size != line.bytes ||
        _seconds(child.modifiedAt) != line.observedMtimeAfterWrite) {
      return '"${liveEntry.key}" changed since the run';
    }
  }
  return null;
}

/// Removes a verified created directory together with exactly the
/// entry set the post-state check verified — the one place v1 undo
/// removes run-created copies (05 §8 rail 9). Deepest-first via
/// descending path order (a child's path always sorts after its
/// parent's); an entry already gone is fine.
Future<bool> _removeVerifiedTree(
  RemoteFileSystem fs,
  RemoteFileEntry live,
  Map<String, RemoteFileEntry> verified, {
  RemoteTransferCancellation? cancellation,
}) async {
  final sorted = verified.values.toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  for (final entry in sorted) {
    if (cancellation?.isCancelled ?? false) return false;

    try {
      await fs.delete(entry);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
    }
  }
  if (cancellation?.isCancelled ?? false) return false;

  try {
    await fs.delete(live);
  } on RemoteFileException catch (error) {
    if (error.kind != RemoteFileErrorKind.notFound) rethrow;
  }
  return true;
}

/// Confines restore staging to the canonical sync root. Every surviving
/// ancestor is checked without following links before stage I/O.
Future<String?> _validateReplaceParentChain(
  RemoteFileSystem fs,
  String root,
  String relativePath,
) async {
  final pathError = _restoreRelativePathError(root, relativePath);
  if (pathError != null) return pathError;

  final rootError = await _restoreRootError(fs, root);
  if (rootError != null) return rootError;

  final segments = relativePath.split('/');

  try {
    var current = root;
    for (var i = 0; i < segments.length - 1; i++) {
      current = remoteJoin(current, segments[i]);
      final entry = await fs.stat(current, followLinks: false);
      if (entry.isSymbolicLink || !entry.isDirectory) {
        final ancestor = segments.take(i + 1).join('/');
        return '"$ancestor" is not a real directory; '
            'cannot stage restore inside it';
      }
    }
  } on RemoteFileException catch (error) {
    return 'could not validate restore destination: ${error.message}';
  }

  return null;
}

/// Recreates every missing ancestor of [relativePath] under [root],
/// shallowest-first. A missing level is created; an existing directory
/// is fine (EEXIST-tolerant per 05 §8 rail 9); a file in the chain
/// blocks the restore.
Future<String?> _ensureChain(
  RemoteFileSystem fs,
  String root,
  String relativePath, {
  RemoteTransferCancellation? cancellation,
}) async {
  final pathError = _restoreRelativePathError(root, relativePath);
  if (pathError != null) return pathError;

  final rootError = await _restoreRootError(fs, root);
  if (rootError != null) return rootError;

  final segments = relativePath.split('/');
  var current = root;
  for (var i = 0; i < segments.length - 1; i++) {
    if (cancellation?.isCancelled ?? false) return null;

    current = remoteJoin(current, segments[i]);
    final existing = await _statOrNull(fs, current);
    if (existing == null) {
      if (cancellation?.isCancelled ?? false) return null;

      try {
        final mutationRootError = await _restoreRootError(fs, root);
        if (mutationRootError != null) return mutationRootError;

        await fs.createDirectory(current);
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.conflict) {
          return 'could not recreate "${segments.take(i + 1).join('/')}"'
              ': ${error.message}';
        }
        // EEXIST — but only a directory winner counts as success.
        final winner = await _statOrNull(fs, current);
        if (winner != null && !winner.isDirectory) {
          return '"${segments.take(i + 1).join('/')}" is a file now; '
              'cannot restore inside it';
        }
      }
      continue;
    }
    if (existing.isSymbolicLink || !existing.isDirectory) {
      return '"${segments.take(i + 1).join('/')}" is a file now; '
          'cannot restore inside it';
    }
  }
  return null;
}

Future<RemoteFileEntry?> _statOrNull(RemoteFileSystem fs, String path) async {
  try {
    return await fs.stat(path, followLinks: false);
  } on RemoteFileException catch (error) {
    if (error.kind == RemoteFileErrorKind.notFound) return null;
    rethrow;
  }
}

/// Streams a file through the VFS's own hashing download and returns
/// its digest — the restore-side verify for copy-fallback trash
/// entries.
Future<String?> _hashFile(RemoteFileSystem fs, String path) async {
  final sink = _HashNullSink();
  final entry = await fs.download(path, sink);
  return entry.contentSha256;
}

final class _HashNullSink implements StreamSink<List<int>> {
  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}

int? _seconds(DateTime? time) =>
    time == null ? null : (time.millisecondsSinceEpoch / 1000).floor();

// ── Serialization ──────────────────────────────────────────────────────

Map<String, Object?> _recordToJson(SyncRunRecord record) => <String, Object?>{
  'runId': record.runId,
  'pairId': record.pairId,
  'startedAt': record.startedAt.toIso8601String(),
  if (record.canonicalRootLeft != null)
    'canonicalRootLeft': record.canonicalRootLeft,
  if (record.canonicalRootRight != null)
    'canonicalRootRight': record.canonicalRootRight,
  if (record.trashScopeLeft != null) 'trashScopeLeft': record.trashScopeLeft,
  if (record.trashScopeRight != null) 'trashScopeRight': record.trashScopeRight,
  if (record.trashLocationKeyLeft != null)
    'trashLocationKeyLeft': record.trashLocationKeyLeft,
  if (record.trashLocationKeyRight != null)
    'trashLocationKeyRight': record.trashLocationKeyRight,
  'rules': _rulesToJson(record.rules),
  'totals': _totalsToJson(record.totals),
  'warnings': [
    for (final warning in record.warnings)
      <String, Object?>{
        'path': warning.relativePath,
        'side': warning.side.name,
        'message': warning.message,
        'kind': warning.kind.name,
      },
  ],
};

SyncRunRecord _recordFromJson(Map<String, Object?> json) => SyncRunRecord(
  runId: json['runId']! as String,
  pairId: json['pairId']! as String,
  startedAt: DateTime.parse(json['startedAt']! as String),
  canonicalRootLeft: json['canonicalRootLeft'] as String?,
  canonicalRootRight: json['canonicalRootRight'] as String?,
  trashScopeLeft: json['trashScopeLeft'] as String?,
  trashScopeRight: json['trashScopeRight'] as String?,
  trashLocationKeyLeft: json['trashLocationKeyLeft'] as String?,
  trashLocationKeyRight: json['trashLocationKeyRight'] as String?,
  rules: _rulesFromJson(json['rules']! as Map<String, Object?>),
  totals: _totalsFromJson(json['totals']! as Map<String, Object?>),
  warnings: [
    for (final warning in json['warnings']! as List<Object?>)
      ScanWarning(
        relativePath: (warning! as Map<String, Object?>)['path']! as String,
        side: SyncSide.values.byName(
          (warning as Map<String, Object?>)['side']! as String,
        ),
        message: warning['message']! as String,
        // Older journals carry no kind; the informational fallback
        // keeps replay honest (a listing failure is only meaningful
        // to planning, which always sees a fresh scan).
        kind: _warningKindFromJson(warning['kind']),
      ),
  ],
);

/// Tolerant kind decode: absent or unrecognized values land on the
/// informational bucket rather than throwing inside replay.
ScanWarningKind _warningKindFromJson(Object? value) {
  for (final kind in ScanWarningKind.values) {
    if (kind.name == value) return kind;
  }
  return ScanWarningKind.malformedName;
}

Map<String, Object?> _rulesToJson(SyncRuleSet rules) => <String, Object?>{
  'direction': rules.direction.name,
  'deletions': rules.deletions.name,
  'backups': rules.backups.name,
  'comparison': rules.comparison.name,
  'mtimeToleranceSecs': rules.mtimeToleranceSecs,
  'acceptedTimeShifts': rules.acceptedTimeShifts,
  'conflictDefault': rules.conflictDefault.name,
  'excludeGlobs': rules.excludeGlobs,
  'includeHidden': rules.includeHidden,
  'symlinks': rules.symlinks.name,
  'trashPathLeft': rules.trashPathLeft,
  'trashPathRight': rules.trashPathRight,
  'maxDelete': rules.maxDelete,
  'deleteFractionWarn': rules.deleteFractionWarn,
  'preserveMtime': rules.preserveMtime,
  'transferConcurrency': rules.transferConcurrency,
};

SyncRuleSet _rulesFromJson(Map<String, Object?> json) => SyncRuleSet(
  direction: SyncDirection.values.byName(json['direction']! as String),
  deletions: DeletionPolicy.values.byName(json['deletions']! as String),
  backups: BackupPolicy.values.byName(json['backups']! as String),
  comparison: ComparisonMode.values.byName(json['comparison']! as String),
  mtimeToleranceSecs: json['mtimeToleranceSecs']! as int,
  acceptedTimeShifts: [
    for (final value in json['acceptedTimeShifts']! as List<Object?>)
      value! as int,
  ],
  conflictDefault: ConflictDefault.values.byName(
    json['conflictDefault']! as String,
  ),
  excludeGlobs: [
    for (final value in json['excludeGlobs']! as List<Object?>)
      value! as String,
  ],
  includeHidden: json['includeHidden']! as bool,
  symlinks: SymlinkPolicy.values.byName(json['symlinks']! as String),
  trashPathLeft: json['trashPathLeft'] as String?,
  trashPathRight: json['trashPathRight'] as String?,
  maxDelete: json['maxDelete']! as int,
  deleteFractionWarn: json['deleteFractionWarn']! as double,
  preserveMtime: json['preserveMtime']! as bool,
  transferConcurrency: json['transferConcurrency']! as int,
);

Map<String, Object?> _totalsToJson(PlanTotals totals) => <String, Object?>{
  'counts': {
    for (final entry in totals.counts.entries) entry.key.name: entry.value,
  },
  'bytes': {
    for (final entry in totals.bytes.entries) entry.key.name: entry.value,
  },
  'replacedFiles': totals.replacedFiles,
  'replacedBytes': totals.replacedBytes,
};

PlanTotals _totalsFromJson(Map<String, Object?> json) => PlanTotals(
  counts: {
    for (final entry in (json['counts']! as Map<String, Object?>).entries)
      SyncActionType.values.byName(entry.key): entry.value! as int,
  },
  bytes: {
    for (final entry in (json['bytes']! as Map<String, Object?>).entries)
      SyncActionType.values.byName(entry.key): entry.value! as int,
  },
  replacedFiles: json['replacedFiles']! as int,
  replacedBytes: json['replacedBytes']! as int,
);

SyncJournalItemLine _itemFromJson(Map<String, Object?> json) =>
    SyncJournalItemLine(
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      action: SyncActionType.values.byName(json['action']! as String),
      outcome: SyncItemStatus.values.byName(json['outcome']! as String),
      attempt: json['attempt']! as int,
      bytes: json['bytes']! as int,
      durationMs: json['durationMs']! as int,
      userOverridden: json['userOverridden']! as bool,
      trashLocation: json['trashLocation'] as String?,
      trashBytes: json['trashBytes'] as int?,
      trashContentSha256: json['trashContentSha256'] as String?,
      observedMtimeAfterWrite: json['observedMtimeAfterWrite'] as int?,
      setstatIgnored: json['setstatIgnored'] == true,
      error: json['error'] as String?,
    );

SyncJournalTrashLine _trashFromJson(Map<String, Object?> json) =>
    SyncJournalTrashLine(
      parentPath: json['parent']! as String,
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      trashLocation: json['trashLocation']! as String,
      bytes: json['bytes']! as int,
      trashContentSha256: json['trashContentSha256'] as String?,
    );

SyncJournalRemoveLine _removeFromJson(Map<String, Object?> json) =>
    SyncJournalRemoveLine(
      parentPath: json['parent']! as String,
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      bytes: json['bytes']! as int,
    );

SyncJournalRmdirLine _rmdirFromJson(Map<String, Object?> json) =>
    SyncJournalRmdirLine(
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      parentPath: json['parent']! as String,
    );

SyncJournalSummary _summaryFromJson(Map<String, Object?> json) =>
    SyncJournalSummary(
      counts: {
        for (final entry in (json['counts']! as Map<String, Object?>).entries)
          SyncItemStatus.values.byName(entry.key): entry.value! as int,
      },
      bytesTransferred: json['bytesTransferred']! as int,
      cancelled: json['cancelled']! as bool,
      mtimeUnreliableLeft: json['mtimeUnreliableLeft']! as bool,
      mtimeUnreliableRight: json['mtimeUnreliableRight']! as bool,
    );
