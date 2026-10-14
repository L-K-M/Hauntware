/// The library's `secret:` handler (docs/design/catalog-library.md
/// section 5.3): pulled credentials materialize into the vault behind the
/// excluded-server shield and the freshness floor, and opted-in
/// credentials publish (and orphaned ones retract) through the catalog
/// writer.
library;

import 'package:seance_protocol/seance_protocol.dart';

import '../store/stores.dart';
import 'catalog_writer.dart';
import 'persistent_record_store.dart';
import 'record_handler.dart';
import 'server_config_store.dart';

/// Registered by every coordinator; [_vault] and [_servers] are null in
/// separate mode, where every `secret:` record is skipped unopened.
final class SecretHandler implements RecordHandler {
  SecretHandler({
    required SyncRecordStore records,
    required SecretVault? vault,
    required SyncTrackingServerStore? servers,
    required bool syncSecrets,
  }) : // Collaborator names stay public; the fields stay private.
       // ignore: prefer_initializing_formals
       _records = records,
       // ignore: prefer_initializing_formals
       _vault = vault,
       // ignore: prefer_initializing_formals
       _servers = servers,
       // ignore: prefer_initializing_formals
       _syncSecrets = syncSecrets;

  static const String idPrefix = 'secret';

  /// Never: §3.2's never-decrypt dispatch binds 04 §4.5's passphrase trial
  /// too, so a vault entry can never be pulled into memory as a trial
  /// candidate.
  static const opensInTrial = false;

  static const _secretPrefix = '$idPrefix:';

  final SyncRecordStore _records;

  /// Non-null in shared mode when the vault has a key: pulled `secret:`
  /// records land here, and opted-in credentials publish from here.
  final SecretVault? _vault;

  /// The server set the exclusion shield and the publish rules judge
  /// against; non-null in shared mode.
  final SyncTrackingServerStore? _servers;

  /// The device-level "Sync saved passwords & keys" switch — Séance's
  /// `syncSecrets`, off by default. It governs both halves: while off, no
  /// credential publishes (whatever a server's own `syncSecret` says) and
  /// no pulled `secret:` record lands in the vault. Retraction stays
  /// ungated ([retractOrphaned]); [catchUp] works off the off-to-on
  /// transition's backlog.
  final bool _syncSecrets;

  @override
  String? get prefix => idPrefix;

  @override
  ApplyPhase get phase => ApplyPhase.secrets;

  @override
  RecordKind get kind => RecordKind.secret;

  @override
  bool get trialDecryptable => opensInTrial;

  /// Whether a credential may publish at all: the switch is on and a vault
  /// exists to read it from.
  bool get publishes => _syncSecrets && _vault != null;

  /// Whether [catchUp] has anything to do: [publishes], in shared mode.
  bool get catchesUp => publishes && _servers != null;

  /// A pulled `secret:` record materializes into the vault under Séance's
  /// two guards: the exclusion shield (a credential referenced only by
  /// excluded servers never lands), and the freshness floor (a strictly
  /// newer local edit is never overwritten — the record layer's own
  /// tie-break cannot protect a credential this device does not publish).
  @override
  Future<ApplyOutcome> applyLive(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    final vault = _vault;
    // Switch off: the record stays stored, unapplied — [catchUp] picks it
    // up if the switch turns on.
    if (!_syncSecrets || vault == null || record.deleted) {
      return ApplyOutcome.skipped;
    }
    final dec = await context.open(record);
    if (dec == null) {
      return context.holdActive ? ApplyOutcome.deferred : ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.secret) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    final Secret secret;
    try {
      secret = Secret.fromJson(dec.data);
      if (record.id != '$_secretPrefix${secret.id}') {
        throw const FormatException('secret id mismatch');
      }
    } catch (_) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    await context.tripwires.clear(record.id);
    if (await _isShieldedSecret(secret.id)) return ApplyOutcome.skipped;
    try {
      final existing = await vault.readableSecret(secret.id);
      if (existing != null && existing.updatedAt > dec.updatedAt) {
        return ApplyOutcome.skipped;
      }
      // Persist the envelope stamp so a later local edit can never
      // manufacture a "newer" version out of an unrelated save —
      // Séance's rule for legacy records whose payload carries no stamp.
      await vault.putSecret(secret.copyWith(updatedAt: dec.updatedAt));
    } catch (_) {
      // A locked or failing vault leaves the record stored but
      // unapplied; skipping keeps the pass alive rather than stranding
      // the cursor — Séance's per-record `skip` posture. Under §4.5's
      // hold it defers instead, like a decrypt failure: the record must
      // still be ahead of the cursor when the verified round re-applies.
      return context.holdActive ? ApplyOutcome.deferred : ApplyOutcome.skipped;
    }
    return ApplyOutcome.applied;
  }

