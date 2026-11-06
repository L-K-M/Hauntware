/// 04 §3.1 — `PersistentLocalRecordStore`: the JSON-file-backed
/// [LocalRecordStore] that gives the sync engine real dirty tracking,
/// delta pulls, and tombstone retention across rounds and restarts.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_protocol/seance_protocol.dart';

import '../sync/local_record_store.dart';
import 'atomic_file_writer.dart';

/// The authenticated account whose local sync mirror this device is opening.
///
/// [baseUrl] is stored exactly as supplied. Callers must normalize it before
/// construction so harmless spelling differences, such as a trailing slash,
/// do not discard a valid mirror. Usernames remain case-sensitive because the
/// sync server treats them as account identifiers.
final class SyncAccountScope {
  factory SyncAccountScope({
    required String baseUrl,
    required String username,
  }) {
    if (baseUrl.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must not be empty');
    }
    if (username.isEmpty) {
      throw ArgumentError.value(username, 'username', 'must not be empty');
    }
    return SyncAccountScope._(baseUrl, username);
  }

  const SyncAccountScope._(this.baseUrl, this.username);

  final String baseUrl;
  final String username;

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl, 'username': username};

  factory SyncAccountScope.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        json['baseUrl'] is! String ||
        json['username'] is! String) {
      throw const FormatException('record store account scope');
    }
    return SyncAccountScope(
      baseUrl: json['baseUrl'] as String,
      username: json['username'] as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncAccountScope &&
      other.baseUrl == baseUrl &&
      other.username == username;

  @override
  int get hashCode => Object.hash(baseUrl, username);
}

/// The bookkeeping beyond the pinned [LocalRecordStore] contract that
/// 04 §3.2's apply pass needs: the apply cursor (`lastAppliedSeq`,
/// persisted exactly like `highWaterSeq`), the full-resync reset, and the
/// displaced-winner resurface for a push that loses server-side.
abstract interface class SyncRecordStore implements LocalRecordStore {
  /// Settle only the operation actually sent to the server. A local edit may
  /// replace it while the push is in flight, even within the same clock tick.
  /// The identity check and mutation must share the store's write queue.
  /// Returns a restored remote winner for a rejected, still-current operation:
  /// the pulled winner that edit displaced is the copy the server still
  /// holds, so it is the true winner and the losing edit must not keep its
  /// slot (04 §3.2's "re-evaluation when the pending local rival next pushes
  /// — including the push-ties-or-LOSES case").
  Future<EncryptedRecord?> settlePush(EncryptedRecord sent, PushResult result);

  /// The highest server seq already materialized into the domain stores.
  /// `RecordCoordinator.applyPulled` advances it only past records that
  /// were applied or superseded that round — never past a seen-but-deferred
  /// one, which a delta pull would never re-deliver.
  Future<int> lastAppliedSeq();

  /// Persist the apply cursor. Monotone: a lower value is ignored; the
  /// full-resync fallback zeroes it through [resetSyncCursors] instead.
  Future<void> setLastAppliedSeq(int seq);

  /// Zero both cursors (04 §3.1's one-time full-resync fallback: the next
  /// pull runs `since = 0` and `applyPulled` re-scans the lifetime set —
  /// every record a no-op tie or a real apply).
  Future<void> resetSyncCursors();

  /// Every displaced pulled winner currently parked behind a dirty local
  /// rival — the apply pass reports these as deferred (their re-check is
  /// triggered by the rival's next push, not by the seq scan).
  Future<List<EncryptedRecord>> displacedRecords();
}

/// The quarantine name for a corrupt record store at [path]: a UTC stamp
/// plus an existence-checked counter so a same-timestamp second corruption
/// cannot overwrite the first rescue copy — which may hold the only copy
/// of unpushed dirty edits (04 §3.1). Exposed for tests.
String recordStoreQuarantinePath(String path, DateTime now, int n) =>
    '$path.corrupt-${_stamp(now)}-$n';

String _stamp(DateTime now) => now
    .toUtc()
    .toIso8601String()
    .replaceAll('-', '')
    .replaceAll(':', '')
    .replaceAll('.', '');

