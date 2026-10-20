/// Klabautermann's own synced records (03 §4.8, M5 plan M04): the
/// `klabautermann:` prefix on the shared coordinator, its typed payload
/// `{type, v, id, ...}`, the `pref` and `rule` codecs, and the
/// device-local store the handler materializes them into.
///
/// The rules every type follows:
/// - the payload's `id` is the envelope id, and its `type` the id's
///   second segment;
/// - unsealed tombstones are ignored, and deletion is a sealed
///   `{type, v, id, removed: true}`, so a forged tombstone can neither
///   silence a rule nor drop a protected target;
/// - a type this build does not know, or a newer `v` of one it knows, is
///   kept verbatim and skipped;
/// - a record over its type's blob or count cap is refused and trips;
/// - a `pref` record of an excluded server is skipped, and one whose
///   server is absent stays stored, pending, until the server arrives.
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart' show ThresholdRule;
import 'package:meta/meta.dart';
import 'package:seance_core/catalog.dart'
    show
        ApplyContext,
        ApplyOutcome,
        ApplyPhase,
        CatalogWriter,
        RecordCoordinator,
        RecordHandler,
        SyncTrackingServerStore,
        SyncTuple,
        WriteOutcome,
        outranksMaterialized;
import 'package:seance_core/seance_core.dart'
    show DecryptedRecord, EncryptedRecord, RecordKind;

import '../engine/protocol.dart'
    show CadenceProfile, ServerPrefs, ServerPrefsChanged, SyncPrefixBudget;
import '../settings/device_settings_store.dart' show writeFileAtomically;
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'sync_state_file.dart';

/// The id prefix every Klabautermann record carries (03 §4.8).
const String klabautermannRecordPrefix = 'klabautermann';

/// The materialized records' file in the support directory [E].
const String klabautermannRecordsFileName = 'klabautermann_records.json';

/// The payload version this build writes and reads strictly.
const int _payloadVersion = 1;

const String _typeKey = 'type';
const String _versionKey = 'v';
const String _idKey = 'id';
const String _removedKey = 'removed';

/// The record types this build reads (03 §4.8's v1 rows).
enum KlabautermannRecordType {
  /// One server's preferences, `klabautermann:pref:<serverConfigId>`.
  pref(blobCap: 8 * 1024, countCap: null),

  /// One alert rule, `klabautermann:rule:<uuid>`.
  rule(blobCap: 4 * 1024, countCap: 200);

  const KlabautermannRecordType({
    required this.blobCap,
    required this.countCap,
  });

  /// The largest sealed blob a record of this type may have [E].
  final int blobCap;

  /// How many live records of this type the account may hold [E]; null
  /// for a per-server type, whose id already allows one per server.
  final int? countCap;

  /// The record id of this type's record [key]: a server id for
  /// [pref], a uuid for [rule].
  String idOf(String key) => '$klabautermannRecordPrefix:$name:$key';

  static KlabautermannRecordType? named(String name) {
    for (final type in values) {
      if (type.name == name) return type;
    }
    return null;
  }
}

/// A `klabautermann:<type>:<key>` id split at its first two colons; null
/// for an id of another prefix or with an empty type or key.
({String type, String key})? parseKlabautermannId(String id) {
  const prefix = '$klabautermannRecordPrefix:';
  if (!id.startsWith(prefix)) return null;
  final rest = id.substring(prefix.length);
  final colon = rest.indexOf(':');
  if (colon <= 0 || colon == rest.length - 1) return null;
  return (type: rest.substring(0, colon), key: rest.substring(colon + 1));
}

/// One alert rule as its `rule` record carries it: the threshold model
/// plus the server or group its scope names.
@immutable
final class SyncedRule {
  const SyncedRule({required this.id, required this.rule, this.target});

  /// The rule's uuid, the record id's last segment.
  final String id;

  final ThresholdRule rule;

  /// The server id or group name a `server` or `group` scoped rule
  /// applies to; null for `all`.
  final String? target;
}

/// The sealed payload of a sealed removal of [recordId].
Map<String, Object?> removedPayload(String recordId) {
  final parsed = parseKlabautermannId(recordId);
  if (parsed == null) {
    throw ArgumentError.value(recordId, 'recordId', 'not a klabautermann id');
  }
  return {
    _typeKey: parsed.type,
    _versionKey: _payloadVersion,
    _idKey: recordId,
    _removedKey: true,
  };
}

/// [prefs] as the `pref` record of [serverId] seals it.
Map<String, Object?> encodeServerPrefs(String serverId, ServerPrefs prefs) => {
  _typeKey: KlabautermannRecordType.pref.name,
  _versionKey: _payloadVersion,
  _idKey: KlabautermannRecordType.pref.idOf(serverId),
  'readOnly': prefs.readOnly,
  if (prefs.cadence case final cadence?) 'cadence': cadence.name,
  'pinnedUnits': prefs.pinnedUnits,
  'pinnedContainers': prefs.pinnedContainers,
  'protectedTargets': prefs.marks.toList()..sort(),
  'panelOrder': prefs.panelOrder,
  'hostAuditLine': prefs.hostAuditLine,
  'stackScanDirs': prefs.stackScanDirs,
};

