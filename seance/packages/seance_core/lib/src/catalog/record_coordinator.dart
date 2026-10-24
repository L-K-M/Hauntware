/// 04 §3.2 — `RecordCoordinator`: the thin, prefix-dispatched bridge
/// between the §3.1 record store and the domain stores, shared through
/// `package:seance_core/catalog.dart` (decision D6;
/// docs/design/catalog-library.md sections 4 and 5; Poltergeist's
/// `BookmarkCoordinator` before the move). Change-driven on the way out
/// (every local write seals exactly the edited row through [CatalogWriter]),
/// delta-scanned on the way in (`applyPulled` processes only records with
/// `seq > lastAppliedSeq`), and skip-and-preserve throughout: prefixes no
/// [RecordHandler] claims are never decrypted, decrypt failures are never
/// rewritten, and decrypt-success + strict-decode-failure raises the §4.2
/// durable tripwire. Every coordinator registers the library's own
/// handlers — `serverConfig` (bare prefixless ids), `hostkey:` and
/// `secret:`, the first and last inert outside shared mode — beside the
/// product handlers the app passes (Poltergeist's `bookmark:`). `snippet:`
/// and every other prefix stay read-never.
library;

import 'dart:math' show min;

import 'package:seance_protocol/seance_protocol.dart';

import '../store/stores.dart';
import '../sync/push_batcher.dart';
import '../sync/sync_engine.dart';
import 'catalog_controller.dart';
import 'catalog_snapshot.dart';
import 'catalog_writer.dart';
import 'enrollment.dart';
import 'host_key_handler.dart';
import 'host_key_mutations.dart';
import 'persistent_record_store.dart';
import 'pin_verdicts.dart';
import 'push_policy.dart';
import 'record_crypto.dart';
import 'record_handler.dart';
import 'secret_handler.dart';
import 'server_config_handler.dart';
import 'server_config_store.dart';

/// Whether pulled prefixless `serverConfig` records materialize (04 §4.2).
/// Shared mode materializes them into the server store and holds the
/// catalog built from it; separate mode has neither, and its dispatch
/// never opens a prefixless record.
enum CatalogMode { shared, separate }

/// A pulled `hostkey:` record whose key conflicts with the locally trusted
/// pin for the same `host:port`. Re-derived by diffing the stored
/// `hostkey:` records against the TOFU store on every `applyPulled` (04
/// §3.2 — durable because it is *re-derived*, not because it is stored),
/// so the conflict resurfaces until the user resolves it.
final class HostKeyConflict {
  const HostKeyConflict({
    required this.locator,
    required this.local,
    required this.pulled,
  });

  /// `host:port` — the [HostKey.locator] spelling.
  final String locator;

  /// The pin this device currently trusts.
  final HostKey local;

  /// The key the winning `hostkey:` record carries.
  final HostKey pulled;
}

/// What one `applyPulled` pass did — the Settings → Backup surface reads
/// [pinConflicts] for the quarantine warning and the tripwire store for
/// decode failures.
final class ApplyReport {
  /// Record ids materialized this pass (upserts and tombstone removes).
  final Set<String> appliedIds = {};

  /// Record ids seen but not applied because a pending local edit or
  /// tombstone still out-tuples them — re-evaluated when the rival's push
  /// resolves, never by cursor advancement.
  final Set<String> deferredIds = {};

  /// The host-key quarantine diff, re-derived wholesale each pass.
  final List<HostKeyConflict> pinConflicts = [];
}

/// The result of one [RecordCoordinator.runRound]: pull/push bookkeeping
/// plus the apply report.
final class SyncRoundResult {
  const SyncRoundResult({
    required this.pulled,
    required this.pushed,
    required this.rounds,
    required this.report,
    required this.pushesHeld,
    required this.authFailed,
    this.refusedIds = const [],
  });

  final int pulled;
  final int pushed;
  final int rounds;
  final ApplyReport report;

  /// True when the round ended with 04 §4.5's push hold still engaged —
  /// dirty records stay sealed locally until the passphrase verifies.
  final bool pushesHeld;

  /// True when the server rejected the bearer token (401 `unauthorized`):
  /// the account is dead or revoked — 04 §7.3's drop-to-local-only. The
  /// durable notice is raised on the enrollment state; there is no token
  /// refresh because server-side tokens never expire.
  final bool authFailed;

  /// Records the server refused as too large to store (413), each sent
  /// alone: they stay dirty, and every later round offers them again.
  final List<String> refusedIds;
}

