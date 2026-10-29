/// 03 §4.4's "Write semantics (v1)" (docs/design/catalog-library.md
/// section 4): the shared write path every change-driven seal goes through.
/// What were Poltergeist's `BookmarkCoordinator` `on*` methods and their
/// `_seal*` internals; credential publication and retraction are
/// [SecretHandler]'s (section 5.3), reached from here.
library;

import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart';

import 'host_key_mutations.dart';
import 'persistent_record_store.dart';
import 'pin_verdicts.dart';
import 'push_policy.dart';
import 'record_crypto.dart';
import 'secret_handler.dart';
import 'server_config_handler.dart';
import 'server_config_store.dart';

/// Result of a [CatalogWriter] mutation. [refusedPullOnly] means
/// [PushPolicy.none]: the call returned before touching any local store,
/// sealing any record or changing any verdict. [written] means the policy
/// let the call run; it may still be a domain no-op (a server write in
/// separate mode, `secretSaved` with the secret switch off).
enum WriteOutcome { written, refusedPullOnly }

/// The local writes one coordinator seals. Every dirty record arrives
/// through [sealLocal]; the server writes also refresh the coordinator's
/// catalog before they return. Under [PushPolicy.none] every mutating
/// call refuses at entry with [WriteOutcome.refusedPullOnly].
final class CatalogWriter {
  /// Built by the `RecordCoordinator`, which owns the collaborators and the
  /// catalog a server write refreshes; apps reach the writer through
  /// `RecordCoordinator.writer`, so the two can never disagree about the
  /// stores, the vault key or this install's device id.
  @internal
  CatalogWriter({
    required SyncRecordStore records,
    required RecordCrypto crypto,
    required String deviceId,
    required HostKeyMutationGate hostKeyMutations,
    required PinVerdictStore pinVerdicts,
    required SyncTrackingServerStore? servers,
    required SecretHandler secrets,
    required PushPolicy pushPolicy,
    required DateTime Function() now,
    required Future<void> Function() refreshCatalog,
  }) : // Collaborator names stay public; the fields stay private.
       // ignore: prefer_initializing_formals
       _records = records,
       // ignore: prefer_initializing_formals
       _crypto = crypto,
       // ignore: prefer_initializing_formals
       _deviceId = deviceId,
       // ignore: prefer_initializing_formals
       _hostKeyMutations = hostKeyMutations,
       // ignore: prefer_initializing_formals
       _pinVerdicts = pinVerdicts,
       // ignore: prefer_initializing_formals
       _servers = servers,
       // ignore: prefer_initializing_formals
       _secrets = secrets,
       // ignore: prefer_initializing_formals
       _pushPolicy = pushPolicy,
       // ignore: prefer_initializing_formals
       _now = now,
       // ignore: prefer_initializing_formals
       _refreshCatalog = refreshCatalog;

  static const _hostKeyPrefix = 'hostkey:';

  final SyncRecordStore _records;
  final RecordCrypto _crypto;
  final String _deviceId;
  final HostKeyMutationGate _hostKeyMutations;
  final PinVerdictStore _pinVerdicts;

  /// Non-null in shared mode: the writable materialization of
  /// `serverConfig` records. Server writes are no-ops without it.
  final SyncTrackingServerStore? _servers;

  final SecretHandler _secrets;
  final PushPolicy _pushPolicy;
  final DateTime Function() _now;
  final Future<void> Function() _refreshCatalog;

  /// This install's sync device id: every local write is sealed under it
  /// (04 §3.2 — `deviceId: deviceId`, always); only re-seals of rows another
  /// device authored keep that device's id.
  String get deviceId => _deviceId;

  /// The coordinator's clock — the stamp a local deletion is dated at.
  DateTime now() => _now();

  /// The policy this writer enforces.
  PushPolicy get pushPolicy => _pushPolicy;

  bool get _pullOnly => _pushPolicy == PushPolicy.none;

  /// `crypto.seal` + `records.putLocal`: the single funnel every dirty
  /// record arrives through, local edits and re-seals alike. Under
  /// [PushPolicy.none] it refuses before `crypto.seal`, so nothing is
  /// sealed and no record is marked dirty.
  Future<WriteOutcome> sealLocal(DecryptedRecord record) async {
    if (_pullOnly) return WriteOutcome.refusedPullOnly;
    await _records.putLocal(await _crypto.seal(record));
    return WriteOutcome.written;
  }

  /// A local server save in shared mode (04 §4.2, amended): persist the
  /// re-stamped row, then seal its prefixless `serverConfig` record dirty
  /// under that stamp and this install's authorship — the same
  /// change-driven write path every local edit uses. An excluded server
  /// retracts instead: a tombstone dated at the edit drops the account
  /// copy while the local row survives (Séance's `_retract`), and the
  /// orphaned credential's record withdraws with it. A no-op in separate
  /// mode, where no server store exists. Pull-only refuses before the row
  /// is saved: a local edit with no record behind it would be undone
  /// silently by the next pulled `serverConfig`.
  Future<WriteOutcome> saveServer(ServerConfig server) async {
    if (_pullOnly) return WriteOutcome.refusedPullOnly;
    final store = _servers;
    if (store == null) return WriteOutcome.written;
    final stored = await store.save(server);
    if (stored.excludeFromSync) {
      await sealLocal(
        DecryptedRecord(
          id: stored.id,
          kind: RecordKind.serverConfig,
          updatedAt: stored.updatedAt,
          deviceId: _deviceId,
          deleted: true,
        ),
      );
      await _secrets.retractOrphaned(stored.secretRef, stored.updatedAt, this);
    } else {
      await sealLocal(serverConfigRecord(stored, deviceId: _deviceId));
      // The opted-in credential travels with its server — re-dating past
      // this device's own earlier retraction when needed, or the fleet
      // keeps it withdrawn.
      final ref = stored.secretRef;
      if (stored.syncSecret && ref != null) await _secrets.publish(ref, this);
    }
    await _refreshCatalog();
    return WriteOutcome.written;
  }