/// Reads a `pref` payload strictly: a [FormatException] for a field of
/// the wrong type or an invalid scan directory. Absent fields take their
/// defaults, keys it does not name are ignored, and a cadence preset this
/// build does not know leaves the device's, so a newer build's preset
/// does not trip.
ServerPrefs decodeServerPrefs(Map<String, Object?> payload) {
  final scanDirs = _strings(payload, 'stackScanDirs');
  for (final dir in scanDirs) {
    if (!dir.startsWith('/') || dir.codeUnits.any((unit) => unit < 0x20)) {
      throw const FormatException('a scan directory is not an absolute path');
    }
  }
  final cadence = payload['cadence'];
  if (cadence != null && cadence is! String) {
    throw const FormatException('cadence is not a name');
  }
  return ServerPrefs(
    readOnly: _bool(payload, 'readOnly', fallback: false),
    cadence: CadenceProfile.values
        .where((profile) => profile.name == cadence)
        .firstOrNull,
    pinnedUnits: _strings(payload, 'pinnedUnits'),
    pinnedContainers: _strings(payload, 'pinnedContainers'),
    marks: _strings(payload, 'protectedTargets').toSet(),
    panelOrder: _strings(payload, 'panelOrder'),
    hostAuditLine: _bool(payload, 'hostAuditLine', fallback: true),
    stackScanDirs: scanDirs,
  );
}

/// [rule] as its `rule` record seals it.
Map<String, Object?> encodeSyncedRule(SyncedRule rule) => {
  ...rule.rule.toJson(),
  _typeKey: KlabautermannRecordType.rule.name,
  _versionKey: _payloadVersion,
  _idKey: KlabautermannRecordType.rule.idOf(rule.id),
  if (rule.target case final target?) 'target': target,
};

/// Reads a `rule` payload strictly ([ThresholdRule.fromJson]); the rule's
/// id is the record id's last segment.
SyncedRule decodeSyncedRule(Map<String, Object?> payload) {
  final id = parseKlabautermannId('${payload[_idKey]}')?.key;
  if (id == null) throw const FormatException('a rule has no id');
  final target = payload['target'];
  if (target != null && (target is! String || target.isEmpty)) {
    throw const FormatException('a rule target is not a name');
  }
  return SyncedRule(
    id: id,
    rule: ThresholdRule.fromJson(payload),
    target: target as String?,
  );
}

bool _bool(
  Map<String, Object?> payload,
  String key, {
  required bool fallback,
}) => switch (payload[key]) {
  null => fallback,
  final bool value => value,
  _ => throw FormatException('$key is not a flag'),
};

List<String> _strings(Map<String, Object?> payload, String key) =>
    List.unmodifiable(decodeStringList(payload, key));

/// One materialized record: the tuple it won with and its sealed payload,
/// a sealed removal's included.
@immutable
final class _Entry {
  const _Entry(this.tuple, this.payload);

  final SyncTuple tuple;
  final Map<String, Object?> payload;

  bool get removed => payload[_removedKey] == true;
}

/// `klabautermann_records.json`: every `klabautermann:` record the
/// handler materialized, by record id, with the tuple it won with and
/// its payload as sealed, unknown types and sealed removals included, so
/// the tuple guard holds across restarts and §3.1's recovery can re-seal
/// them verbatim. Kept like the sync state files ([SyncStateFile]).
final class KlabautermannRecordStore {
  KlabautermannRecordStore._(this._file, this._entries);

  final SyncStateFile _file;
  final Map<String, _Entry> _entries;

  static const String _recordsKey = 'records';
  static const String _updatedAtKey = 'updatedAt';
  static const String _deviceIdKey = 'deviceId';
  static const String _payloadKey = 'payload';

  /// Opens the file in [supportDirectory]. Never throws; a file it cannot
  /// use leaves the store empty and is reported in [issue].
  static Future<KlabautermannRecordStore> open(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    SyncStateWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    final (file, entries) = await SyncStateFile.open(
      File(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$klabautermannRecordsFileName',
      ),
      access: access,
      decode: _decode,
      writer: writer,
      now: now,
    );
    return KlabautermannRecordStore._(file, entries ?? {});
  }

  /// The problem met while opening, or null when the file was fine or
  /// absent.
  SyncStateIssue? get issue => _file.issue;

  /// The tuple [recordId] last materialized with, or null.
  SyncTuple? tupleOf(String recordId) => _entries[recordId]?.tuple;