/// The id classes 04 §4.5's passphrase trial and deferred foreign-record
/// check may open on an install whose coordinator is given [handlers],
/// derived from handler registration rather than a fixed prefix list:
/// [id]'s prefix must belong to a registered handler that opts in
/// ([RecordHandler.trialDecryptable]). The library's own handlers are
/// registered on every install — prefixless `serverConfig` and `hostkey:`
/// opt in, `secret:` never does — so [handlers] are the product handlers
/// the app passes the coordinator (Poltergeist's `bookmark:`). A prefix
/// nothing registers, `snippet:` included, is never opened: §3.2's
/// never-decrypt dispatch binds the trial too.
bool isDecryptableSyncId(String id, Iterable<RecordHandler> handlers) {
  final prefix = syncIdPrefix(id);
  for (final generic in _genericHandlerTraits) {
    if (generic.prefix == prefix) return generic.trialDecryptable;
  }
  for (final handler in handlers) {
    if (handler.prefix == prefix) return handler.trialDecryptable;
  }
  return false;
}

/// The prefixes the coordinator claims for the library's own handlers, and
/// whether each opts into the passphrase trial — the handlers' own
/// constants, so the trial rule and the registration cannot drift.
const _genericHandlerTraits = [
  (
    prefix: ServerConfigHandler.idPrefix,
    trialDecryptable: ServerConfigHandler.opensInTrial,
  ),
  (
    prefix: HostKeyHandler.idPrefix,
    trialDecryptable: HostKeyHandler.opensInTrial,
  ),
  (
    prefix: SecretHandler.idPrefix,
    trialDecryptable: SecretHandler.opensInTrial,
  ),
];

/// The sync server's error code for a push it refuses as too large to
/// store (`SyncEngine` answers the same code).
const String _payloadTooLarge = 'payload_too_large';

/// See the library doc. The coordinator never owns transport: [runRound]
/// takes the [SyncApi] seam per call and tests fake it.
final class RecordCoordinator {
  /// [handlers] are the app's product handlers; none may claim a prefix
  /// the library's own handlers claim, and no two may share one.
  /// [catalogMode] decides whether [servers] (required in shared mode, and
  /// only there) materializes pulled configs and a [catalog]; [secrets] is
  /// shared-mode only too. [onCatalogReplaced] is the catalog's change
  /// notification, called synchronously on every rebuild. A [pushPolicy]
  /// of [PushPolicy.none] makes the coordinator pull-only: rounds pull and
  /// apply but never push, [writer] refuses every mutation, and the
  /// re-seal paths seal nothing.
  ///
  /// [inheritCatalogFrom] is for an app that rebuilds its coordinator under
  /// the same account and vault key (a settings change, a reload): the new
  /// coordinator keeps serving the predecessor's catalog — same identity,
  /// same contents, same notification — instead of swapping in an empty
  /// one until its first rebuild. The inherited catalog keeps the callback
  /// it was built with, so [onCatalogReplaced] must then be null.
  factory RecordCoordinator({
    required SyncRecordStore records,
    required List<RecordHandler> handlers,
    required ConflictAwareHostKeyStore hostKeys,
    required HostKeyMutationGate hostKeyMutations,
    required RecordCrypto crypto,
    required String deviceId,
    required PinVerdictStore pinVerdicts,
    required SyncTripwireStore tripwires,
    required CatalogMode catalogMode,
    required PushPolicy pushPolicy,
    void Function(List<ServerConfig> snapshot)? onCatalogReplaced,
    RecordCoordinator? inheritCatalogFrom,
    SyncTrackingServerStore? servers,
    SecretVault? secrets,
    bool syncSecrets = false,
    SyncEnrollmentState? enrollment,
    DateTime Function()? now,
    int maxRounds = 5,
  }) {
    final shared = catalogMode == CatalogMode.shared;
    if (shared != (servers != null)) {
      throw ArgumentError.value(
        servers,
        'servers',
        shared
            ? 'shared mode materializes into a server store'
            : 'separate mode has no server store',
      );
    }
    if (!shared && secrets != null) {
      throw ArgumentError.value(
        secrets,
        'secrets',
        'separate mode has no credential vault',
      );
    }
    if (!shared && onCatalogReplaced != null) {
      throw ArgumentError.value(
        onCatalogReplaced,
        'onCatalogReplaced',
        'separate mode has no catalog',
      );
    }
    final inherited = inheritCatalogFrom?._catalog;
    if (inheritCatalogFrom != null) {
      if (inherited == null || !shared) {
        throw ArgumentError.value(
          inheritCatalogFrom,
          'inheritCatalogFrom',
          'only a shared-mode coordinator inherits a shared-mode catalog',
        );
      }
      if (onCatalogReplaced != null) {
        throw ArgumentError.value(
          onCatalogReplaced,
          'onCatalogReplaced',
          'an inherited catalog keeps the callback it was built with',
        );
      }
    }

    final claimed = {
      for (final generic in _genericHandlerTraits) generic.prefix,
    };
    for (final handler in handlers) {
      if (!claimed.add(handler.prefix)) {
        throw ArgumentError.value(
          handler.prefix,
          'handlers',
          'a prefix is claimed by exactly one handler',
        );
      }
    }

    final clock = now ?? DateTime.now;
    final secretHandler = SecretHandler(
      records: records,
      vault: secrets,
      servers: servers,
      syncSecrets: syncSecrets,
    );
    // Product handlers first: §3.1's re-seal walks this order, the order
    // Poltergeist's coordinator re-sealed in (bookmarks, then servers, then
    // credentials).
    final registered = <RecordHandler>[
      ...handlers,
      ServerConfigHandler(servers: servers),
      HostKeyHandler(
        hostKeys: hostKeys,
        pinVerdicts: pinVerdicts,
        hostKeyMutations: hostKeyMutations,
      ),
      secretHandler,
    ];
    final catalog =
        inherited ??
        (shared ? CatalogController(onReplaced: onCatalogReplaced) : null);

    late final RecordCoordinator coordinator;
    final writer = CatalogWriter(
      records: records,
      crypto: crypto,
      deviceId: deviceId,
      hostKeyMutations: hostKeyMutations,
      pinVerdicts: pinVerdicts,
      servers: servers,
      secrets: secretHandler,
      pushPolicy: pushPolicy,
      now: clock,
      refreshCatalog: () => coordinator._refreshCatalog(),
    );
    return coordinator = RecordCoordinator._(
      records: records,
      handlers: registered,
      productHandlers: List.unmodifiable(handlers),
      secretHandler: secretHandler,
      hostKeys: hostKeys,
      hostKeyMutations: hostKeyMutations,
      crypto: crypto,
      deviceId: deviceId,
      pinVerdicts: pinVerdicts,
      tripwires: tripwires,
      catalog: catalog,
      servers: servers,
      writer: writer,
      pushPolicy: pushPolicy,
      enrollment: enrollment,
      maxRounds: maxRounds,
    );
  }