  /// Tombstones stay no-ops — vault material is not something an
  /// envelope-only signal may strip.
  @override
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  ) async => ApplyOutcome.skipped;

  /// Credentials the vault still holds re-seal through the publish path —
  /// it re-sources the plaintext and lands the record dirty. They are not
  /// materialized tuples, so none counts toward the re-seal total.
  @override
  Future<int> reSealAfterStoreLoss(CatalogWriter writer) async {
    final servers = _servers;
    if (servers == null) return 0;
    for (final server in await servers.load()) {
      final ref = server.secretRef;
      if (!server.excludeFromSync && server.syncSecret && ref != null) {
        await publish(ref, writer);
      }
    }
    return 0;
  }

  @override
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record) async {
    final Secret? secret;
    try {
      secret = await _vault?.readableSecret(
        record.id.substring(_secretPrefix.length),
      );
    } catch (_) {
      return null;
    }
    if (secret == null) return null;
    return DecryptedRecord(
      id: record.id,
      kind: RecordKind.secret,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      data: secret.toJson(),
    );
  }

  /// The device-level switch just turned on: work off what change-driven
  /// sync skipped while it was off. Stored `secret:` records the apply
  /// pass skipped sit behind the cursor, and no delta pull re-delivers
  /// them, so apply them now (the freshness floor keeps this
  /// idempotent); then publish every credential a synced server opts in
  /// that the account does not already carry at its current stamp. The
  /// caller checks [catchesUp] first.
  Future<void> catchUp(ApplyContext context) async {
    final vault = _vault;
    final store = _servers;
    if (!_syncSecrets || vault == null || store == null) return;
    for (final record in await _records.allRecords()) {
      if (record.deleted || syncIdPrefix(record.id) != idPrefix) continue;
      await applyLive(record, context);
    }
    for (final server in await store.load()) {
      final ref = server.secretRef;
      if (server.excludeFromSync || !server.syncSecret || ref == null) {
        continue;
      }
      final Secret? secret;
      try {
        secret = await vault.readableSecret(ref);
      } catch (_) {
        continue;
      }
      if (secret == null) continue;
      final existing = await _records.getRecord('$_secretPrefix$ref');
      if (existing != null &&
          !existing.deleted &&
          existing.updatedAt >= secret.updatedAt) {
        continue;
      }
      await publish(ref, context.writer);
    }
  }

  /// Seal the vault entry [ref] into its `secret:` record, dirty for the
  /// next push. An unreadable or absent entry publishes nothing — the
  /// pull side's repair path is what heals it. Nothing publishes while
  /// the device-level switch is off — every publish path funnels through
  /// here, so this is the one gate. When this device's own earlier
  /// retraction still sits in the record store past the credential's
  /// stamp, re-date the credential past it (and persist the bump so vault
  /// and record agree): without the bump the tombstone wins LWW and the
  /// fleet keeps the credential withdrawn — Séance's `_reviveSecrets`
  /// case. Another device's retraction is not ours to overrule: the
  /// credential stays withdrawn until it is edited.
  Future<void> publish(String ref, CatalogWriter writer) async {
    final vault = _vault;
    if (!_syncSecrets || vault == null) return;
    final Secret? secret;
    try {
      secret = await vault.readableSecret(ref);
    } catch (_) {
      return;
    }
    if (secret == null) return;
    var stamped = secret;
    final existing = await _records.getRecord('$_secretPrefix$ref');
    if (existing != null &&
        existing.deleted &&
        existing.deviceId == writer.deviceId &&
        existing.updatedAt >= stamped.updatedAt) {
      stamped = stamped.copyWith(updatedAt: existing.updatedAt + 1);
      try {
        await vault.putSecret(stamped);
      } catch (_) {
        // A vault that cannot take the bump still publishes nothing new;
        // the next round's pull-side repair gets another chance.
        return;
      }
    }
    await writer.sealLocal(
      DecryptedRecord(
        id: '$_secretPrefix$ref',
        kind: RecordKind.secret,
        updatedAt: stamped.updatedAt,
        deviceId: writer.deviceId,
        data: stamped.toJson(),
      ),
    );
  }

  /// Retract a credential's `secret:` record when no synced server still
  /// references it — the withdrawal half of delete and exclusion. A
  /// still-synced sharer keeps the credential published (Séance's
  /// `syncedSecretRefs` rule, conservatively counting a sharer whose own
  /// `syncSecret` is off). Ungated by the switch, as in Séance: this
  /// device cannot tell whether an earlier session with the switch on
  /// already published the credential, and leaving one behind costs the
  /// credential. The tombstone outranks the live `secret:` record this
  /// device has seen — a credential's stamp advances independently of
  /// its server's, so the server's [stamp] alone could lose LWW to it.
  Future<void> retractOrphaned(
    String? ref,
    int stamp,
    CatalogWriter writer,
  ) async {
    final store = _servers;
    if (ref == null || store == null) return;
    for (final server in await store.load()) {
      if (!server.excludeFromSync && server.secretRef == ref) return;
    }
    var retractedAt = stamp;
    final existing = await _records.getRecord('$_secretPrefix$ref');
    if (existing != null && existing.updatedAt >= retractedAt) {
      // Already withdrawn at or past this stamp — re-sealing would only
      // regress the record.
      if (existing.deleted) return;
      retractedAt = existing.updatedAt + 1;
    }
    await writer.sealLocal(
      DecryptedRecord(
        id: '$_secretPrefix$ref',
        kind: RecordKind.secret,
        updatedAt: retractedAt,
        deviceId: writer.deviceId,
        deleted: true,
      ),
    );
  }

  /// True when every stored reference to [ref] is excluded — the shield
  /// that keeps a retracted credential's pulled copies out of the vault.
  Future<bool> _isShieldedSecret(String ref) async {
    final store = _servers;
    if (store == null) return false;
    var shielded = false;
    for (final server in await store.load()) {
      if (server.secretRef != ref) continue;
      if (!server.excludeFromSync) return false;
      shielded = true;
    }
    return shielded;
  }
}