  /// Whether [recordId] holds a live record, not a sealed removal.
  bool isLive(String recordId) => _entries[recordId]?.removed == false;

  /// How many live records of [type] the store holds.
  int liveCount(KlabautermannRecordType type) => _entries.entries
      .where(
        (entry) =>
            !entry.value.removed &&
            parseKlabautermannId(entry.key)?.type == type.name,
      )
      .length;

  /// Every live `pref` record's preferences, by server id, whether or not
  /// its server is in the catalog.
  Map<String, ServerPrefs> prefs() => {
    for (final MapEntry(:key, :value) in _entries.entries)
      if (parseKlabautermannId(key) case (
        type: 'pref',
        key: final serverId,
      ) when !value.removed)
        if (_tryDecode(() => decodeServerPrefs(value.payload)) case final p?)
          serverId: p,
  };

  /// Every live `rule` record's rule, by rule id.
  List<SyncedRule> rules() => [
    for (final MapEntry(:key, :value) in _entries.entries)
      if (!value.removed && parseKlabautermannId(key)?.type == 'rule')
        if (_tryDecode(() => decodeSyncedRule(value.payload)) case final r?) r,
  ];

  /// Materializes [payload] for [recordId] under [tuple].
  Future<void> put(
    String recordId,
    SyncTuple tuple,
    Map<String, Object?> payload,
  ) {
    _entries[recordId] = _Entry(tuple, Map.unmodifiable(payload));
    return _save();
  }

  /// [recordId]'s materialized record as [CatalogWriter.sealLocal] takes
  /// it, under its winning tuple, or null.
  DecryptedRecord? sealable(String recordId) {
    final entry = _entries[recordId];
    if (entry == null) return null;
    return DecryptedRecord(
      id: recordId,
      kind: RecordKind.klabautermann,
      updatedAt: entry.tuple.updatedAt,
      deviceId: entry.tuple.deviceId,
      data: entry.payload,
    );
  }

  /// Every materialized record id.
  Iterable<String> get ids => _entries.keys.toList();

  /// Values the stored payloads were checked against when they applied;
  /// one a later build would refuse reads as absent rather than throwing.
  static T? _tryDecode<T>(T Function() decode) {
    try {
      return decode();
    } on FormatException {
      return null;
    }
  }

  Future<void> _save() => _file.save({
    _recordsKey: {
      for (final id in _entries.keys.toList()..sort())
        id: {
          _updatedAtKey: _entries[id]!.tuple.updatedAt,
          _deviceIdKey: _entries[id]!.tuple.deviceId,
          _payloadKey: _entries[id]!.payload,
        },
    },
  });

  static Map<String, _Entry> _decode(Map<String, Object?> body) {
    final records = body[_recordsKey];
    if (records == null) return {};
    if (records is! Map<String, Object?>) {
      throw const FormatException('records is not an object');
    }
    return {
      for (final MapEntry(:key, :value) in records.entries)
        key: switch (value) {
          {
            _updatedAtKey: final int updatedAt,
            _deviceIdKey: final String deviceId,
            _payloadKey: final Map<String, Object?> payload,
          }
              when parseKlabautermannId(key) != null =>
            _Entry(
              SyncTuple(updatedAt: updatedAt, deviceId: deviceId),
              Map.unmodifiable(payload),
            ),
          _ => throw FormatException('record $key is not a stored record'),
        },
    };
  }
}

/// Pulled `klabautermann:` records (03 §4.8): each applies under the §3.2
/// tuple guard into [KlabautermannRecordStore], after the pass's server
/// configs, so the exclusion check judges a `pref` against the round's
/// final server set.
final class KlabautermannRecordHandler implements RecordHandler {
  KlabautermannRecordHandler({required this._store, required this._servers});

  final KlabautermannRecordStore _store;
  final SyncTrackingServerStore _servers;

  @override
  String? get prefix => klabautermannRecordPrefix;

  /// The secrets phase applies after every server config of the pass.
  @override
  ApplyPhase get phase => ApplyPhase.secrets;

  @override
  RecordKind get kind => RecordKind.klabautermann;

  /// Never: 03 §4.8's v1.x `sudo` and `registry` types put credentials
  /// under this prefix, and §3.2's never-decrypt rule binds the passphrase
  /// trial too.
  @override
  bool get trialDecryptable => false;

  @override
  Future<ApplyOutcome> applyLive(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    final dec = await context.open(record);
    if (dec == null) {
      return context.holdActive ? ApplyOutcome.deferred : ApplyOutcome.skipped;
    }
    final parsed = parseKlabautermannId(record.id);
    final payload = dec.data;
    if (dec.kind != RecordKind.klabautermann ||
        parsed == null ||
        payload[_idKey] != record.id ||
        payload[_typeKey] != parsed.type ||
        payload[_versionKey] is! int) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }

    final type = KlabautermannRecordType.named(parsed.type);
    final version = payload[_versionKey]! as int;
    if (type == null || version > _payloadVersion) {
      // Kept verbatim for the build that knows it, and skipped.
      return _materialize(record, payload, ApplyOutcome.skipped);
    }

    final removed = payload[_removedKey];
    if (removed != null && removed is! bool) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    if (!await _withinCaps(record, type, removed == true) ||
        (removed != true && !_decodes(type, payload))) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    await context.tripwires.clear(record.id);

    if (type == KlabautermannRecordType.pref &&
        (await _servers.byId(parsed.key))?.excludeFromSync == true) {
      return ApplyOutcome.skipped;
    }
    return _materialize(record, payload, ApplyOutcome.applied);
  }

  /// Unsealed tombstones never strip a preference or a rule (03 §4.8):
  /// deletion is a sealed `removed` record.
  @override
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  ) async => ApplyOutcome.skipped;

  /// Every materialized record re-seals verbatim under its winning
  /// tuple; returns how many the writer took.
  @override
  Future<int> reSealAfterStoreLoss(CatalogWriter writer) async {
    var resealed = 0;
    for (final id in _store.ids) {
      final record = _store.sealable(id);
      if (record == null) continue;
      if (await writer.sealLocal(record) == WriteOutcome.written) resealed++;
    }
    return resealed;
  }

  @override
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record) async {
    final stored = _store.sealable(record.id);
    if (stored == null) return null;
    return DecryptedRecord(
      id: record.id,
      kind: RecordKind.klabautermann,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      data: stored.data,
    );
  }

  Future<ApplyOutcome> _materialize(
    EncryptedRecord record,
    Map<String, Object?> payload,
    ApplyOutcome outcome,
  ) async {
    if (!outranksMaterialized(record, _store.tupleOf(record.id))) {
      return ApplyOutcome.deferred;
    }
    await _store.put(
      record.id,
      SyncTuple(updatedAt: record.updatedAt, deviceId: record.deviceId),
      payload,
    );
    return outcome;
  }

  /// Whether [record] fits its type's blob cap and, when it would add a
  /// live record, its count cap.
  Future<bool> _withinCaps(
    EncryptedRecord record,
    KlabautermannRecordType type,
    bool removed,
  ) async {
    if (record.blob.length > type.blobCap) return false;
    final countCap = type.countCap;
    if (countCap == null || removed || _store.isLive(record.id)) return true;
    return _store.liveCount(type) < countCap;
  }

  static bool _decodes(
    KlabautermannRecordType type,
    Map<String, Object?> payload,
  ) {
    try {
      switch (type) {
        case KlabautermannRecordType.pref:
          decodeServerPrefs(payload);
        case KlabautermannRecordType.rule:
          decodeSyncedRule(payload);
      }
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// The account budget the `klabautermann:` records take: the sealed blobs
/// of every live one in [records].
SyncPrefixBudget prefixBudgetOf(Iterable<EncryptedRecord> records) =>
    SyncPrefixBudget(
      records
          .where(
            (record) =>
                !record.deleted &&
                record.id.startsWith('$klabautermannRecordPrefix:'),
          )
          .fold(0, (sum, record) => sum + record.blob.length),
    );

/// The [ServerPrefsChanged] events that take an app holding [sent] to
/// [prefs], and what it holds after them. [sent] maps each server id to
/// its preferences as [encodeServerPrefs] sealed them, so equal
/// preferences compare equal; a server [prefs] no longer lists gets a
/// null.
(List<ServerPrefsChanged>, Map<String, String>) diffServerPrefs(
  Map<String, String> sent,
  Map<String, ServerPrefs> prefs,
) {
  final encoded = {
    for (final MapEntry(:key, :value) in prefs.entries)
      key: jsonEncode(encodeServerPrefs(key, value)),
  };
  return (
    [
      for (final id in {...sent.keys, ...encoded.keys})
        if (sent[id] != encoded[id]) ServerPrefsChanged(id, prefs[id]),
    ],
    encoded,
  );
}

/// Local `klabautermann:` writes, sealed through the coordinator's
/// [CatalogWriter.sealLocal] funnel and refused under `PushPolicy.none`.
extension KlabautermannRecordWrites on RecordCoordinator {
  /// Retracts [serverId]'s `pref` record with a sealed removal dated now,
  /// as when the server becomes excluded from sync (03 §4.8).
  Future<WriteOutcome> retractServerPrefs(String serverId) {
    final id = KlabautermannRecordType.pref.idOf(serverId);
    return writer.sealLocal(
      DecryptedRecord(
        id: id,
        kind: RecordKind.klabautermann,
        updatedAt: writer.now().toUtc().millisecondsSinceEpoch,
        deviceId: writer.deviceId,
        data: removedPayload(id),
      ),
    );
  }
}