  RecordCoordinator._({
    required this._records,
    required List<RecordHandler> handlers,
    required this._productHandlers,
    required this._secretHandler,
    required this._hostKeys,
    required this._hostKeyMutations,
    required this._crypto,
    required this._deviceId,
    required this._pinVerdicts,
    required this._tripwires,
    required this._catalog,
    required this._servers,
    required this._writer,
    required this._pushPolicy,
    required this._enrollment,
    required this._maxRounds,
  }) : _handlers = {for (final handler in handlers) handler.prefix: handler};

  static const _hostKeyPrefix = 'hostkey:';

  final SyncRecordStore _records;

  /// Every registered handler by prefix, in registration order: the app's
  /// product handlers, then the library's own.
  final Map<String?, RecordHandler> _handlers;

  /// What the app passed — the trial rule's input.
  final List<RecordHandler> _productHandlers;

  final SecretHandler _secretHandler;
  final ConflictAwareHostKeyStore _hostKeys;
  final HostKeyMutationGate _hostKeyMutations;
  final RecordCrypto _crypto;
  final String _deviceId;
  final PinVerdictStore _pinVerdicts;
  final SyncTripwireStore _tripwires;

  /// Non-null in shared mode (04 §4.2): pulled prefixless `serverConfig`
  /// records materialize here. Null in separate mode, where prefixless ids
  /// are never decrypted at all.
  final CatalogController? _catalog;

  /// Non-null in shared mode, paired with [_catalog]: the writable
  /// materialization of `serverConfig` records — the catalog is its sorted
  /// view.
  final SyncTrackingServerStore? _servers;

  final CatalogWriter _writer;

  /// [PushPolicy.none] skips every round's push half and both re-seal
  /// passes; every seal below them stops at [CatalogWriter.sealLocal] too.
  final PushPolicy _pushPolicy;

  bool get _pullOnly => _pushPolicy == PushPolicy.none;

  /// The durable enrollment state (04 §4.5): while `passphraseUnverified`
  /// holds, [runRound] holds all pushes and the deferred foreign-record
  /// check is the only way out besides re-enrollment. Null means never
  /// enrolled — nothing is held and no deferred check runs.
  final SyncEnrollmentState? _enrollment;