  /// A local server delete: drop the row and seal a real tombstone — the
  /// resurrection-gap fix Séance's ephemeral store lacks — then retract the
  /// orphaned credential's record. The record takes the stamp the store
  /// recorded for its tombstone tuple ([deletionStamp]: past every
  /// version seen, so a peer's fast clock cannot outrank the delete), so
  /// store and record agree on it. Pull-only refuses before the row drops.
  Future<WriteOutcome> deleteServer(ServerConfig server) async {
    if (_pullOnly) return WriteOutcome.refusedPullOnly;
    final store = _servers;
    if (store == null) return WriteOutcome.written;
    final prior = await store.byId(server.id);
    await store.remove(server.id);
    final tuple = await store.syncTupleOf(server.id);
    final deletedAt = tuple != null && tuple.deleted
        ? tuple.updatedAt
        : deletionStamp(
            now: _now(),
            prior: [prior?.updatedAt, server.updatedAt, tuple?.updatedAt],
          );
    await sealLocal(
      DecryptedRecord(
        id: server.id,
        kind: RecordKind.serverConfig,
        updatedAt: deletedAt,
        deviceId: _deviceId,
        deleted: true,
      ),
    );
    await _secrets.retractOrphaned(
      (prior ?? server).secretRef,
      deletedAt,
      this,
    );
    await _refreshCatalog();
    return WriteOutcome.written;
  }

  /// A credential the editor saved into the vault (via
  /// `SecretVault.putLocalSecret`, so its own stamp advanced): publish it
  /// while a synced server opts it in — a credential edit on an excluded
  /// or non-`syncSecret` server stays local (Séance's
  /// `_publishableSecretRefs` rule), and so does every credential while
  /// the device-level "Sync saved passwords & keys" switch is off.
  /// Null-safe when shared mode has no vault or store. Pull-only refuses
  /// before reading the server set.
  Future<WriteOutcome> secretSaved(String secretId) async {
    if (_pullOnly) return WriteOutcome.refusedPullOnly;
    final store = _servers;
    if (!_secrets.publishes || store == null) return WriteOutcome.written;
    var publishable = false;
    for (final server in await store.load()) {
      if (!server.excludeFromSync &&
          server.syncSecret &&
          server.secretRef == secretId) {
        publishable = true;
        break;
      }
    }
    if (publishable) await _secrets.publish(secretId, this);
    return WriteOutcome.written;
  }

  /// A deliberately published TOFU pin (divergence 2's seam; no app calls
  /// it today): seal it and clear any negative pin for the locator —
  /// explicit re-trust is the only thing that lifts the untrust verdict
  /// (04 §3.2). The pin record lands first: lifting the verdict before the
  /// replacement is durable would leave a window where a pulled rival key
  /// auto-applies. Pull-only refuses before the verdict changes.
  Future<WriteOutcome> publishPin(HostKey pin) async {
    if (_pullOnly) return WriteOutcome.refusedPullOnly;
    await _hostKeyMutations.run(() async {
      await sealLocal(
        DecryptedRecord(
          id: pin.recordId,
          kind: RecordKind.hostKey,
          updatedAt: pin.pinnedAt,
          deviceId: _deviceId,
          data: pin.toJson(),
        ),
      );
      await _pinVerdicts.removeNegativePin(pin.locator);
    });
    return WriteOutcome.written;
  }

  /// "Forget host": tombstone the pin's record AND record the durable
  /// negative pin. The tombstone alone cannot hold — a still-trusting peer
  /// habitually re-pushes its pin with a fresh stamp, and without the
  /// verdict the next diff would auto-apply the very key the user removed
  /// under MITM suspicion. Local de-trust is the caller's side of the
  /// contract: `HostKeyStore` offers no removal, so the app drops the pin
  /// through its own store alongside this call. Pull-only refuses before
  /// the negative pin is added.
  Future<WriteOutcome> forgetPin(String host, int port) async {
    if (_pullOnly) return WriteOutcome.refusedPullOnly;
    await _hostKeyMutations.run(() async {
      final locator = hostKeyLocator(host, port);
      await _pinVerdicts.addNegativePin(locator);
      await sealLocal(
        DecryptedRecord(
          id: '$_hostKeyPrefix$locator',
          kind: RecordKind.hostKey,
          updatedAt: _now().toUtc().millisecondsSinceEpoch,
          deviceId: _deviceId,
          deleted: true,
        ),
      );
    });
    return WriteOutcome.written;
  }
}