/// A [SyncRecordStore] backed by one JSON file:
///
/// ```json
/// { "version": 1,
///   "highWaterSeq": 41,
///   "lastAppliedSeq": 40,
///   "recordEnvelopeFloor": 2,
///   "cursorRecoveryPending": true,
///   "records":   [ {"...EncryptedRecord json...", "dirty": false} ],
///   "displaced": [ {"...EncryptedRecord json..."} ] }
/// ```
///
/// When [scope] is supplied the document is version 2 and adds an `account`
/// object containing its normalized base URL and exact username. Unscoped
/// consumers retain the version 1 shape so their established bytes and
/// migrations do not change.
///
/// Written atomically after every mutation through the house temp+rename
/// writer ([AtomicFileWriter.write]). Tombstones are retained
/// indefinitely (04 §3.2 — no GC: any window risks resurrecting a deletion
/// through a long-offline device). A corrupt file is quarantined under a
/// unique per-occurrence name and the store restarts empty; the caller
/// surfaces the durable Settings → Backup notice and drives
/// `RecordCoordinator.reSealAfterStoreLoss`. A newer `version` fails
/// closed in place — data this build must not overwrite.
final class PersistentLocalRecordStore
    implements
        SyncRecordStore,
        PushSettlingRecordStore,
        LocalPublicationStore,
        RecoverableSyncCursorStore,
        RecordEnvelopeFloorStore {
  PersistentLocalRecordStore({
    required String path,
    this.scope,
    this.adoptLegacy = false,
    this.resetExisting = false,
    Future<void> Function(File target, String contents)? atomicWriter,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
  }) : // Keep the filesystem path immutable and private.
       // ignore: prefer_initializing_formals
       _file = File(path),
       _atomicWriter = atomicWriter ?? const AtomicFileWriter().write,
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _onError = onError {
    if (scope == null && (adoptLegacy || resetExisting)) {
      throw ArgumentError(
        'adoptLegacy and resetExisting require an account scope',
      );
    }
  }

  static const _legacyStoreVersion = 1;
  static const _scopedStoreVersion = 2;

  final File _file;
  final SyncAccountScope? scope;

  /// Whether a valid legacy v1 document may be claimed by [scope].
  ///
  /// Set this only for an account already present in durable settings at app
  /// startup. Explicit enrollment must reset an unclaimed legacy mirror.
  final bool adoptLegacy;

  /// Clears a valid document even when it already carries [scope]. This is
  /// used after explicit enrollment, where a deleted and recreated account
  /// can have the same endpoint and username but a different server history.
  final bool resetExisting;

  final Future<void> Function(File target, String contents) _atomicWriter;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? _onError;

  final _records = <String, EncryptedRecord>{};
  final _dirty = <String>{};

  /// The pulled winners a dirty local edit displaced (04 §3.2's deferred
  /// re-check): when the local rival's push is rejected, the server's copy
  /// is still this record — [settlePush] puts it back so the losing
  /// edit cannot keep the slot or the materialized row.
  final _displaced = <String, EncryptedRecord>{};

  int _highWaterSeq = 0;
  int _lastAppliedSeq = 0;
  bool _cursorRecoveryPending = false;
  int _recordEnvelopeFloor = kLegacyRecordEnvelopeVersion;

  /// Set when a corrupt file was quarantined during load — the durable
  /// recovery-notice seam (04 §3.1): the app reads it once to surface the
  /// "deleted bookmarks may reappear" warning and trigger the re-seal.
  String? quarantinedPath;

  Future<void>? _loadFuture;
  Future<void> _writeTail = Future.value();

  /// Loads, validates, and, for a scoped store, durably binds the file before
  /// the caller publishes that account as active.
  Future<void> initialize() => _ensureLoaded();

  @override
  Future<List<EncryptedRecord>> allRecords() async {
    await _writeTail;
    await _ensureLoaded();
    return List.unmodifiable(_records.values);
  }

  @override
  Future<EncryptedRecord?> getRecord(String id) async {
    await _writeTail;
    await _ensureLoaded();
    return _records[id];
  }

  @override
  Future<List<EncryptedRecord>> displacedRecords() async {
    await _writeTail;
    await _ensureLoaded();
    return List.unmodifiable(_displaced.values);
  }

  /// A local change: marks dirty and persists. When it evicts a clean server
  /// copy, that copy is stashed in [_displaced]. A rejection or publication
  /// opt-out can then restore the server state already below the pull cursor.
  @override
  Future<void> putLocal(EncryptedRecord record) => _mutate((candidate) {
    final existing = candidate.records[record.id];
    if (existing != null && !candidate.dirty.contains(record.id)) {
      candidate.displaced[record.id] = existing;
    }
    candidate.records[record.id] = record;
    candidate.dirty.add(record.id);
  });

  /// A pulled record: stored clean. Never overwrites a dirty local that
  /// beats it — and a remote that loses to a pending local becomes the
  /// displaced resurface candidate, since it is the copy the server holds.
  /// A remote that out-tuples a pending local replaces it and clears the
  /// dirty flag: the unpushed edit is discarded without reaching the
  /// server — the LWW semantics 04 §3.1 pins on the shared tuple.
  @override
  Future<void> putRemote(EncryptedRecord record) => _mutate((candidate) {
    final existing = candidate.records[record.id];
    if (existing != null) {
      final winner = Lww.resolve(existing, record);
      assert(
        identical(winner, existing) || identical(winner, record),
        'Lww.resolve must return one of its arguments — '
        'displaced-winner tracking relies on reference identity',
      );
      if (!identical(winner, record)) {
        if (candidate.dirty.contains(record.id)) {
          candidate.displaced[record.id] = record;
        }
        return;
      }
    }
    candidate.records[record.id] = record;
    candidate.dirty.remove(record.id);
    // The just-pulled record is the server's current winner: any
    // stashed rival predates it and can never resurface.
    candidate.displaced.remove(record.id);
  });

  @override
  Future<List<EncryptedRecord>> dirtyRecords() async {
    await _writeTail;
    await _ensureLoaded();
    return List.unmodifiable(_dirty.map((id) => _records[id]!));
  }

  /// The server accepted the push: stamp the assigned seq, clear dirty,
  /// and drop any displaced rival — it can never win now.
  @override
  Future<void> markSynced(String id, int seq) => _mutate((candidate) {
    final record = candidate.records[id];
    if (record != null) candidate.records[id] = record.withSeq(seq);
    candidate.dirty.remove(id);
    candidate.displaced.remove(id);
  });

  @override
  Future<EncryptedRecord?> settlePush(
    EncryptedRecord sent,
    PushResult result,
  ) async {
    if (result.id != sent.id) {
      throw ArgumentError('push result must identify the sent record');
    }
    return _mutate((candidate) {
      if (!identical(candidate.records[sent.id], sent) ||
          !candidate.dirty.contains(sent.id)) {
        return null;
      }
      if (result.accepted) {
        candidate.records[sent.id] = sent.withSeq(result.seq);
        candidate.dirty.remove(sent.id);
        candidate.displaced.remove(sent.id);
        return null;
      }
      final restored = candidate.displaced.remove(sent.id);
      if (restored != null && restored.seq == result.seq) {
        candidate.records[sent.id] = restored;
        candidate.dirty.remove(sent.id);
        return restored;
      }
      // The pull observed a different server winner after this copy was
      // displaced. Keep the edit dirty so that winner can reconcile it on
      // a later pull instead of resurrecting stale mirror state.
      return null;
    });
  }

  @override
  Future<void> cancelLocal(String id) => _mutate((candidate) {
    if (!candidate.dirty.remove(id)) return;
    final restored = candidate.displaced.remove(id);
    if (restored == null) {
      candidate.records.remove(id);
    } else {
      candidate.records[id] = restored;
    }
  });

  @override
  Future<int> highWaterSeq() async {
    await _writeTail;
    await _ensureLoaded();
    return _highWaterSeq;
  }

  @override
  Future<void> setHighWaterSeq(int seq) => _mutate((candidate) {
    if (seq > candidate.highWaterSeq) candidate.highWaterSeq = seq;
  });

  @override
  Future<int> lastAppliedSeq() async {
    await _writeTail;
    await _ensureLoaded();
    return _lastAppliedSeq;
  }

  @override
  Future<void> setLastAppliedSeq(int seq) => _mutate((candidate) {
    if (seq > candidate.lastAppliedSeq) candidate.lastAppliedSeq = seq;
  });

  @override
  Future<void> resetSyncCursors() => _mutate((candidate) {
    candidate.highWaterSeq = 0;
    candidate.lastAppliedSeq = 0;
  });

  @override
  Future<void> recoverFromRejectedCursor() => _mutate((candidate) {
    final cleanIds = <String>[
      for (final entry in candidate.records.entries)
        if (!candidate.dirty.contains(entry.key)) entry.key,
    ];
    for (final id in cleanIds) {
      final record = candidate.records[id]!;
      candidate.records[id] = EncryptedRecord(
        envelopeVersion: record.envelopeVersion,
        id: record.id,
        updatedAt: record.updatedAt,
        deviceId: record.deviceId,
        deleted: record.deleted,
        seq: null,
        blob: record.blob,
      );
    }
    candidate.dirty.addAll(cleanIds);
    candidate.displaced.clear();
    candidate.highWaterSeq = 0;
    candidate.lastAppliedSeq = 0;
    candidate.cursorRecoveryPending = true;
  });

  @override
  Future<bool> cursorRecoveryPending() async {
    await _writeTail;
    await _ensureLoaded();
    return _cursorRecoveryPending;
  }

  @override
  Future<void> completeCursorRecovery() => _mutate((candidate) {
    candidate.cursorRecoveryPending = false;
  });

  @override
  Future<int> recordEnvelopeFloor() async {
    await _writeTail;
    await _ensureLoaded();
    return _recordEnvelopeFloor;
  }

  @override
  Future<void> observeRecordEnvelopeFloor(int floor) async {
    if (floor < kLegacyRecordEnvelopeVersion ||
        floor > kCurrentRecordEnvelopeVersion) {
      throw FormatException('Unsupported record envelope floor $floor');
    }
    await _ensureLoaded();
    await _writeTail;
    if (floor < _recordEnvelopeFloor) {
      throw RecordEnvelopeFloorDowngradeException(
        observed: _recordEnvelopeFloor,
        advertised: floor,
      );
    }
    if (floor == _recordEnvelopeFloor) return;
    await _mutate((candidate) => candidate.recordEnvelopeFloor = floor);
  }

  /// Every mutation is serialized and persisted atomically before the
  /// call returns — a crash mid-round can lose at most the in-flight
  /// mutation, never a torn document. The edit closure runs against a
  /// private candidate snapshot of all seven state components;
  /// [_encode] serializes the candidate, and live state is committed
  /// synchronously only once the writer succeeded. Because an atomic writer
  /// can fail after its rename, an error is reconciled against the target:
  /// the candidate is committed when its complete bytes reached disk, while
  /// an unchanged target leaves live state untouched. If even that check
  /// fails, the next read or mutation reloads from disk. The queue heals so
  /// one transient error cannot wedge later writes, and the caller still
  /// sees the failure.
  Future<T> _mutate<T>(T Function(_CandidateState candidate) edit) {
    final operation = _writeTail.then((_) async {
      await _ensureLoaded();
      final candidate = _snapshot();
      final result = edit(candidate);
      final contents = _encode(candidate);
      try {
        await _atomicWriter(_file, contents);
      } on Object {
        try {
          if (await _file.readAsString() == contents) _commit(candidate);
        } on Object {
          // The target may contain either complete document, but it cannot be
          // inspected. Force the next operation to establish which one won.
          _loadFuture = null;
        }
        rethrow;
      }
      _commit(candidate);
      return result;
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  /// Swap a successfully persisted candidate into the live fields.
  /// Clear-and-refill keeps the maps' and set's identity and insertion
  /// order (readers hold these exact objects), and runs synchronously
  /// right after the awaited writer, so no reader can observe a
  /// half-committed mutation.
  void _commit(_CandidateState candidate) {
    _records
      ..clear()
      ..addAll(candidate.records);
    _dirty
      ..clear()
      ..addAll(candidate.dirty);
    _displaced
      ..clear()
      ..addAll(candidate.displaced);
    _highWaterSeq = candidate.highWaterSeq;
    _lastAppliedSeq = candidate.lastAppliedSeq;
    _cursorRecoveryPending = candidate.cursorRecoveryPending;
    _recordEnvelopeFloor = candidate.recordEnvelopeFloor;
  }

  Future<void> _ensureLoaded() {
    final activeLoad = _loadFuture;
    if (activeLoad != null) return activeLoad;

    final load = _load();
    _loadFuture = load;
    unawaited(
      load.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A transient filesystem failure must not poison later reads.
          if (identical(_loadFuture, load)) _loadFuture = null;
        },
      ),
    );
    return load;
  }

  Future<void> _load() async {
    _clear();
    quarantinedPath = null;

    late final String? contents;
    await _file.parent.create(recursive: true);
    contents = await _file.exists() ? await _file.readAsString() : null;
    if (contents == null) {
      if (scope != null) await _write();
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } catch (error, stack) {
      // Report before quarantining: _quarantine throws when the bad file
      // cannot be moved aside, and the original error must still surface.
      await _recoverMalformed(error, stack);
      return;
    }

    if (decoded is! Map) {
      await _recoverMalformed(
        const FormatException('record store root'),
        StackTrace.current,
      );
      return;
    }

    final doc = decoded.cast<String, dynamic>();
    final version = doc['version'];
    // A recognized but newer version fails closed in place — data this
    // build must not overwrite. A missing or non-int version is a
    // document this build never wrote: quarantine it like any other
    // malformed root rather than adopt it as v1.
    if (version is! int) {
      await _recoverMalformed(
        const FormatException('record store version'),
        StackTrace.current,
      );
      return;
    }
    final supported = scope == null
        ? version == _legacyStoreVersion
        : version == _legacyStoreVersion || version == _scopedStoreVersion;
    if (!supported) throw FormatException('record store version $version');

    SyncAccountScope? storedScope;
    try {
      if (version == _scopedStoreVersion) {
        final account = doc['account'];
        if (account is! Map) {
          throw const FormatException('record store account scope');
        }
        storedScope = SyncAccountScope.fromJson(
          account.cast<String, dynamic>(),
        );
      }
      _readDocument(doc);
    } catch (error, stack) {
      await _recoverMalformed(error, stack);
      return;
    }

    final activeScope = scope;
    if (activeScope == null) return;

    final adoptingLegacy = version == _legacyStoreVersion && adoptLegacy;
    final mustReset =
        resetExisting ||
        (version == _legacyStoreVersion && !adoptingLegacy) ||
        (version == _scopedStoreVersion && storedScope != activeScope);
    if (mustReset) _clear();

    // Claim a v1 document, bind a replacement account, or persist the reset
    // before any cursor or record mutation can race a restart.
    if (version == _legacyStoreVersion || mustReset) await _write();
  }

  void _readDocument(Map<String, dynamic> doc) {
    final records = doc['records'];
    final highWater = doc['highWaterSeq'];
    final lastApplied = doc['lastAppliedSeq'];
    final cursorRecoveryPending = doc['cursorRecoveryPending'];
    final recordEnvelopeFloor = doc['recordEnvelopeFloor'];
    final displaced = doc['displaced'];
    if (records is! List ||
        (highWater != null && highWater is! int) ||
        (lastApplied != null && lastApplied is! int) ||
        (cursorRecoveryPending != null && cursorRecoveryPending is! bool) ||
        (recordEnvelopeFloor != null && recordEnvelopeFloor is! int) ||
        (displaced != null && displaced is! List)) {
      throw const FormatException('record store root');
    }

    for (final entry in records) {
      _readEntry((entry as Map).cast<String, dynamic>());
    }
    if (displaced is List) {
      for (final entry in displaced) {
        final record = EncryptedRecord.fromJson(
          (entry as Map).cast<String, dynamic>(),
        );
        _displaced[record.id] = record;
      }
    }

    _highWaterSeq = highWater as int? ?? 0;
    _lastAppliedSeq = lastApplied as int? ?? 0;
    _cursorRecoveryPending = cursorRecoveryPending as bool? ?? false;
    _recordEnvelopeFloor =
        recordEnvelopeFloor as int? ?? kLegacyRecordEnvelopeVersion;
    if (_recordEnvelopeFloor < kLegacyRecordEnvelopeVersion ||
        _recordEnvelopeFloor > kCurrentRecordEnvelopeVersion) {
      throw const FormatException('record store envelope floor');
    }
  }

  Future<void> _recoverMalformed(Object error, StackTrace stack) async {
    _report(error, stack);
    _clear();
    await _quarantine();
    if (scope != null) await _write();
  }

  void _clear() {
    _records.clear();
    _dirty.clear();
    _displaced.clear();
    _highWaterSeq = 0;
    _lastAppliedSeq = 0;
    _cursorRecoveryPending = false;
    _recordEnvelopeFloor = kLegacyRecordEnvelopeVersion;
  }

  void _readEntry(Map<String, dynamic> json) {
    final dirty = json.remove('dirty');
    final record = EncryptedRecord.fromJson(json);
    _records[record.id] = record;
    if (dirty == true) _dirty.add(record.id);
  }

  String _encode(_CandidateState candidate) => jsonEncode({
    'version': scope == null ? _legacyStoreVersion : _scopedStoreVersion,
    if (scope != null) 'account': scope!.toJson(),
    'highWaterSeq': candidate.highWaterSeq,
    'lastAppliedSeq': candidate.lastAppliedSeq,
    if (candidate.recordEnvelopeFloor > kLegacyRecordEnvelopeVersion)
      'recordEnvelopeFloor': candidate.recordEnvelopeFloor,
    if (candidate.cursorRecoveryPending) 'cursorRecoveryPending': true,
    'records': [
      for (final record in candidate.records.values)
        {...record.toJson(), 'dirty': candidate.dirty.contains(record.id)},
    ],
    if (candidate.displaced.isNotEmpty)
      'displaced': [
        for (final record in candidate.displaced.values) record.toJson(),
      ],
  });

  /// Write the current live state. Used by [_load] to bind a scoped store
  /// or persist a reset before any mutation can race a restart.
  Future<void> _write() => _atomicWriter(_file, _encodeLive());

  String _encodeLive() => _encode(_snapshot());

  _CandidateState _snapshot() => _CandidateState(
    records: Map.of(_records),
    dirty: Set.of(_dirty),
    displaced: Map.of(_displaced),
    highWaterSeq: _highWaterSeq,
    lastAppliedSeq: _lastAppliedSeq,
    cursorRecoveryPending: _cursorRecoveryPending,
    recordEnvelopeFloor: _recordEnvelopeFloor,
  );

  /// Moves a corrupt store aside under a unique `corrupt-<stamp>-<n>` name
  /// so a repeated corruption can never overwrite the first rescue copy.
  /// Throws when the file cannot be moved: starting empty over bytes this
  /// version could not read would let the next write destroy them.
  Future<void> _quarantine() async {
    for (var n = 0; ; n++) {
      final target = recordStoreQuarantinePath(_file.path, _now(), n);
      if (File(target).existsSync()) continue;
      await _file.rename(target);
      quarantinedPath = target;
      return;
    }
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }
}

/// The private working copy one mutation edits: a snapshot of all seven
/// live state components taken after load, mutated by the edit closure,
/// serialized by the write, and committed into the live fields only
/// once the writer succeeded or reconciliation proves its rename landed.
/// A pre-commit failure discards it wholesale. The maps and set are plain
/// copies, so they keep the live collections' insertion order without ever
/// touching the objects themselves.
final class _CandidateState {
  _CandidateState({
    required this.records,
    required this.dirty,
    required this.displaced,
    required this.highWaterSeq,
    required this.lastAppliedSeq,
    required this.cursorRecoveryPending,
    required this.recordEnvelopeFloor,
  });

  final Map<String, EncryptedRecord> records;
  final Set<String> dirty;
  final Map<String, EncryptedRecord> displaced;
  int highWaterSeq;
  int lastAppliedSeq;
  bool cursorRecoveryPending;
  int recordEnvelopeFloor;
}