  final int _maxRounds;

  /// The shared write path (03 §4.4): every local edit seals through it.
  CatalogWriter get writer => _writer;

  /// The read-only server materialization apps consume; null in separate
  /// mode.
  CatalogSnapshot? get catalog => _catalog;

  /// The device-level switch just turned on: work off what change-driven
  /// sync skipped while it was off — the stored `secret:` records the
  /// apply pass skipped, then every opted-in credential the account does
  /// not already carry at its current stamp (`SecretHandler.catchUp`). A
  /// no-op while the switch is off or outside shared mode. The lifted
  /// §4.5 hold runs it again, since what it deferred under the hold is
  /// behind the cursor too.
  Future<void> catchUpSecrets() async {
    if (!_secretHandler.catchesUp) return;
    await _secretHandler.catchUp(await _applyContext());
  }

  /// Repopulate the shared-mode catalog from the server store — the
  /// post-mutation and post-restart repaint path, before any round has
  /// run. A no-op outside shared mode.
  Future<void> rebuildCatalog() => _refreshCatalog();

  Future<void> _refreshCatalog() async {
    final catalog = _catalog;
    if (catalog != null) await _rebuildCatalog(catalog);
  }

  /// Resolve a pin conflict by keeping the local pin: record the durable
  /// kept-verdict (the rejected fingerprint, so the *same* key returning
  /// stays resolved but a genuinely different one still warns) and re-push
  /// the kept pin under a fresh LWW tuple. A stale dialog decision is a
  /// no-op: both fingerprints must still describe the current conflict.
  Future<void> keepLocalPin(HostKeyConflict expected) =>
      _hostKeyMutations.run(() async {
        final current = await _matchingConflictPins(expected);
        if (current == null) return;

        final replacement = await _hostKeys.replaceIfCurrent(
          current.local,
          current.local,
        );
        if (replacement == HostKeyInstallResult.conflict) return;

        await _pinVerdicts.recordKeptVerdict(
          expected.locator,
          current.pulled.fingerprintSha256,
        );
        await _writer.sealLocal(
          DecryptedRecord(
            id: current.local.recordId,
            kind: RecordKind.hostKey,
            updatedAt: deletionStamp(
              now: _writer.now(),
              prior: [current.pulledStamp],
            ),
            deviceId: _deviceId,
            data: current.local.toJson(),
          ),
        );
      });

  /// Resolve a pin conflict by accepting the pulled key: install the
  /// record store's copy — no re-push, it already won LWW — and clear any
  /// negative pin, since accepting is explicit re-trust. Stale decisions
  /// cannot install a key the user was never shown.
  Future<void> acceptPulledPin(HostKeyConflict expected) =>
      _hostKeyMutations.run(() async {
        final current = await _matchingConflictPins(expected);
        if (current == null) return;

        final replacement = await _hostKeys.replaceIfCurrent(
          current.local,
          current.pulled,
        );
        if (replacement == HostKeyInstallResult.conflict) return;

        await _pinVerdicts.removeNegativePin(expected.locator);
      });

  /// Re-read both sides while the shared mutation gate is held. This is the
  /// compare step for conflict actions opened from a potentially stale UI.
  Future<({HostKey local, HostKey pulled, int pulledStamp})?>
  _matchingConflictPins(HostKeyConflict expected) async {
    if (expected.local.locator != expected.locator ||
        expected.pulled.locator != expected.locator) {
      return null;
    }

    final local = await _hostKeys.get(expected.local.host, expected.local.port);
    if (local == null ||
        local.fingerprintSha256 != expected.local.fingerprintSha256) {
      return null;
    }

    final record = await _records.getRecord(
      '$_hostKeyPrefix${expected.locator}',
    );
    if (record == null || record.deleted) return null;

    final DecryptedRecord dec;
    try {
      dec = await _crypto.open(record);
    } catch (_) {
      return null;
    }
    if (dec.kind != RecordKind.hostKey) return null;

    final HostKey pulled;
    try {
      pulled = HostKey.fromJson(dec.data);
    } catch (_) {
      return null;
    }
    if (pulled.locator != expected.locator ||
        pulled.fingerprintSha256 != expected.pulled.fingerprintSha256) {
      return null;
    }

    return (local: local, pulled: pulled, pulledStamp: record.updatedAt);
  }

