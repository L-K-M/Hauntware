/// The library's `serverConfig` handler (docs/design/catalog-library.md
/// section 5.3): bare prefixless ids, Séance's convention. Pulled configs
/// materialize into the server store in shared mode; with no store
/// (separate mode) prefixless records are skipped without being opened.
library;

import 'package:seance_protocol/seance_protocol.dart';

import 'catalog_writer.dart';
import 'push_policy.dart';
import 'record_handler.dart';
import 'server_config_store.dart';

/// One server sealed under its own stamp — the record id is the bare
/// config id, Séance's convention: prefixless ids are `serverConfig`.
DecryptedRecord serverConfigRecord(
  ServerConfig server, {
  required String deviceId,
}) => DecryptedRecord(
  id: server.id,
  kind: RecordKind.serverConfig,
  updatedAt: server.updatedAt,
  deviceId: deviceId,
  data: server.toJson(),
);

/// Registered by every coordinator; [_servers] is null in separate mode.
final class ServerConfigHandler implements RecordHandler {
  ServerConfigHandler({required SyncTrackingServerStore? servers})
    : // The public collaborator name stays readable; its field is private.
      // ignore: prefer_initializing_formals
      _servers = servers;

  /// Bare ids carry no prefix.
  static const String? idPrefix = null;

  /// Server configs carry no credential, so the passphrase trial may open
  /// them (04 §4.5).
  static const opensInTrial = true;

  final SyncTrackingServerStore? _servers;

  @override
  String? get prefix => idPrefix;

  @override
  ApplyPhase get phase => ApplyPhase.configs;

  @override
  RecordKind get kind => RecordKind.serverConfig;

  @override
  bool get trialDecryptable => opensInTrial;

  @override
  Future<ApplyOutcome> applyLive(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    // Decrypt only when a server store exists to materialize into (shared
    // mode).
    final store = _servers;
    if (store == null) return ApplyOutcome.skipped;
    final dec = await context.open(record);
    if (dec == null) {
      return context.holdActive ? ApplyOutcome.deferred : ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.serverConfig) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    final ServerConfig config;
    try {
      config = ServerConfig.fromJson(dec.data);
      if (config.id != record.id) {
        throw const FormatException('serverConfig id mismatch');
      }
    } catch (_) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    await context.tripwires.clear(record.id);
    // The exclusion shield runs before the tuple guard: a locally
    // excluded server keeps its row but must never re-materialize pulled
    // state. Its retraction re-dates past a winning pulled copy — once,
    // then settles; the rival pushes at a fixed stamp, so nothing bids
    // back (Séance's `rescheduleOutranked` escalation).
    final local = await store.byId(config.id);
    if (local != null && local.excludeFromSync) {
      if (record.updatedAt >= local.updatedAt) {
        await context.writer.sealLocal(
          DecryptedRecord(
            id: record.id,
            kind: RecordKind.serverConfig,
            updatedAt: record.updatedAt + 1,
            deviceId: context.writer.deviceId,
            deleted: true,
          ),
        );
      }
      return ApplyOutcome.skipped;
    }
    if (!outranksMaterialized(record, await store.syncTupleOf(config.id))) {
      return ApplyOutcome.deferred;
    }
    await store.applySyncedRecord(
      config,
      ServerSyncTuple(updatedAt: record.updatedAt, deviceId: record.deviceId),
    );
    return ApplyOutcome.applied;
  }

  /// A pulled `serverConfig` tombstone deletes the materialized row under
  /// the same tuple guard an upsert uses — with Séance's two exceptions:
  /// a locally excluded row never drops (the tombstone is this device's
  /// own retraction echoing back), and an own-deviceId tombstone over a
  /// live local row is a reversed exclusion — the live record re-dates
  /// past it rather than honouring a decision the user undid. A pull-only
  /// coordinator makes no local decisions to undo and seals no revive, so
  /// there the tombstone applies like any other. Configs already carry
  /// the breach-tolerant exposure of an envelope a sync server can assert
  /// on its own; Séance applies them the same way.
  @override
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    final store = _servers;
    if (store == null) return ApplyOutcome.skipped;
    final local = await store.byId(record.id);
    if (local != null && local.excludeFromSync) {
      return ApplyOutcome.skipped;
    }
    final deviceId = context.writer.deviceId;
    final pullOnly = context.writer.pushPolicy == PushPolicy.none;
    if (local != null && record.deviceId == deviceId && !pullOnly) {
      // A row that already outranks its own old retraction (the edit that
      // re-included it) needs no revive — re-dating it to the tombstone's
      // stamp + 1 would regress it.
      if (local.updatedAt > record.updatedAt) return ApplyOutcome.skipped;
      final revived = local.copyWith(updatedAt: record.updatedAt + 1);
      await store.applySyncedRecord(
        revived,
        ServerSyncTuple(updatedAt: revived.updatedAt, deviceId: deviceId),
      );
      await context.writer.sealLocal(
        serverConfigRecord(revived, deviceId: deviceId),
      );
      return ApplyOutcome.applied;
    }
    if (!outranksMaterialized(record, await store.syncTupleOf(record.id))) {
      return ApplyOutcome.deferred;
    }
    await store.removeSyncedRecord(
      record.id,
      ServerSyncTuple(
        updatedAt: record.updatedAt,
        deviceId: record.deviceId,
        deleted: true,
      ),
    );
    return ApplyOutcome.applied;
  }

  /// Shared mode's materialized set: the server store's tuples re-seal
  /// under their own bare ids with the persisted winning authorship. An
  /// excluded row keeps a live local tuple but is retracted on the
  /// account: re-seal the retraction, as [reSourcePending] does — live
  /// payload would un-exclude it fleet-wide.
  @override
  Future<int> reSealAfterStoreLoss(CatalogWriter writer) async {
    final servers = _servers;
    if (servers == null) return 0;
    var resealed = 0;
    final serverTuples = await servers.syncTuples();
    final serverRows = {for (final s in await servers.load()) s.id: s};
    for (final entry in serverTuples.entries) {
      final tuple = entry.value;
      final row = serverRows[entry.key];
      await writer.sealLocal(
        row == null || tuple.deleted || row.excludeFromSync
            ? DecryptedRecord(
                id: entry.key,
                kind: RecordKind.serverConfig,
                updatedAt: tuple.updatedAt,
                deviceId: tuple.deviceId,
                deleted: true,
              )
            : DecryptedRecord(
                id: entry.key,
                kind: RecordKind.serverConfig,
                updatedAt: tuple.updatedAt,
                deviceId: tuple.deviceId,
                data: row.toJson(),
              ),
      );
      resealed++;
    }
    return resealed;
  }

  /// An excluded server's stale live record re-seals as the retraction
  /// the store says it should be — re-pushing live payload would
  /// un-exclude it on the fleet.
  @override
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record) async {
    final row = await _servers?.byId(record.id);
    if (row == null) return null;
    return row.excludeFromSync
        ? DecryptedRecord(
            id: record.id,
            kind: RecordKind.serverConfig,
            updatedAt: record.updatedAt,
            deviceId: record.deviceId,
            deleted: true,
          )
        : DecryptedRecord(
            id: record.id,
            kind: RecordKind.serverConfig,
            updatedAt: record.updatedAt,
            deviceId: record.deviceId,
            data: row.toJson(),
          );
  }
}