  /// The host-key quarantine diff (04 §3.2): every stored `hostkey:`
  /// record's key against the local TOFU store, re-derived rather than
  /// remembered so a dismissed warning re-arms on the next round.
  Future<List<HostKeyConflict>> pinConflicts() async {
    final negative = await _pinVerdicts.negativePins();
    final conflicts = <HostKeyConflict>[];
    for (final record in await _records.allRecords()) {
      if (record.deleted || !record.id.startsWith(_hostKeyPrefix)) {
        continue;
      }
      final pin = await _decodePin(record);
      if (pin == null) continue;
      final local = await _hostKeys.get(pin.host, pin.port);
      if (local == null || !local.conflictsWith(pin)) continue;
      if (negative.contains(pin.locator)) continue;
      if (await _pinVerdicts.rejectedFingerprintFor(pin.locator) ==
          pin.fingerprintSha256) {
        continue;
      }
      conflicts.add(
        HostKeyConflict(locator: pin.locator, local: local, pulled: pin),
      );
    }
    return conflicts;
  }

  /// §3.1's corruption recovery: re-seal every materialized tuple —
  /// content and tombstones alike — with the row's *persisted winning*
  /// `(updatedAt, deviceId)`, never this install's id unconditionally
  /// (that would flip the fleet-wide tie-break on rows a remote device
  /// authored). Every record lands dirty, so the next round re-pushes the
  /// set — content-identical for already-synced rows, harmless under LWW.
  /// Each handler re-seals its own prefix
  /// ([RecordHandler.reSealAfterStoreLoss]). Returns the number of records
  /// re-sealed: none under [PushPolicy.none], which seals nothing.
  Future<int> reSealAfterStoreLoss() async {
    if (_pullOnly) return 0;
    var resealed = 0;
    for (final handler in _handlers.values) {
      resealed += await handler.reSealAfterStoreLoss(_writer);
    }
    return resealed;
  }

  /// §4.5's release path: after a corrected passphrase verifies, every
  /// still-dirty record may have been sealed under the *unverified* key —
  /// pushing it would poison the fleet with ciphertext no correct
  /// passphrase reads. Re-seal each pending write under the coordinator's
  /// current vault key before the next round can push it. A record that
  /// already opens under the verified key is skipped (sealed
  /// post-correction); a stale-key record's plaintext is re-sourced from
  /// the materialized stores ([RecordHandler.reSourcePending]); the
  /// envelope's `(updatedAt, deviceId)` is preserved verbatim so the
  /// re-seal keeps the exact same LWW tuple — no re-stamp, no tie-break
  /// flip. A stale-key record whose plaintext no store can supply stays
  /// dirty — releasing it would push the corruption the hold existed to
  /// prevent (unreachable in separate mode: every local-write path
  /// produces product or `hostkey:` ids, which always have a materialized
  /// source). Pull-only has no pending writes to release and seals none.
  Future<int> reSealPendingWrites() async {
    if (_pullOnly) return 0;
    var resealed = 0;
    for (final record in await _records.dirtyRecords()) {
      final handler = _handlers[syncIdPrefix(record.id)];
      if (handler == null) continue;
      if (record.deleted) {
        await _writer.sealLocal(
          DecryptedRecord(
            id: record.id,
            kind: handler.kind,
            updatedAt: record.updatedAt,
            deviceId: record.deviceId,
            deleted: true,
          ),
        );
        resealed++;
        continue;
      }
      // A record that already opens under the verified key needs nothing —
      // it was sealed post-correction. Only a decrypt failure (stale key)
      // needs the plaintext re-sourced below.
      try {
        await _crypto.open(record);
        continue;
      } catch (_) {
        // Sealed under the unverified key: re-source the plaintext.
      }
      final replacement = await handler.reSourcePending(record);
      if (replacement == null) continue;
      await _writer.sealLocal(replacement);
      resealed++;
    }
    return resealed;
  }

  /// One sync round over the [api] seam: delta pull off `highWaterSeq`
  /// (with the one-time full-resync fallback when the cursor is rejected),
  /// merge into the store, push the dirty set, then materialize. Loops
  /// while progress is being made, bounded by [RecordCoordinator]'s
  /// `maxRounds`. While 04 §4.5's `passphraseUnverified` hold is set the
  /// push half is skipped entirely — nothing sealed under an unproven key
  /// leaves the device — and the round ends with the deferred
  /// foreign-record check. Under [PushPolicy.none] the push half never
  /// runs, so nothing is pushed even if a record became dirty some other
  /// way. A 401 `unauthorized` is a dead or revoked
  /// account (tokens never expire server-side, so there is no refresh):
  /// the durable notice is raised and the round ends — local-only.
  Future<SyncRoundResult> runRound(SyncApi api) async {
    final report = ApplyReport();
    var pulled = 0;
    var pushed = 0;
    var rounds = 0;
    var authFailed = false;
    final refused = <String>{};
    var limits = const PushLimits();
    rounds:
    while (rounds < _maxRounds) {
      rounds++;
      final int roundPulled;
      try {
        final pull = await _pullOnce(api);
        roundPulled = pull.pulled;
        limits = pull.limits ?? limits;
      } on ApiError catch (error) {
        if (error.code != 'unauthorized') rethrow;
        authFailed = true;
        break;
      }
      // A good pull proves the token lives — lift a stale auth notice.
      await _setNotice(syncNoticeAccountAuthFailed, false);
      pulled += roundPulled;
      var progressed = roundPulled > 0;
      if (!_pullOnly && !await _pushesHeld()) {
        final dirty = [
          for (final record in await _records.dirtyRecords())
            if (!refused.contains(record.id)) record,
        ];
        // Batched to the limits the pull advertised: one body past them
        // would be refused whole, identically every round.
        for (final batch in batchForPush(dirty, limits)) {
          final PushResponse response;
          try {
            response = await api.push(batch);
          } on ApiError catch (error) {
            if (error.code == 'unauthorized') {
              authFailed = true;
              break rounds;
            }
            // The batcher sends a record past a cap alone and last, so a
            // refused batch of one is that record's own failure: it stays
            // dirty, and the batches the server took stay pushed.
            if (error.code != _payloadTooLarge || batch.length != 1) rethrow;
            refused.add(batch.single.id);
            continue;
          }
          final sentById = {for (final record in batch) record.id: record};
          for (final result in response.results) {
            // Unrequested and repeated results cannot settle another edit.
            final sent = sentById.remove(result.id);
            if (sent == null) continue;
            final restored = await _records.settlePush(sent, result);
            if (result.accepted) {
              pushed++;
              progressed = true;
            } else {
              // The push lost server-side LWW: the copy the server actually
              // holds is the displaced pulled winner, so put it back —
              // leaving the losing edit in place would diverge the fleet
              // (04 §3.2's push-ties-or-loses re-check). A rejection with no
              // displaced winner stays dirty for the next pull to reconcile.
              if (restored != null) {
                progressed = true;
                final context = _contextFor(holdActive: false);
                switch (await _dispatch(restored, context)) {
                  case ApplyOutcome.applied:
                    report.appliedIds.add(restored.id);
                  case ApplyOutcome.deferred:
                    report.deferredIds.add(restored.id);
                  case ApplyOutcome.skipped:
                }
              }
            }
          }
        }
      }
      // No durable state changed this round (nothing pulled, nothing
      // accepted, nothing restored): the next iteration would replay the
      // identical delta pull and push, so stop instead of spinning to the
      // rounds cap. Rejected dirt stays dirty for the next sync.
      if (!progressed) break;
    }
    await _applyPulledInto(report);
    await _deferredPassphraseCheck();
    if (authFailed) {
      await _setNotice(syncNoticeAccountAuthFailed, true);
    }
    return SyncRoundResult(
      pulled: pulled,
      pushed: pushed,
      rounds: rounds,
      report: report,
      pushesHeld: await _pushesHeld(),
      authFailed: authFailed,
      refusedIds: refused.toList(),
    );
  }

  /// 04 §4.5's hold: while `passphraseUnverified` is set, no push leaves
  /// the device — the first push under a wrong key would itself be the
  /// corruption (records no correct-passphrase device could ever read).
  Future<bool> _pushesHeld() async =>
      await _enrollment?.passphraseUnverified() ?? false;

  ApplyContext _contextFor({required bool holdActive}) => ApplyContext(
    records: _records,
    crypto: _crypto,
    writer: _writer,
    tripwires: _tripwires,
    holdActive: holdActive,
  );

  Future<ApplyContext> _applyContext() async =>
      _contextFor(holdActive: await _pushesHeld());

  Future<void> _setNotice(String notice, bool active) async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    // Skip the durable write when nothing changes — a good pull reaches
    // here every round, and an unconditional set is a settings-file write
    // (and observer notification) per round for the app's lifetime.
    if ((await enrollment.notices()).contains(notice) == active) return;
    await enrollment.setNotice(notice, active);
  }

  /// The deferred trial-decrypt (04 §4.5): while the hold stands, the flag
  /// clears only on a **foreign** non-tombstone record that decrypts — this
  /// device's own output would vacuously clear it under whatever key sealed
  /// it. Every foreign candidate on a decryptable id is tried (a corrupt
  /// one cannot condemn the passphrase — the three-cause copy exists
  /// precisely because a single failure is ambiguous); a success clears
  /// the hold and the notice, and when every candidate fails the durable
  /// Settings → Backup error is raised with pushes still held.
  Future<void> _deferredPassphraseCheck() async {
    final enrollment = _enrollment;
    if (enrollment == null || !await enrollment.passphraseUnverified()) {
      return;
    }
    final candidates = [
      for (final record in await _records.allRecords())
        if (!record.deleted &&
            record.blob.isNotEmpty &&
            record.deviceId != _deviceId &&
            isDecryptableSyncId(record.id, _productHandlers))
          record,
    ]..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    var sawFailure = false;
    for (final record in candidates) {
      var verified = false;
      try {
        await _crypto.open(record);
        verified = true;
      } catch (_) {
        sawFailure = true;
      }
      if (!verified) continue;
      // The passphrase is verified — but the hold is the only gate
      // keeping stale-key ciphertext offline. Re-seal held writes
      // BEFORE lifting the flag: a clear-then-reseal window would let
      // the next round push whatever the unverified key sealed — the
      // fleet-poisoning the hold exists to prevent. Deliberately outside
      // the try: a re-seal failure must not masquerade as a passphrase
      // failure — it propagates and leaves the hold standing.
      await reSealPendingWrites();
      await enrollment.setPassphraseUnverified(false);
      await enrollment.setNotice(syncNoticePassphraseCheckFailed, false);
      // A catch-up that ran under the hold deferred whatever failed,
      // and those records sit behind the apply cursor: re-run it.
      await catchUpSecrets();
      return;
    }
    if (sawFailure) {
      await enrollment.setNotice(syncNoticePassphraseCheckFailed, true);
    }
  }

  /// The pull half of a round, with §3.1's one-time full-resync fallback:
  /// a rejected `since` cursor resets both cursors and re-pulls from zero,
  /// so `applyPulled` re-scans the lifetime set.
  Future<({int pulled, PushLimits? limits})> _pullOnce(SyncApi api) async {
    PullResponse response;
    try {
      response = await api.pull(since: await _records.highWaterSeq());
    } on SyncCursorRejectedException {
      await _records.resetSyncCursors();
      response = await api.pull(since: 0);
    }
    var snapshot = await _records.highWaterSeq();
    for (final remote in response.records) {
      final seq = remote.seq;
      if (seq != null && seq > snapshot) snapshot = seq;
      // The store merges under the same Lww the server ran — a loser is
      // dropped or parked behind the dirty rival it lost to.
      await _records.putRemote(remote);
    }
    await _records.setHighWaterSeq(snapshot);
    return (pulled: response.records.length, limits: response.limits);
  }

  /// Materialize pulled records — see [applyPulled].
  Future<ApplyReport> applyPulled() async {
    final report = ApplyReport();
    await _applyPulledInto(report);
    return report;
  }

  /// The apply pass (04 §3.2): dispatch every stored record with
  /// `seq > lastAppliedSeq` in seq order, then advance the cursor — but
  /// only past records that were applied or terminally skipped, never past
  /// a seen-but-deferred one (a delta pull never re-delivers a passed seq;
  /// a deferred record's re-check is the rival's next push instead). While
  /// §4.5's passphrase hold stands a decrypt failure defers rather than
  /// skips — it is not terminal, and the corrected-passphrase re-pull must
  /// find the record still ahead of the apply cursor.
  Future<void> _applyPulledInto(ApplyReport report) async {
    final cursor = await _records.lastAppliedSeq();
    final context = await _applyContext();
    final dirtyIds = (await _records.dirtyRecords()).map((r) => r.id).toSet();
    final pending = [
      for (final record in await _records.allRecords())
        if (record.seq != null &&
            record.seq! > cursor &&
            !dirtyIds.contains(record.id))
          record,
    ]..sort((a, b) => a.seq!.compareTo(b.seq!));

    var advanceTo = cursor;
    int? blockedAt;
    Future<void> account(EncryptedRecord record, ApplyOutcome outcome) async {
      if (outcome == ApplyOutcome.deferred) {
        report.deferredIds.add(record.id);
        blockedAt = blockedAt == null
            ? record.seq
            : min(blockedAt!, record.seq!);
        return;
      }
      if (outcome == ApplyOutcome.applied) {
        report.appliedIds.add(record.id);
      }
      if (blockedAt == null && record.seq! > advanceTo) {
        advanceTo = record.seq!;
      }
    }

    // `account` is awaited per record; `seq` is non-null by construction
    // of `pending`/`lastPending` (filtered above).

    // Records of the secrets phase apply after every other dispatch: the
    // exclusion shield judges them against the round's *final* server set,
    // not the store as their seq position found it.
    final lastPending = <EncryptedRecord>[];
    for (final record in pending) {
      if (_handlers[syncIdPrefix(record.id)]?.phase == ApplyPhase.secrets) {
        lastPending.add(record);
        continue;
      }
      await account(record, await _dispatch(record, context));
    }
    for (final record in lastPending) {
      await account(record, await _dispatch(record, context));
    }

    // The other deferral channel: pulled losers parked behind a dirty local
    // rival. They are outside the seq scan (not stored), but they are still
    // seen-but-deferred — report them and keep the cursor honest below
    // them.
    for (final displaced in await _records.displacedRecords()) {
      final seq = displaced.seq;
      if (seq != null && seq > cursor) {
        report.deferredIds.add(displaced.id);
        blockedAt = blockedAt == null ? seq : min(blockedAt!, seq);
      }
    }
    final blocked = blockedAt;
    if (blocked != null && advanceTo >= blocked) {
      advanceTo = blocked - 1;
    }
    if (advanceTo > cursor) {
      await _records.setLastAppliedSeq(advanceTo);
    }

    report.pinConflicts.addAll(await pinConflicts());
    final catalog = _catalog;
    if (catalog != null) await _rebuildCatalog(catalog);
  }

  /// Route one record by its plaintext id prefix — *before* decrypting
  /// (04 §3.2): the prefix decides whether a record is decrypted at all,
  /// the decrypted kind decides whether it is applied. Prefixes no handler
  /// claims (`snippet:` and every unrecognized `<prefix>:`) are
  /// skip-preserved without ever being opened, and so are prefixless and
  /// `secret:` ids outside shared mode, whose handlers have no store.
  /// Tombstones carry no sealed kind, so the prefix alone routes them to
  /// [RecordHandler.applyTombstone]; `hostkey:` and `secret:` tombstones
  /// stay no-ops there — honouring those would hand the server a primitive
  /// for stripping this device's pins or vault.
  Future<ApplyOutcome> _dispatch(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    final handler = _handlers[syncIdPrefix(record.id)];
    if (handler == null) return ApplyOutcome.skipped;
    return record.deleted
        ? handler.applyTombstone(record, context)
        : handler.applyLive(record, context);
  }

  /// Decrypt for the catalog backfill: a failure means the record is not
  /// for this vault key (or is corrupt ciphertext) — preserved untouched.
  Future<DecryptedRecord?> _openForApply(EncryptedRecord record) async {
    try {
      return await _crypto.open(record);
    } catch (_) {
      return null;
    }
  }

  /// Decode a stored `hostkey:` record for the quarantine diff — null on
  /// any failure (the tripwire is the apply scan's job, not the diff's).
  Future<HostKey?> _decodePin(EncryptedRecord record) async {
    try {
      final dec = await _crypto.open(record);
      if (dec.kind != RecordKind.hostKey) return null;
      final pin = HostKey.fromJson(dec.data);
      return record.id == pin.recordId ? pin : null;
    } catch (_) {
      return null;
    }
  }

  /// Rebuild the shared-mode catalog from the server store. First a
  /// backfill pass adopts any decodable prefixless record with no
  /// materialized tuple — pulled by a build that predates the writable
  /// store, or otherwise never dispatched past the apply cursor — under
  /// its own envelope tuple; waiting for a seq the cursor already passed
  /// would leave the catalog empty until the next upstream edit.
  Future<void> _rebuildCatalog(CatalogController catalog) async {
    final store = _servers;
    if (store == null) {
      catalog.replace(const []);
      return;
    }
    for (final record in await _records.allRecords()) {
      if (record.deleted || syncIdPrefix(record.id) != null) continue;
      final dec = await _openForApply(record);
      if (dec == null || dec.kind != RecordKind.serverConfig) continue;
      try {
        final config = ServerConfig.fromJson(dec.data);
        if (config.id != record.id) continue;
        if (await store.syncTupleOf(config.id) != null) continue;
        await _tripwires.clear(record.id);
        await store.applySyncedRecord(
          config,
          ServerSyncTuple(
            updatedAt: record.updatedAt,
            deviceId: record.deviceId,
          ),
        );
      } catch (_) {
        // Left to the apply scan's tripwire.
      }
    }
    catalog.replace(await store.load());
  }
}
