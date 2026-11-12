import 'dart:developer' as developer;
import 'dart:math' show max;

import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart';

import '../catalog/host_key_mutations.dart';
import '../catalog/pin_verdicts.dart';
import '../catalog/record_coordinator.dart' show HostKeyConflict;
import '../inbox/inbox_service.dart';
import '../inbox/inbox_stores.dart';
import '../store/stores.dart';
import 'legacy_envelope_migration.dart';
import 'local_record_store.dart';
import 'sync_engine.dart';

const int _warningLogLevel = 900;
const String _recordKindDelimiter = ':';
const String _hostKeyIdPrefix = 'hostkey$_recordKindDelimiter';
const String _secretIdPrefix = 'secret$_recordKindDelimiter';
const String _snippetIdPrefix = 'snippet$_recordKindDelimiter';
const String _syncLoggerName = 'seance.sync';

typedef _ApplySkip = void Function(
  String id,
  Object error,
  StackTrace stackTrace, {
  bool? permanent,
});

Future<T> _runLocalDirectly<T>(Future<T> Function() action) => action();

/// A domain source whose latest enumeration lost data to a read failure.
///
/// An empty healthy source means absence and may cancel a pending publication.
/// An incomplete source means absence is unknown: the sync mirror must retain
/// authenticated, policy-eligible dirty records until the source is repaired.
abstract interface class SyncCollectionHealth {
  bool get syncCollectionFailed;

  /// Persist that the mirror has been applied and recollected successfully.
  Future<void> markSyncCollectionRecovered();
}

bool _collectionFailed(Object? source) =>
    source is SyncCollectionHealth && source.syncCollectionFailed;

bool _sameJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !_sameJson(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

/// The sealed kind of a durable local deletion intent. Older stores persist
/// only the plaintext envelope, so the stable id namespace supplies the kind
/// when an upgraded client turns that intent into an authenticated tombstone.
RecordKind _tombstoneKind(String id) {
  final delimiter = id.indexOf(_recordKindDelimiter);
  if (delimiter < 0) return RecordKind.serverConfig;
  return switch (id.substring(0, delimiter)) {
    'hostkey' => RecordKind.hostKey,
    'secret' => RecordKind.secret,
    'snippet' => RecordKind.snippet,
    'bookmark' => RecordKind.bookmark,
    'assistant' => RecordKind.assistantSettings,
    'inboxapp' => RecordKind.inboxApp,
    'inboxstatus' => RecordKind.inboxStatus,
    'klabautermann' => RecordKind.klabautermann,
    _ => RecordKind.unknown,
  };
}

bool _isSeancePublication(String id) => switch (_tombstoneKind(id)) {
      RecordKind.serverConfig ||
      RecordKind.hostKey ||
      RecordKind.secret ||
      RecordKind.snippet ||
      RecordKind.assistantSettings ||
      RecordKind.inboxApp ||
      RecordKind.inboxStatus =>
        true,
      RecordKind.bookmark ||
      RecordKind.klabautermann ||
      RecordKind.unknown =>
        false,
    };

/// Bridges the app's domain objects (server configs, pinned host keys, and —
/// opt-in — secrets) to the encrypted record layer and back, then drives a
/// [SyncEngine] round. Records are keyed by their domain id and disambiguated
/// by [RecordKind], so applying pulled records routes each to the right store.
///
/// Each round re-collects the domain stores, but semantic matches retain the
/// mirror's existing ciphertext, sequence and dirty state. This lets durable
/// cursors skip old downloads without turning every unchanged object into a
/// newly encrypted upload.
class SyncCoordinator {
  final ConfigStore configStore;

  /// The TOFU pins. Conflict-aware because a pulled pin is written only
  /// when it agrees with the local one: a separate read and write could
  /// overwrite a key the connection flow pinned in between.
  final ConflictAwareHostKeyStore hostKeyStore;

  /// The user's pin verdicts (catalog-library.md §7): a locator under a
  /// negative pin never takes a pulled key, and a conflict whose pulled
  /// fingerprint the user already rejected is not raised again. Null means
  /// no verdicts are kept, so every conflict is raised; a pulled pin that
  /// disagrees with the local one is never written either way.
  final PinVerdictStore? pinVerdicts;
  final RecordCodec codec;
  final LocalRecordStore local;
  final String deviceId;

  /// Optional snippet store. When present, snippets sync like server configs.
  final SnippetStore? snippetStore;

  /// Opt-in assistant-configuration syncing. Null — the default — means the
  /// record is neither pushed nor applied, so a device that has not opted in
  /// keeps its own provider, model and keys whatever the account carries.
  ///
  /// When it is set, the assistant's API keys travel inside the sealed record
  /// whether or not [syncSecrets] is on. The two switches are about different
  /// things — [syncSecrets] governs the credentials servers authenticate with
  /// — but `syncSecrets: false` is the flag a reader would reach for to keep
  /// key material off the server, so the exception is worth stating here. The
  /// seal is the protection, the same one synced passwords get.
  final AssistantSettingsStore? assistantStore;

  /// Whether an assistant record is worth having on the account at all.
  ///
  /// One predicate for both sides on purpose. [collectLocal] asks it before
  /// publishing and the apply loop asks it before adopting, and the two must
  /// answer identically: a record one side publishes and the other skips is
  /// parked on the account under a stamp nothing older can displace, and one
  /// the publish side would refuse but the apply side takes is adopted over a
  /// working configuration. Written out twice, that symmetry survives only
  /// until someone edits one copy. The reasoning behind each clause is at the
  /// two call sites, which is where it is load-bearing.
  static bool _isViableAssistantRecord(AssistantSettings s) =>
      s.providerKind.isNotEmpty && s.updatedAt > 0;

  /// Opt-in secret syncing. When true, [secretVault] and [secretIds] must be
  /// provided so secrets can be sealed into records.
  ///
  /// Governs server credentials only: the assistant's API keys travel with
  /// [assistantStore]'s record whatever this says — see there.
  final bool syncSecrets;
  final SecretVault? secretVault;

  /// Durable record of servers (and other kinds) the user has deleted, awaiting
  /// propagation. Optional so the pure-Dart tests and any embedding without a
  /// deletion path can omit it; when present, [collectLocal] republishes each
  /// pending tombstone so the engine pushes it, and [run] prunes it once the
  /// sync server has taken it. Null means deletions are not propagated — the
  /// pre-existing behaviour, which the app no longer relies on.
  final TombstoneStore? tombstoneStore;

  /// The command inbox's connected apps and handled statuses. Optional like
  /// the snippet store; null means neither kind is published or applied.
  ///
  /// An app record carries the app's key inside the seal whatever
  /// [syncSecrets] says: without the key a device cannot open the proposals
  /// the server keeps for it. Neither kind is ever deleted by a tombstone.
  /// An app is removed by a sealed record marking it removed rather than a
  /// tombstone, and a status is only ever added.
  final InboxAppStore? inboxAppStore;
  final InboxStatusStore? inboxStatusStore;

  /// Clock for the status retention cutoff; injectable for tests.
  final DateTime Function() now;

  SyncCoordinator({
    required this.configStore,
    required this.hostKeyStore,
    this.pinVerdicts,
    required this.codec,
    required this.local,
    required this.deviceId,
    this.snippetStore,
    this.assistantStore,
    this.syncSecrets = false,
    this.secretVault,
    this.tombstoneStore,
    this.inboxAppStore,
    this.inboxStatusStore,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// The pulled `hostkey:` records the latest [applyToStores] held back
  /// because they disagree with this device's pin (Séance #56). Re-derived
  /// on every apply from the mirror against the live store, never stored,
  /// so a conflict stays until the user resolves it or the account stops
  /// carrying the pulled key. [PulledPinResolver] resolves one.
  List<HostKeyConflict> get pinConflicts => List.unmodifiable(_pinConflicts);
  List<HostKeyConflict> _pinConflicts = const [];

  /// [pulled] as a conflict to raise, or null when it is not one after all
  /// (the local pin changed since the conditional write refused it) or the
  /// user already kept their pin over this very key.
  Future<HostKeyConflict?> _pinConflict(HostKey pulled) async {
    final local = await hostKeyStore.get(pulled.host, pulled.port);
    if (local == null || !local.conflictsWith(pulled)) return null;
    final rejected = await pinVerdicts?.rejectedFingerprintFor(pulled.locator);
    if (rejected == pulled.fingerprintSha256) return null;
    return HostKeyConflict(
      locator: pulled.locator,
      local: local,
      pulled: pulled,
    );
  }

  /// Whether [pin] is the key the user already rejected and no current local
  /// trust decision has since installed that same key deliberately.
  ///
  /// The second half matters after `known_hosts.json` damage: absence is not
  /// permission to adopt the rejected key merely because there is no longer a
  /// local pin for [putIfNoConflict] to conflict with. A matching current pin,
  /// on the other hand, is an explicit later trust decision and may sync.
  Future<bool> _rejectedWithoutTrustedMatch(HostKey pin) async {
    final rejected =
        await pinVerdicts?.rejectedFingerprintFor(pin.locator);
    if (rejected != pin.fingerprintSha256) return false;
    final trusted = await hostKeyStore.get(pin.host, pin.port);
    return trusted?.fingerprintSha256 != pin.fingerprintSha256;
  }

  /// The credentials [servers] opt into publishing to the account.
  ///
  /// One rule in one place: [collectLocal] decides what to publish with it and
  /// [_reviveSecrets] decides what is worth re-dating with it, and the two are
  /// only correct while they agree. This used to be a predicate inside
  /// `collectLocal`'s loop, leaning on the `continue` above it for the
  /// excluded half — a shape the second caller could only copy, not share, so
  /// adding a condition would have reached one and missed the other.
  Set<String> _publishableSecretRefs(List<ServerConfig> servers) => {
        if (syncSecrets)
          for (final server in servers)
            if (!server.excludeFromSync &&
                server.syncSecret &&
                server.secretRef != null &&
                // The app's own vault entries are never a credential, even
                // under a config that names one.
                !isReservedVaultId(server.secretRef!))
              server.secretRef!,
      };

  /// Host-key locators an actively synced server names.
  ///
  /// Orphan pins are withheld too. A peer cannot use one without its server
  /// config, and after an excluded config is lost to file corruption its
  /// payload-less tombstone no longer reveals which locator must stay local.
  /// Publishing only affirmative live references therefore fails closed for
  /// that privacy choice. A later synced config naming the address makes the
  /// existing local pin eligible again.
  static Set<String> _publishableHostKeyLocators(
    List<ServerConfig> servers,
  ) =>
      {
        for (final server in servers)
          if (!server.excludeFromSync)
            hostKeyLocator(server.host, server.port),
      };

  /// Stage a trusted domain value only when its semantic contents changed.
  ///
  /// Encryption uses a random nonce, so encrypting first would make equal
  /// values look different and mark every record dirty on every round. A
  /// pulled semantic match may also carry another device's id and a server
  /// sequence; both belong to the existing winner and must survive local
  /// collection. An unchanged dirty value stays dirty with the same bytes so
  /// an interrupted push retries exactly what it previously attempted. A
  /// valid mirror tuple that outranks a stale domain snapshot is also kept;
  /// the apply pass will materialize that winner instead of uploading a loss.
  Future<bool> _stageLocal(DecryptedRecord desired) async {
    final existing = await local.getRecord(desired.id);
    if (existing != null) {
      try {
        final current = await codec.decrypt(existing);
        if (current.id == desired.id &&
            current.kind == desired.kind &&
            current.updatedAt == desired.updatedAt &&
            current.deleted == desired.deleted &&
            (!desired.deleted || current.deviceId == desired.deviceId) &&
            _sameJson(current.data, desired.data)) {
          return false;
        }
        final sameStamp = existing.updatedAt == desired.updatedAt;
        // Live domain rows do not retain the record device id. Rebuilding an
        // unapplied peer winner with this device's larger id would therefore
        // turn stale equal-stamp content into a winning upload. Durable
        // deletion intents do retain their deleting device id, so tombstones
        // can still use the complete LWW tuple on a tie.
        final existingWins = existing.updatedAt > desired.updatedAt ||
            (sameStamp && !desired.deleted) ||
            (sameStamp &&
                desired.deleted &&
                existing.deviceId.compareTo(desired.deviceId) >= 0);
        if (existingWins) return false;
      } catch (_) {
        // A legacy, damaged or wrong-key mirror entry is replaced from the
        // trusted domain store below and retried as a current envelope.
      }
    }
    await local.putLocal(await codec.encrypt(desired));
    return true;
  }

  Future<void> _cancelUncollectedDirty(Set<String> collectedIds) async {
    final publications = local;
    if (publications is! LocalPublicationStore) return;
    for (final record in await publications.dirtyRecords()) {
      // A tombstone is an explicit deletion or retraction, not an opt-in live
      // publication. Only a newer live domain value may supersede it. This is
      // also what keeps confirmed deletions queued across a failed rollback
      // recovery after their original TombstoneStore intent was pruned.
      if (record.deleted) continue;
      if (!collectedIds.contains(record.id) &&
          _isSeancePublication(record.id)) {
        await publications.cancelLocal(record.id);
      }
    }
  }

  /// Remove re-queued pins local trust policy withholds before a surviving
  /// local pin can stage the shared id. Otherwise [_stageLocal] correctly
  /// keeps the newer mirror tuple, but `stage()` has already marked that id
  /// collected and rollback recovery would republish the withheld key.
  Future<void> _cancelWithheldDirtyHostKeys(Set<String> negativePins) async {
    final publications = local;
    if (publications is! LocalPublicationStore) return;
    for (final record in await publications.dirtyRecords()) {
      if (record.deleted || !record.id.startsWith(_hostKeyIdPrefix)) continue;
      final HostKey pin;
      try {
        final decoded = await codec.decrypt(record);
        if (decoded.kind != RecordKind.hostKey) continue;
        pin = HostKey.fromJson(decoded.data);
        if (decoded.id != pin.recordId) continue;
      } catch (_) {
        // Malformed records are classified and canceled by the strict apply
        // pass during recovery; ordinary collection must not guess at them.
        continue;
      }
      // Verdict and domain-store failures are not malformed mirror bytes. Let
      // them fail the collection rather than silently republishing a key whose
      // trust decision could not be checked.
      final trusted = await hostKeyStore.get(pin.host, pin.port);
      if (negativePins.contains(pin.locator) ||
          (trusted != null && trusted.conflictsWith(pin)) ||
          await _rejectedWithoutTrustedMatch(pin)) {
        await publications.cancelLocal(record.id);
      }
    }
  }

  Future<List<DecryptedRecord>> _readableMirrorRecords({
    required bool dirtyOnly,
  }) async {
    final records = dirtyOnly
        ? await local.dirtyRecords()
        : await local.allRecords();
    final readable = <DecryptedRecord>[];
    for (final record in records) {
      try {
        readable.add(await codec.decrypt(record));
      } catch (_) {
        // Invalid mirror bytes are not evidence that a failed source owned a
        // valid domain value. Normal cancellation removes dirty copies.
      }
    }
    return readable;
  }

  Iterable<SyncCollectionHealth> get _failedCollectionSources sync* {
    for (final source in [
      configStore,
      snippetStore,
      hostKeyStore,
      inboxStatusStore,
    ]) {
      if (source is SyncCollectionHealth && source.syncCollectionFailed) {
        yield source;
      }
    }
  }

  Future<void> _markCollectionSourcesRecovered() async {
    for (final source in _failedCollectionSources.toList()) {
      await source.markSyncCollectionRecovered();
    }
  }

  /// Encode current local state into the record store (as local edits).
  ///
  /// Local credential edits must use [SecretVault.putLocalSecret] so their
  /// versions advance independently of unrelated server configuration edits.
  Future<int> collectLocal({bool cancelMissing = true}) async {
    var changed = 0;
    final collectedIds = <String>{};
    Future<void> stage(DecryptedRecord desired) async {
      collectedIds.add(desired.id);
      if (await _stageLocal(desired)) changed++;
    }

    final servers = await configStore.listServers();
    final policyServers = <String, ServerConfig>{
      for (final server in servers) server.id: server,
    };
    if (_collectionFailed(configStore)) {
      for (final record in await _readableMirrorRecords(dirtyOnly: false)) {
        if (record.deleted || record.kind != RecordKind.serverConfig) continue;
        try {
          final server = ServerConfig.fromJson(record.data);
          if (server.id != record.id ||
              (server.secretRef != null &&
                  isReservedVaultId(server.secretRef!))) {
            continue;
          }
          policyServers.putIfAbsent(server.id, () => server);
          // A live excluded config should already be a retraction, never a
          // publication. Preserve only the live values a complete collection
          // would have staged.
          if (!server.excludeFromSync) collectedIds.add(record.id);
        } catch (_) {
          continue;
        }
      }
    }
    final serversForPolicy = policyServers.values.toList();

    final publishableHostKeyLocators =
        _publishableHostKeyLocators(serversForPolicy);
    // The same rule, for credentials: nothing prevents two configs pointing at
    // one vault entry, and a credential a still-synced server holds must keep
    // reaching the devices that want it.
    final syncedSecretRefs = <String>{};
    for (final s in serversForPolicy) {
      final ref = s.secretRef;
      if (ref != null && !s.excludeFromSync) syncedSecretRefs.add(ref);
    }

    // Record ids of domain objects that still exist this round. A pending
    // tombstone whose id is still present was re-created (import/migration) or
    // never actually removed, so it is not republished — see the tombstone
    // loop. Read from the stores, not the sync mirror: the mirror persists
    // across rounds and can hold a live copy of a just-deleted record that
    // must not suppress its tombstone. Fetched once and reused for the snippet
    // publishing loop.
    final snippetList = await snippetStore?.listSnippets() ?? const <Snippet>[];
    if (_collectionFailed(snippetStore)) {
      for (final record in await _readableMirrorRecords(dirtyOnly: true)) {
        if (record.deleted || record.kind != RecordKind.snippet) continue;
        try {
          final snippet = Snippet.fromJson(record.data);
          if (record.id == '$_snippetIdPrefix${snippet.id}') {
            collectedIds.add(record.id);
          }
        } catch (_) {
          continue;
        }
      }
    }
    final presentIds = <String>{
      for (final s in servers) s.id,
      for (final s in snippetList) '$_snippetIdPrefix${s.id}',
    };

    final publishedSecretRefs = _publishableSecretRefs(serversForPolicy);
    for (final server in servers) {
      if (server.excludeFromSync) {
        changed += await _retract(server, syncedSecretRefs, collectedIds.add);
        continue;
      }
      await stage(DecryptedRecord(
        id: server.id,
        kind: RecordKind.serverConfig,
        updatedAt: server.updatedAt,
        deviceId: deviceId,
        data: server.toJson(),
      ));
    }
    // Publish each opted-in credential at its own edit time. Legacy local
    // entries use zero until an actual edit or a remote version supplies a
    // stamp, so an unrelated server rename cannot promote stale material.
    // Older clients still borrow server timestamps and need upgrading for
    // this protection to hold on every device.
    for (final ref in publishedSecretRefs) {
      // The durable mirror may be the only readable copy after the vault blob
      // is damaged. Keep an already-staged publication eligible before trying
      // the vault read; null below means "cannot mint a replacement", not that
      // the user opted out and the recoverable mirror copy should be cancelled.
      collectedIds.add('$_secretIdPrefix$ref');
      // [SecretVault.readableSecret] again, and here it is what makes the
      // repair in [_applySecretRecords] reachable at all: this runs before the
      // round's pull, so an entry that will not open would throw out of
      // `collectLocal` and take the whole round with it — every server, every
      // pin, on every future round — leaving the record that could have fixed
      // it forever unpulled. There is nothing publishable in a credential that
      // cannot be opened, so skip it and let the pull heal it. A store that
      // cannot be read still throws, as everywhere else: a round built on a
      // vault nobody could look at would retract nothing and publish nothing,
      // which is not the same as having nothing to say.
      final secret = await secretVault?.readableSecret(ref);
      if (secret == null) continue;
      await stage(DecryptedRecord(
        id: '$_secretIdPrefix${secret.id}',
        kind: RecordKind.secret,
        updatedAt: secret.updatedAt,
        deviceId: deviceId,
        data: secret.toJson(),
      ));
    }
    // Deletions the user made are remembered in [tombstoneStore], not in
    // configStore — the row is gone. Republish each as a dirty tombstone so the
    // engine pushes it and last-write-wins carries the delete to the server and
    // every other device, instead of the deleted record returning on the next
    // full pull and being re-adopted by [applyToStores]. Pruned in [run] once
    // the server has the tombstone. A config tombstone is honoured on apply
    // regardless of the payload it replaces (routed by its bare id), so the
    // deletion converges even for a kind a peer cannot yet decode. The
    // durable store holds a local deletion intent, not a wire-ready record:
    // seal its routing and conflict tuple under the account key here.
    for (final tombstone
        in await tombstoneStore?.all() ?? const <EncryptedRecord>[]) {
      // Skip a tombstone whose id still names a live domain object this round:
      // an id re-created (import or migration) while its delete was pending, or
      // one whose row-drop was interrupted. Publishing it would push a delete
      // for something that exists. Checked against [presentIds] (the stores),
      // not the mirror, so it holds however the mirror is backed; the app also
      // clears a pending tombstone when its id is re-saved.
      if (presentIds.contains(tombstone.id)) continue;
      final kind = _tombstoneKind(tombstone.id);
      if (kind == RecordKind.unknown) continue;
      await stage(DecryptedRecord(
        id: tombstone.id,
        kind: kind,
        updatedAt: tombstone.updatedAt,
        deviceId: tombstone.deviceId,
        deleted: true,
      ));
    }
    final hostKeys = await hostKeyStore.all();
    final negativePins = await pinVerdicts?.negativePins() ?? const {};
    await _cancelWithheldDirtyHostKeys(negativePins);
    if (_collectionFailed(hostKeyStore)) {
      for (final record in await _readableMirrorRecords(dirtyOnly: true)) {
        if (record.deleted || record.kind != RecordKind.hostKey) continue;
        final HostKey pin;
        try {
          pin = HostKey.fromJson(record.data);
        } catch (_) {
          continue;
        }
        if (record.id == pin.recordId &&
            publishableHostKeyLocators.contains(pin.locator) &&
            !negativePins.contains(pin.locator) &&
            !await _rejectedWithoutTrustedMatch(pin)) {
          collectedIds.add(record.id);
        }
      }
    }
    for (final hk in hostKeys) {
      if (!publishableHostKeyLocators.contains(hk.locator) ||
          negativePins.contains(hk.locator)) {
        // Withheld, not retracted: peer removal of a local TOFU decision
        // remains a separate product policy. Orphan pins are withheld as well
        // as excluded-only pins so a lost excluded config cannot make its
        // address publishable merely by disappearing from local policy.
        continue;
      }
      await stage(DecryptedRecord(
        id: hk.recordId,
        kind: RecordKind.hostKey,
        updatedAt: hk.pinnedAt,
        deviceId: deviceId,
        data: hk.toJson(),
      ));
    }
    // The contract reserves null for "the keys could not be vouched for this
    // round", but the real store backs onto an OS keyring, and a locked or
    // missing one surfaces from a platform channel as a throw. Uncaught, one
    // failed keystore read would abandon the rest of this method — the
    // snippets below it would never be collected, and a round's worth of
    // unrelated records would pay for the assistant's keyring. Degrading to
    // null costs the assistant the round it was going to sit out anyway.
    if (assistantStore != null) {
      // As for credentials above, a prior offline edit in the durable mirror
      // remains valid when today's keyring read fails. A null store is the
      // actual opt-out signal and deliberately leaves this id uncollected.
      collectedIds.add(AssistantSettings.recordId);
    }
    AssistantSettings? assistant;
    try {
      assistant = await assistantStore?.getAssistantSettings();
    } catch (_) {
      assistant = null;
    }
    // The apply side's guard, at the boundary where bad data enters: an empty
    // provider means a payload this build could not read, not a configuration
    // — the same degradation `fromJson` makes of a missing field can happen
    // to a device's own settings file — and publishing one would park a
    // record no device adopts on the account under this device's stamp,
    // where nothing older can displace it.
    // And the stamp, which is the other half of "is this worth publishing".
    // Zero means this device has never edited its assistant — the sentinel
    // `AppState.assistantSyncSwitchedOn` reads before it decides to stamp and
    // publish. Without it here, a device that opted in with nothing
    // configured parks its *shipped defaults* on the account at stamp zero,
    // and the next device to opt in — every install that configured its
    // assistant before this feature existed reads zero too — adopts them over
    // a working provider, model and keys, because `0 < 0` is false. That is
    // the exact harm the switch-on guard exists to prevent; guarding the
    // stamp bump alone left this path open.
    if (assistant != null && _isViableAssistantRecord(assistant)) {
      await stage(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        // The settings' own timestamp, not the round's: collectLocal runs
        // every five minutes, and a moving one would make each round a fresh
        // winning write and set two devices trading the record forever.
        updatedAt: assistant.updatedAt,
        deviceId: deviceId,
        data: assistant.toJson(),
      ));
    }
    for (final s in snippetList) {
      await stage(DecryptedRecord(
        id: '$_snippetIdPrefix${s.id}',
        kind: RecordKind.snippet,
        updatedAt: s.updatedAt,
        deviceId: deviceId,
        data: s.toJson(),
      ));
    }
    if (inboxAppStore != null) {
      // FileInboxAppStore withholds a live app when its vault key is damaged.
      // An already-staged sealed record may be the only remaining key copy and
      // can heal that store during apply, so an enabled store protects dirty
      // inbox-app publications it cannot hydrate today. A null store remains
      // the explicit opt-out signal.
      for (final record in await local.dirtyRecords()) {
        if (record.id.startsWith(kInboxAppIdPrefix)) {
          collectedIds.add(record.id);
        }
      }
    }
    for (final app
        in await inboxAppStore?.listApps() ?? const <InboxApp>[]) {
      await stage(DecryptedRecord(
        id: app.recordId,
        kind: RecordKind.inboxApp,
        updatedAt: app.updatedAt,
        deviceId: deviceId,
        data: app.toJson(),
      ));
    }
    final statusCutoff = _statusCutoff();
    final statuses =
        await inboxStatusStore?.listStatuses() ?? const <InboxStatus>[];
    if (_collectionFailed(inboxStatusStore)) {
      for (final record in await _readableMirrorRecords(dirtyOnly: true)) {
        if (record.deleted || record.kind != RecordKind.inboxStatus) continue;
        try {
          final status = InboxStatus.fromJson(record.data);
          if (record.id == status.recordId &&
              status.updatedAt >= statusCutoff) {
            collectedIds.add(record.id);
          }
        } catch (_) {
          continue;
        }
      }
    }
    for (final status in statuses) {
      // Past retention a status names nothing any server still holds, and
      // publishing it every round would only grow every device's mirror.
      if (status.updatedAt < statusCutoff) continue;
      await stage(DecryptedRecord(
        id: status.recordId,
        kind: RecordKind.inboxStatus,
        updatedAt: status.updatedAt,
        deviceId: deviceId,
        data: status.toJson(),
      ));
    }
    if (cancelMissing) await _cancelUncollectedDirty(collectedIds);
    return changed;
  }

  /// Tombstone every status past retention that the server still holds live.
  ///
  /// Each handled proposal mints its own record id, and the server keeps a
  /// row until it is deleted, so live statuses would otherwise pile up
  /// against the account's record quota, which every app on the account
  /// shares. Only a clean, sequenced mirror copy is retired: that is the
  /// server's row, while a status that never left this device needs no
  /// tombstone. The tombstone is dated just after the status, so any later
  /// edit of it still wins, and once the mirror holds a tombstone the id is
  /// skipped, so devices settle on one tombstone instead of trading them.
  /// Clients that predate this ignore an `inboxstatus:` tombstone on apply.
  ///
  /// Called only after a completed pull, when a clean sequenced copy is known
  /// to be the server's row. Before the pull a rejected cursor could still
  /// show that the server never had it.
  Future<int> _retireExpiredStatuses() async {
    if (inboxStatusStore == null) return 0;
    final statusCutoff = _statusCutoff();
    final dirtyIds = {
      for (final record in await local.dirtyRecords()) record.id,
    };
    var retired = 0;
    for (final record in await local.allRecords()) {
      if (record.deleted ||
          record.seq == null ||
          record.updatedAt >= statusCutoff ||
          dirtyIds.contains(record.id) ||
          !record.id.startsWith(kInboxStatusIdPrefix)) {
        continue;
      }
      final DecryptedRecord status;
      try {
        status = await codec.decrypt(record);
      } catch (_) {
        // Not this device's to judge: the apply pass reports unreadable rows.
        continue;
      }
      if (status.kind != RecordKind.inboxStatus) continue;
      final tombstone = status.tombstone(
        updatedAt: status.updatedAt + 1,
        deviceId: deviceId,
      );
      if (await _stageLocal(tombstone)) retired++;
    }
    return retired;
  }

  int _statusCutoff() =>
      now().millisecondsSinceEpoch - kInboxStatusRetention.inMilliseconds;

  /// Retract a server the user has excluded from sync: tombstone its record,
  /// and its credential's, so a copy pushed before the exclusion comes off the
  /// server — and the server row off the devices that pulled it, which honour
  /// the config tombstone. They keep their vault entry because peer removal of
  /// local credential material remains a separate product policy; the routing
  /// comment in [applyToStores] has the reasoning. Doing nothing instead would
  /// leave the
  /// blob on the server forever while this device silently stopped updating
  /// it, which is a worse answer than either syncing or not.
  ///
  /// The record id is `secret:` + [ServerConfig.secretRef], which is the same
  /// id [collectLocal] pushes under: [SecretVault.putSecret] keys the blob by
  /// `secret.id` and serializes that same id inside it, so a secret read back
  /// through a ref always reports that ref as its id. Resolving the ref
  /// through the vault here to "be sure" would trade a guaranteed match for a
  /// decryption that throws when the OS keyring is locked — turning a locked
  /// keyring into a silently skipped retraction.
  ///
  /// Dated at [ServerConfig.updatedAt] rather than "now" for two reasons.
  /// Excluding a server *is* an edit, so that timestamp already is the moment
  /// the user asked for this — later than the copy on the server, and it loses
  /// to a genuinely newer edit made elsewhere exactly as any other write would.
  /// And a fixed date makes the tombstone identical between rounds, so the
  /// server sequences it once and later rounds simply adopt their own
  /// tombstone back instead of minting a new sequence number every five
  /// minutes.
  ///
  /// The credential is tombstoned whatever [syncSecrets] and
  /// [ServerConfig.syncSecret] say: those govern *pushing* one, and this
  /// device cannot tell from here whether an earlier session with different
  /// settings already did. Withdrawing a credential that was never there costs
  /// an id-shaped row; leaving one behind because we were unsure costs the
  /// credential.
  ///
  /// That row is a real disclosure and worth naming: a credential the user
  /// never synced has its ref published to the sync server as a tombstone id.
  /// It is a `uuidV4` minted for the vault, carrying no host, user or label,
  /// so what the server learns is that a credential exists — and it stops
  /// there, because the id is not honoured as a delete anywhere. Gating this
  /// on the current [syncSecrets] instead would trade that for the failure
  /// that actually matters: a credential the user *did* publish under older
  /// settings, left on the sync server with nothing that will ever withdraw
  /// it.
  ///
  /// Unless a still-synced server shares it, which [syncedSecretRefs] names.
  /// A secret record is keyed by the credential, not by the server holding it,
  /// so a tombstone dated at the exclusion would beat that server's own push
  /// of the same id every round — quietly and permanently ending credential
  /// sync for a server the user never excluded. That set counts a sharer
  /// whose own [ServerConfig.syncSecret] is off too, which is the
  /// conservative side of the same trade: a credential such a sharer once
  /// published stays on the server rather than being withdrawn from under a
  /// server that still holds it.
  Future<int> _retract(
    ServerConfig server,
    Set<String> syncedSecretRefs,
    void Function(String) collected,
  ) async {
    var changed = 0;
    collected(server.id);
    if (await _tombstone(
      server.id,
      RecordKind.serverConfig,
      server.updatedAt,
    )) {
      changed++;
    }
    final secretRef = server.secretRef;
    if (secretRef != null && !syncedSecretRefs.contains(secretRef)) {
      collected('$_secretIdPrefix$secretRef');
      if (await _tombstone(
        '$_secretIdPrefix$secretRef',
        RecordKind.secret,
        server.updatedAt,
      )) {
        changed++;
      }
    }
    return changed;
  }

  Future<bool> _tombstone(String id, RecordKind kind, int updatedAt) {
    return _stageLocal(DecryptedRecord(
      id: id,
      kind: kind,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: true,
    ));
  }

  /// Re-date a credential this device retracted and then opted back in to,
  /// and report how many moved.
  ///
  /// The credential analogue of [_revive], and needed for the same reason: a
  /// retraction is dated from the config that carried it, so re-including the
  /// server leaves a tombstone the credential's own edit time — which the
  /// switch did not touch — loses to. Without this the config comes back while
  /// its credential stays withdrawn, and a device enrolling afterwards gets a
  /// server it cannot log into.
  ///
  /// The bump is written to the vault as well as staged, which does move a
  /// stamp the user did not earn by editing the material. Two reasons it has
  /// to: the record's payload carries the same stamp as its envelope and a
  /// peer *rejects* the pair when they disagree ([_applySecretRecords]), and a
  /// vault left behind would republish the losing date every round. It is the
  /// same fiction [_revive] applies to a re-included config, bounded the same
  /// way — one millisecond past the retraction, a deterministic function of a
  /// date already on the record, so it settles instead of bidding.
  ///
  /// [servers] is the effective list [applyToStores] maintains while applying
  /// this batch. It includes live config writes and excludes config
  /// tombstones without a second store read that could straddle another
  /// mutation. A credential therefore revives only when a config survives the
  /// same batch and [collectLocal] would publish it on the next round.
  Future<int> _reviveSecrets(
    List<(String, int)> refs,
    List<ServerConfig> servers,
    _ApplySkip skip,
  ) async {
    final vault = secretVault;
    if (refs.isEmpty || !syncSecrets || vault == null) return 0;
    final published = _publishableSecretRefs(servers);
    var bumpedCount = 0;
    for (final (ref, retractedAt) in refs) {
      // Still retracted as far as this device is concerned: the switch is off
      // again, or off for every owner. Nothing to bring back.
      if (!published.contains(ref)) continue;
      // Fail-soft per credential, like [_revive]: a locked keyring on one
      // entry must not throw out of `applyToStores` and discard the round.
      try {
        final secret = await vault.getSecret(ref);
        // Gone, or already outranking its own retraction — [collectLocal]
        // publishes a winning date on its own and needs no help. Counting it
        // would spend a sync round on a batch that changed nothing.
        if (secret == null || secret.updatedAt > retractedAt) continue;
        final bumped = secret.copyWith(updatedAt: retractedAt + 1);
        // Staged first, stored second, for the reason spelled out in
        // [_revive]: a failed store write is retried identically next round,
        // while a failed stage after a successful store write would leave the
        // guard above dropping this credential forever.
        await _stageLocal(DecryptedRecord(
          id: '$_secretIdPrefix$ref',
          kind: RecordKind.secret,
          updatedAt: bumped.updatedAt,
          deviceId: deviceId,
          data: bumped.toJson(),
        ));
        await vault.putSecret(bumped);
        bumpedCount++;
      } catch (error, stackTrace) {
        skip('$_secretIdPrefix$ref', error, stackTrace);
      }
    }
    return bumpedCount;
  }

  /// Drop pending tombstones that are done, so [tombstoneStore] stays bounded.
  ///
  /// [collectLocal] republishes every entry each round (unless its id is a
  /// live record again — see [presentIds]). An entry is done in two cases, both
  /// judged from the sequenced record the mirror holds after the round:
  ///
  ///  * a sequenced tombstone — this round's push was accepted, or a pull
  ///    carried the server's own copy back: the delete has propagated.
  ///  * a sequenced live record strictly newer than the tombstone — a peer's
  ///    later edit won last-write-wins (or the id was re-created), so the
  ///    tombstone can never win and [collectLocal] already skips it; retrying
  ///    it forever would only leak store entries.
  ///
  /// Everything else stays: an unconfirmed entry (a round that pushed nothing —
  /// offline), or a live record the tombstone still outranks (an interrupted
  /// row-drop, where the delete may yet win). Dropping either would strand a
  /// deletion while the record resurrects.
  Future<void> _pruneConfirmedTombstones() async {
    final store = tombstoneStore;
    if (store == null) return;
    for (final pending in await store.all()) {
      final mirrored = await local.getRecord(pending.id);
      if (mirrored == null || mirrored.seq == null) continue;
      if (mirrored.deleted || mirrored.updatedAt > pending.updatedAt) {
        await store.remove(pending.id);
      }
    }
  }

  /// Write every record in the local store back into the domain stores,
  /// honouring tombstones. Returns the number of records that had to be
  /// re-dated — retractions the server outranked (see [rescheduleOutranked])
  /// plus servers re-included behind their own retraction (see [_revive]) — so
  /// the caller knows a further push is worth making. When [requireComplete]
  /// is true, a transient domain-store failure is thrown after the remaining
  /// records are inspected. Schema and integrity failures remain fail-soft;
  /// retrying cannot make those records safe to apply.
  Future<int> applyToStores({
    bool requireComplete = false,
    void Function(String id)? onPermanentReject,
  }) async {
    // A server excluded from sync is local-only, so nothing pulled may touch
    // it: not the tombstone this device pushed to retract it (which comes back
    // on the next pull sequenced by the server), and not a copy another device
    // is still pushing because it has not seen that tombstone yet. Its
    // credential is shielded on the same grounds, in [_applySecretRecords].
    final servers = await configStore.listServers();
    final effectiveServers = {for (final server in servers) server.id: server};
    final excluded = <String>{
      for (final server in servers)
        if (server.excludeFromSync) server.id,
    };
    // Credentials are decided after the loop rather than inside it: whether one
    // may be applied or withdrawn depends on which servers still reference it,
    // and a config record in the same batch may be about to add or remove the
    // last reference. Record order is not defined, so deciding inline would
    // make the outcome depend on it.
    final secretRecords = <DecryptedRecord>[];
    // Host keys are likewise decided after configs and tombstones have landed.
    // A pin is publishable only while a live synced config names its address,
    // so applying it inline would make the answer depend on record order.
    final hostKeyRecords = <DecryptedRecord>[];
    // Live configs for servers this device excluded: see [rescheduleOutranked].
    final outranked = <DecryptedRecord>[];
    // Servers this device re-included whose own retraction still outranks
    // them: see the tombstone branch below.
    final revived = <(ServerConfig, int)>[];
    // Credentials of those servers, as `(ref, retracted at)`. A credential's
    // own edit time does not move when the user merely flips the switch back,
    // so unlike a config it cannot outrank its retraction on its own.
    final revivedSecrets = <(String, int)>[];
    final skippedIds = <String>[];
    final pinConflicts = <HostKeyConflict>[];
    final negativePins = await pinVerdicts?.negativePins() ?? const {};
    // Inbox app removals re-dated past a live copy that beat them; see the
    // inboxApp case. Counted with the other re-datings so [run] pushes them.
    var redatedRemovals = 0;
    Object? firstError;
    StackTrace? firstStackTrace;
    Object? firstTransientError;
    StackTrace? firstTransientStackTrace;
    void skip(
      String id,
      Object error,
      StackTrace stackTrace, {
      bool? permanent,
    }) {
      skippedIds.add(id);
      firstError ??= error;
      firstStackTrace ??= stackTrace;
      if (permanent == true) {
        onPermanentReject?.call(id);
      } else {
        firstTransientError ??= error;
        firstTransientStackTrace ??= stackTrace;
      }
    }

    T? decode<T>(String id, T Function() read) {
      try {
        return read();
      } catch (error, stackTrace) {
        skip(id, error, stackTrace, permanent: true);
        return null;
      }
    }

    for (final enc in await local.allRecords()) {
      final DecryptedRecord dec;
      try {
        dec = await codec.decrypt(enc);
      } catch (error, stackTrace) {
        skip(enc.id, error, stackTrace, permanent: true);
        continue;
      }
      try {
        // Tombstones carry an authenticated kind and tuple. The id prefix is
        // still what routes their application policy after codec validation.
        // A `snippet:` tombstone is applied like a config below (a snippet is
        // non-secret settings, the same risk class as a config). The other
        // prefixed kinds — `secret:`, `hostkey:` — remain deliberate policy
        // no-ops: a peer deleting shared ciphertext is not yet permission to
        // erase this device's vault material or local TOFU decision.
        if (dec.deleted) {
          final routedKind = _tombstoneKind(dec.id);
          if (routedKind == RecordKind.unknown || dec.kind != routedKind) {
            skip(
              dec.id,
              StateError('tombstone kind ${dec.kind.name} does not match '
                  'record id ${dec.id}'),
              StackTrace.current,
              permanent: true,
            );
            continue;
          }
          // Routed on the delimiter alone because a config id never carries
          // one: every config is minted with `uuidV4()` (the editor's draft
          // id and the ssh_config import), and the prefixed kinds are the
          // only ids that contain it.
          if (!dec.id.contains(_recordKindDelimiter)) {
            if (excluded.contains(dec.id)) continue;
            // Our own retraction, for a server this device is no longer
            // excluding: the user turned the switch back off. Deleting here
            // would honour a decision that has since been reversed — and the
            // re-included config cannot win it back on its own, because the
            // tombstone may have been re-dated past this device's clock by
            // [rescheduleOutranked]. So the live record is re-dated instead,
            // the mirror of that escalation, and the delete is skipped.
            // Not named `local`: that is the record store this method
            // writes through, and shadowing it here would let a later edit
            // reach for `local.putLocal` and silently get a ServerConfig.
            final localServer = await configStore.getServer(dec.id);
            // Only this device's own retraction is revived past. A peer's
            // tombstone for the same server — both devices excluded it, and
            // the peer's exclusion outranks this device's re-inclusion —
            // deletes a config this device just re-included, with nothing to
            // say so. Dropping the guard would resurrect configs legitimately
            // deleted elsewhere, so the residual stands until a delete can
            // carry its intent; pinned by "a peer's later exclusion outranks
            // a re-inclusion".
            if (localServer != null && dec.deviceId == deviceId) {
              revived.add((localServer, dec.updatedAt));
              continue;
            }
            await configStore.deleteServer(dec.id);
            effectiveServers.remove(dec.id);
            continue;
          }
          // A credential retraction yields when this device still publishes a
          // config that names the entry. That includes peer tombstones: a
          // concurrent peer edit can retire the old credential while this
          // device's newer config still wins LWW with the old reference. If
          // the surviving vault material could not outbid that tombstone, the
          // converged config would name a credential no new device can fetch.
          // [_reviveSecrets] checks publishability, so a true orphan remains
          // withdrawn and no tombstone reaches the vault.
          if (dec.id.startsWith(_secretIdPrefix)) {
            revivedSecrets.add((
              dec.id.substring(_secretIdPrefix.length),
              dec.updatedAt,
            ));
            continue;
          }
          // A `snippet:` tombstone IS applied, unlike `secret:`/`hostkey:`: a
          // snippet is non-secret settings, the same risk class as a config.
          // The refused kinds stay staged for a future explicit removal policy
          // (they simply fall through this branch to the `continue`).
          final snippets = snippetStore;
          if (snippets != null &&
              dec.id.length > _snippetIdPrefix.length &&
              dec.id.startsWith(_snippetIdPrefix)) {
            await snippets
                .deleteSnippet(dec.id.substring(_snippetIdPrefix.length));
          }
          continue;
        }

        switch (dec.kind) {
          case RecordKind.serverConfig:
            if (excluded.contains(dec.id)) {
              outranked.add(dec);
              continue;
            }

            final pulled = decode<ServerConfig>(
              dec.id,
              () => ServerConfig.fromJson(dec.data),
            );
            if (pulled == null) continue;
            // The exclusion shield above keys on the *record* id, and this
            // write would key on the payload's. A record whose two ids
            // disagree — schema drift, a buggy peer, anything hand-made by a
            // device that has the key — would slip a config past the shield,
            // and land under an id no tombstone can ever name.
            if (pulled.id != dec.id) {
              skip(
                dec.id,
                StateError(
                  'config id ${pulled.id} does not match record id ${dec.id}',
                ),
                StackTrace.current,
                permanent: true,
              );
              continue;
            }
            // A config naming one of the app's own vault entries as its
            // credential would aim edits and deletes of that server at it.
            final secretRef = pulled.secretRef;
            if (secretRef != null && isReservedVaultId(secretRef)) {
              skip(
                dec.id,
                StateError('config credential $secretRef is reserved'),
                StackTrace.current,
                permanent: true,
              );
              continue;
            }
            await configStore.putServer(pulled);
            effectiveServers[pulled.id] = pulled;
          case RecordKind.hostKey:
            hostKeyRecords.add(dec);
          case RecordKind.secret:
            secretRecords.add(dec);
          case RecordKind.snippet:
            final store = snippetStore;
            if (store == null) continue;

            final snippet = decode<Snippet>(
              dec.id,
              () => Snippet.fromJson(dec.data),
            );
            if (snippet == null) continue;
            // LWW and tombstones name the envelope id; the store writes the
            // payload id. They must identify the same snippet or this record
            // can overwrite one whose newer edit or deletion already won.
            if (dec.id != '$_snippetIdPrefix${snippet.id}') {
              skip(
                dec.id,
                StateError(
                  'snippet id ${snippet.id} does not match record id ${dec.id}',
                ),
                StackTrace.current,
                permanent: true,
              );
              continue;
            }
            await store.putSnippet(snippet);
          case RecordKind.assistantSettings:
            final store = assistantStore;
            if (store == null) continue;

            final assistant = decode<AssistantSettings>(
              dec.id,
              () => AssistantSettings.fromJson(dec.data),
            );
            if (assistant == null) continue;
            // `fromJson` degrades a missing field to '' rather than throwing,
            // so that a record from a newer build stays readable. A provider
            // name is the one field that can never legitimately be empty — it
            // is written from an enum — so an empty one means the payload is
            // not a configuration, and adopting it would replace a working
            // assistant with nothing on every device that pulled it.
            // And a stamp of zero, for the same reason one is never
            // published: zero means "never edited here", so no compliant
            // client puts one on the wire and two devices cannot legitimately
            // tie at it. Refusing it here costs no convergence — unlike
            // widening the comparison below, which would refuse a real tie —
            // and it keeps a record parked by an older build, or by a client
            // that does not follow this rule, from being adopted over a
            // working configuration by every device still reading zero.
            if (!_isViableAssistantRecord(assistant)) {
              skip(
                dec.id,
                const FormatException('assistant settings are not viable'),
                StackTrace.current,
                permanent: true,
              );
              continue;
            }

            // This record won last-write-wins against the synced *mirror*,
            // which is only as fresh as the last [collectLocal]. Unlike a
            // server config, the assistant configuration is edited straight
            // into its store between rounds — so an edit made while a round
            // was already in flight is newer than anything the mirror knows,
            // and applying an older pulled record over it would lose the edit
            // silently, then re-collect and publish the loss.
            //
            // Strictly older, not older-or-equal: a tie between two records
            // is already resolved at the record layer by device id and
            // sequence, and skipping ties here would stop two devices ever
            // converging on one of them. The tie that resolution never sees is
            // a local edit that did not reach the mirror this round — made
            // after [collectLocal] ran, or withheld by it because a key it
            // references could not be read. That edit loses to a pulled record
            // sharing its stamp, which is the narrow price of convergence and
            // why the edit stamp is minted as fine-grained as the clock
            // allows.
            if (assistant.updatedAt < await store.assistantSettingsUpdatedAt()) {
              continue;
            }

            await store.putAssistantSettings(assistant);
          case RecordKind.inboxApp:
            final store = inboxAppStore;
            if (store == null) continue;

            final app = decode<InboxApp>(
              dec.id,
              () => InboxApp.fromJson(dec.data),
            );
            if (app == null) continue;
            if (dec.id != app.recordId) {
              skip(
                dec.id,
                StateError('inbox app ${app.id} does not match record id '
                    '${dec.id}'),
                StackTrace.current,
                permanent: true,
              );
              continue;
            }
            final existing = await store.getApp(app.id);
            // Removal is final: an app id is never reused, so a live copy
            // arriving after this device saw the removal is a stale one, and
            // adopting it would bring back a revoked key.
            //
            // It can only arrive by beating the removal at last-write-wins,
            // though: another device edited the app later, or under a clock
            // ahead of this one. Skipping it alone would leave that copy on
            // the account for good, and every other device keeping the key.
            // So the removal is re-dated past it and pushed again, the same
            // escalation [rescheduleOutranked] makes for a retraction.
            if (existing != null && existing.removed) {
              // Past the later of the copy's stamps and the removal's own, so
              // the removal never moves backwards.
              if (!app.removed) {
                final redated = existing.asRemoved(
                  updatedAt: [dec.updatedAt, app.updatedAt, existing.updatedAt]
                          .reduce(max) +
                      1,
                );
                await _stageLocal(DecryptedRecord(
                  id: redated.recordId,
                  kind: RecordKind.inboxApp,
                  updatedAt: redated.updatedAt,
                  deviceId: deviceId,
                  data: redated.toJson(),
                ));
                await store.putApp(redated);
                redatedRemovals++;
              }
              continue;
            }
            // Strictly older, for the reason the assistant path gives: an
            // edit made between rounds is newer than the mirror knows.
            if (existing != null && app.updatedAt < existing.updatedAt) {
              continue;
            }
            await store.putApp(app);
          case RecordKind.inboxStatus:
            final store = inboxStatusStore;
            if (store == null) continue;

            final status = decode<InboxStatus>(
              dec.id,
              () => InboxStatus.fromJson(dec.data),
            );
            if (status == null) continue;
            if (dec.id != status.recordId) {
              skip(
                dec.id,
                StateError('inbox status ${status.recordId} does not match '
                    'record id ${dec.id}'),
                StackTrace.current,
                permanent: true,
              );
              continue;
            }
            if (status.updatedAt < _statusCutoff()) continue;
            await store.putStatus(status);
          // Poltergeist's bookmarks and Klabautermann's settings belong to
          // the sibling apps: kept as pulled, never applied or rewritten.
          case RecordKind.bookmark:
          case RecordKind.klabautermann:
          case RecordKind.unknown:
            continue;
        }
      } catch (error, stackTrace) {
        skip(enc.id, error, stackTrace);
      }
    }
    await _applyHostKeyRecords(
      hostKeyRecords,
      negativePins,
      pinConflicts,
      skip,
    );
    _pinConflicts = pinConflicts;

    await _applySecretRecords(secretRecords, skip);

    // Both re-dating passes report through `skip` too, so they run before
    // the log line, not after it: a tombstone that could not be minted or a
    // revival that could not be staged was landing in `skippedIds` a moment
    // after the only reader of `skippedIds` had already spoken.
    final redated = redatedRemovals +
        await rescheduleOutranked(outranked, skip) +
        await _revive(revived, skip) +
        await _reviveSecrets(
          revivedSecrets,
          effectiveServers.values.toList(growable: false),
          skip,
        );
    if (skippedIds.isNotEmpty) {
      developer.log(
        'Skipped synced records: ${skippedIds.join(', ')}',
        name: _syncLoggerName,
        level: _warningLogLevel,
        error: firstError,
        stackTrace: firstStackTrace,
      );
    }
    if (requireComplete && firstTransientError != null) {
      Error.throwWithStackTrace(
        firstTransientError!,
        firstTransientStackTrace!,
      );
    }
    return redated;
  }

  /// Apply pulled pins after the batch's configs, failing closed when no live
  /// synced config names the address or the user already rejected this key.
  Future<void> _applyHostKeyRecords(
    List<DecryptedRecord> records,
    Set<String> negativePins,
    List<HostKeyConflict> pinConflicts,
    _ApplySkip skip,
  ) async {
    final publishableLocators = _publishableHostKeyLocators(
      await configStore.listServers(),
    );
    for (final dec in records) {
      final HostKey pin;
      try {
        pin = HostKey.fromJson(dec.data);
      } catch (error, stackTrace) {
        skip(dec.id, error, stackTrace, permanent: true);
        continue;
      }
      // The same id invariant the config and secret paths enforce: a pin is
      // stored under its payload's locator, and a record whose id names
      // another would plant trust for an address no record ever named.
      if (dec.id != pin.recordId) {
        skip(
          dec.id,
          StateError(
            'host key locator ${pin.locator} does not match record id '
            '${dec.id}',
          ),
          StackTrace.current,
          permanent: true,
        );
        continue;
      }
      if (!publishableLocators.contains(pin.locator) ||
          negativePins.contains(pin.locator)) {
        continue;
      }
      try {
        if (await _rejectedWithoutTrustedMatch(pin)) continue;
        // A pulled pin that disagrees with this device's is held back, never
        // written (Séance #56): on a hostile network a forged record would
        // otherwise win trust on every device.
        final installed = await hostKeyStore.putIfNoConflict(pin);
        if (installed == HostKeyInstallResult.installed) continue;
        final conflict = await _pinConflict(pin);
        if (conflict != null) pinConflicts.add(conflict);
      } catch (error, stackTrace) {
        skip(dec.id, error, stackTrace);
      }
    }
  }

  /// Re-date a re-included server past the retraction it is still losing to.
  ///
  /// Excluding under a clock this device runs behind re-dates the tombstone to
  /// beat the copy that beat it — which can be past this device's own clock.
  /// Turning the switch back off then stamps an honest "now" that still loses,
  /// so the server would stay retracted everywhere else and this device would
  /// apply its own stale retraction and delete the config it had just brought
  /// back. Persisting the bump is what makes it stick: a fresh timestamp each
  /// round would be a new winning write every five minutes, which is the churn
  /// [_retract]'s stable date exists to avoid.
  Future<int> _revive(
    List<(ServerConfig, int)> servers,
    _ApplySkip skip,
  ) async {
    var bumpedCount = 0;
    for (final (config, retractedAt) in servers) {
      if (config.updatedAt > retractedAt) continue;
      // Fail-soft per record, like the loop that produced this list: a
      // transient store error on one server would otherwise throw out of
      // `applyToStores`, discarding the sync outcome the round had already
      // earned and skipping the second pass — turning one flaky write into a
      // whole failed round.
      try {
        final bumped = config.copyWith(updatedAt: retractedAt + 1);
        // The staged record first, the store second. The bump is a
        // deterministic function of the retraction's date, so a failed
        // `putServer` is retried identically next round — but a failed
        // `putLocal` *after* a successful `putServer` is never retried,
        // because the store then reports `updatedAt > retractedAt` and the
        // guard above drops this server from `revived` forever. The bump
        // would never reach a peer, while the losing pre-bump record still
        // would, and the next pull's tombstone would delete the config the
        // user had just brought back.
        await _stageLocal(DecryptedRecord(
          id: bumped.id,
          kind: RecordKind.serverConfig,
          updatedAt: bumped.updatedAt,
          deviceId: deviceId,
          data: bumped.toJson(),
        ));
        await configStore.putServer(bumped);
        bumpedCount++;
      } catch (error, stackTrace) {
        skip(config.id, error, stackTrace);
      }
    }
    // What was bumped, not what was offered: a server already outranking its
    // own retraction needs nothing, and counting it would spend an extra sync
    // round on a batch that changed nothing.
    return bumpedCount;
  }

  /// Store pulled credentials, shielding the ones only excluded servers name.
  ///
  /// A stale remote version of a local-only server's credential would
  /// otherwise overwrite the vault entry that server still uses. Shielded only
  /// when *no* synced server shares it — the same "every server that names it"
  /// rule the host-key locators use: a record for a ref a synced server holds
  /// is a live update for that server, not a stale copy of a local-only one.
  ///
  /// The rule is evaluated here, after the record loop, against the server
  /// list the whole batch produced: a config in the same batch may have just
  /// introduced the synced server that shares this credential, and deciding
  /// inline would have shielded it on a snapshot taken before that.
  Future<void> _applySecretRecords(
    List<DecryptedRecord> records,
    _ApplySkip skip,
  ) async {
    // The id invariant enforced here rather than left to the call site, like
    // the kind check in [rescheduleOutranked]: every id this method reasons
    // about is `secret:` + the vault ref, which is what [_shieldedSecretIds]
    // builds and what the shield is compared against. A record arriving under
    // any other id could not be shielded by construction, and would go to
    // `Secret.fromJson` to either throw into the skip diagnostics or, worse,
    // parse and be written into the vault as a credential nothing named.
    for (final dec in records.where((d) => !d.id.startsWith(_secretIdPrefix))) {
      // Through `skip`, not a log line of its own: correctly not written, but
      // every other drop in this method lands in `skippedIds`, and a peer
      // minting secret ids differently should show up where a reader is
      // already looking rather than in a channel of its own.
      skip(
        dec.id,
        StateError('secret record id is not `$_secretIdPrefix`-prefixed'),
        StackTrace.current,
        permanent: true,
      );
    }
    // After the id check, so a peer minting ids differently shows up on a
    // device that syncs no secrets too — otherwise the problem looks
    // device-specific while it is being chased.
    final vault = secretVault;
    if (!syncSecrets || vault == null) return;
    // A store read after the loop above has already written configs and host
    // keys: fail-soft like every other failure in this method, or one flaky
    // read throws out of `applyToStores` past the re-dating passes and the
    // log, and the round's outcome goes with it.
    // One predicate, computed once: the two loops below have to agree with
    // each other and with the check above on what a secret record *is*, and a
    // copy each would let one be edited without the others.
    final prefixed =
        records.where((d) => d.id.startsWith(_secretIdPrefix)).toList();
    final Set<String> shielded;
    try {
      shielded = await _shieldedSecretIds();
    } catch (error, stackTrace) {
      for (final dec in prefixed) {
        skip(dec.id, error, stackTrace);
      }
      return;
    }
    for (final dec in prefixed) {
      if (shielded.contains(dec.id)) continue;
      final Secret secret;
      try {
        secret = Secret.fromJson(dec.data);
      } catch (error, stackTrace) {
        skip(dec.id, error, stackTrace, permanent: true);
        continue;
      }
      try {
        // The shield keys on the record id and the vault write keys on the
        // payload's: a record whose two disagree would slip a credential past
        // the shield and land it under a ref the shield never named — the
        // same hole the config path closes for its own id.
        if (dec.id != '$_secretIdPrefix${secret.id}') {
          skip(
            dec.id,
            StateError(
              'secret id ${secret.id} does not match record id ${dec.id}',
            ),
            StackTrace.current,
            permanent: true,
          );
          continue;
        }
        // The app's own vault entries (the recovery wrap key) are never a
        // credential: a record naming one would replace this device's
        // recovery and stop the code its user wrote down from working.
        if (isReservedVaultId(secret.id)) {
          skip(
            dec.id,
            StateError('secret id ${secret.id} is reserved'),
            StackTrace.current,
            permanent: true,
          );
          continue;
        }
        if (dec.data.containsKey('updatedAt') &&
            secret.updatedAt != dec.updatedAt) {
          skip(
            dec.id,
            StateError('secret timestamp does not match its record'),
            StackTrace.current,
            permanent: true,
          );
          continue;
        }
        // An older copy must not land on a newer local edit. Before a
        // credential carried a version of its own, the record store's
        // last-write-wins did this job: every referenced credential was
        // published every round, so an older remote never reached here as a
        // winner. Publishing is opt-in now, so a credential this device does
        // not publish has no record of its own standing in front of it, and
        // this floor is all that is left. Strictly newer, so a tie still
        // resolves where it always did — in the record layer, which breaks it
        // by device and seq; this only refuses what is plainly stale.
        // [SecretVault.readableSecret], not `getSecret`: an entry that will
        // not open is absent for this purpose, not something to protect. The
        // floor above exists to keep a newer local edit, and an entry with no
        // readable version has none to keep — while the record being weighed
        // against it is the only thing that can repair the damage. Letting the
        // read throw instead sends the record to `skip`, which leaves the
        // vault holding a credential the user cannot use and sync unable to
        // replace it, this round and every round after. Before a credential
        // carried a version at all this path simply overwrote, so failing
        // closed here would be a new way to lose one.
        //
        // A store that cannot be *read* still throws and still reaches the
        // per-record handler, which is the distinction that method exists to
        // keep: treating "I could not look" as "nothing there" would let a
        // transient fault overwrite material that was never unreadable.
        final existing = await vault.readableSecret(secret.id);
        if (existing != null && existing.updatedAt > dec.updatedAt) continue;
        // Legacy peers omit the payload stamp. Persist their envelope version
        // so subsequent local config edits never manufacture a newer one.
        await vault.putSecret(secret.copyWith(updatedAt: dec.updatedAt));
      } catch (error, stackTrace) {
        skip(dec.id, error, stackTrace);
      }
    }
  }

  /// Ids of credentials only excluded servers reference.
  Future<Set<String>> _shieldedSecretIds() async {
    final servers = await configStore.listServers();
    return <String>{
      for (final server in servers)
        if (server.excludeFromSync && server.secretRef != null)
          '$_secretIdPrefix${server.secretRef}',
    }..removeAll(<String>{
        for (final server in servers)
          if (!server.excludeFromSync && server.secretRef != null)
            '$_secretIdPrefix${server.secretRef}',
      });
  }

  /// Re-date retractions the server outranked, and report how many.
  ///
  /// [_retract] dates a tombstone at the config's `updatedAt` — the moment the
  /// user excluded the server, and so later than the copy on the server in the
  /// ordinary case. It is *not* later when another device wrote that copy
  /// under a clock this one runs behind, or edited it while this device was
  /// offline. Then the live record wins last-write-wins, the pull adopts it
  /// back over the tombstone, and every later round mints the same losing date
  /// again: the exclusion holds on this device forever while the config sits
  /// on the sync server and on every other device — a privacy switch failing
  /// silently in exactly the multi-device case it exists for.
  ///
  /// So a live config for an excluded server (which can only reach the local
  /// store by beating our tombstone) re-dates it one millisecond past the
  /// record that won, the smallest date that wins outright instead of tying.
  /// It escalates once and settles: the other device pushes its copy at a
  /// fixed `updatedAt` of its own, not a fresh one per round, so nothing
  /// bids back. Once the retraction lands, no live copy returns and
  /// [_retract]'s stable date takes over again.
  ///
  /// A credential is deliberately not re-dated the same way. A `secret:`
  /// record is keyed by the credential rather than by the server holding it,
  /// so a live one may be the ongoing push of a *synced* server on another
  /// device that shares the vault entry — one this device has not pulled yet,
  /// and whose owner never excluded anything. Out-bidding that would end
  /// credential sync for their server; the shield in [_applySecretRecords]
  /// already keeps the stale-copy case from touching this device's vault.
  ///
  /// The residual that leaves, stated rather than left to be rediscovered:
  /// when the live `secret:` record on the server is dated after the
  /// exclusion, the retraction loses and nothing escalates it, so the
  /// credential stays on the sync server. The shield protects this device's
  /// vault, not the remote copy. And because a `secret:` tombstone is not
  /// honoured against the vault at all (see the routing comment in
  /// [applyToStores]), the *other* device keeps its copy of the credential as
  /// an orphan no config names — inert, and invisible in a UI that lists
  /// servers, but not gone. Both residuals close the same way: sealed
  /// tombstones, which let a delete be trusted and so escalated.
  ///
  /// Visible for testing because the guard below is the whole point: a test
  /// that can only reach it through [applyToStores] — which filters first —
  /// proves the filter, never the guard.
  @visibleForTesting
  Future<int> rescheduleOutranked(
    List<DecryptedRecord> records, [
    void Function(String, Object, StackTrace)? skip,
  ]) async {
    // Both invariants this doc comment spends paragraphs on are enforced here
    // rather than left to the call site to preserve forever. Every record
    // reaching the loop is re-tombstoned, so an unfiltered list handed in by
    // some future path would delete every pulled config on every device — the
    // one mistake in this file whose blast radius is the whole account, and
    // it should not be a filter away. The kind check is the other half:
    // minting a tombstone one millisecond past a live `secret:` record is
    // exactly the harm described above.
    //
    // The exclusion is re-read from the store rather than checked against a
    // staged tombstone, which is what it looks like it should be: by the time
    // a record is in this list it *beat* that tombstone, so the local store
    // holds the winning config under that id and the tombstone is gone.
    final excluded = <String>{
      for (final server in await configStore.listServers())
        if (server.excludeFromSync) server.id,
    };
    // Live records only, checked here for the same reason as the kind: a
    // tombstone re-dated past itself would be a bid two excluding devices
    // could trade forever. A pulled tombstone never carries a kind (decrypt
    // returns `unknown` for one), so the kind check already refuses it; the
    // flag is the invariant stated in its own words.
    final configs = records
        .where((dec) =>
            dec.kind == RecordKind.serverConfig &&
            !dec.deleted &&
            excluded.contains(dec.id))
        .toList();
    var mintedCount = 0;
    for (final dec in configs) {
      try {
        await _tombstone(dec.id, dec.kind, dec.updatedAt + 1);
        mintedCount++;
      } catch (error, stackTrace) {
        if (skip == null) rethrow;
        skip(dec.id, error, stackTrace);
      }
    }
    return mintedCount;
  }

  /// One full synchronization round.
  ///
  /// Throws [SyncRecordsRefused] if the server refused records as too large,
  /// but only once everything else is done: what was pulled is applied and
  /// confirmed tombstones are pruned first. Thrown straight from the engine, a
  /// record the server refuses on every round would keep this device from
  /// ever applying another device's edit or deletion even though the durable
  /// mirror retained it.
  Future<SyncOutcome> run(SyncApi api) =>
      runStaged(api, runLocal: _runLocalDirectly);

  /// Runs one sync while holding [runLocal] only around mirror and domain-store
  /// work. Pulls and pushes happen between those phases, so a slow endpoint
  /// does not prevent unrelated local mutations from completing.
  Future<SyncOutcome> runStaged(
    SyncApi api, {
    required SyncLocalRunner runLocal,
  }) async {
    final resumingRecovery = await runLocal(() async {
      final recoverable = local is RecoverableSyncCursorStore
          ? local as RecoverableSyncCursorStore
          : null;
      return recoverable != null &&
          await recoverable.cursorRecoveryPending();
    });
    // Refresh present values, tombstones, and policy before a resumed zero
    // pull, but never infer deletion from absence until the recovered mirror
    // has been applied. This preserves a quarantined source while ensuring an
    // edit or deletion made after the phase was persisted still wins.
    await runLocal(
      () => collectLocal(cancelMissing: !resumingRecovery),
    );
    await migrateLegacyEnvelopes(
      api,
      store: local,
      runLocal: runLocal,
      openLegacy: codec.decryptLegacyForMigration,
      openCurrent: codec.decrypt,
      isEligible: _eligibleLegacyMigration,
    );
    final engine = SyncEngine(local, remoteValidator: _validRemoteRecord);
    // The latest pass's answer, not the union of both: a second pass pushes
    // every refused record that is still dirty again, so it knows which are
    // still refused and which a pulled copy has since settled.
    var refused = const <RefusedRecord>[];
    Future<SyncOutcome> pass() async {
      try {
        final outcome = await engine.sync(
          api,
          runLocal: runLocal,
          refreshLocal: (mode) => collectLocal(
            cancelMissing: mode != SyncLocalRefreshMode.cursorRecovery,
          ),
          beforeCursorRecoveryPull: () => collectLocal(cancelMissing: false),
          afterCursorRecovery: () async {
            // A transient domain-store failure must keep the durable recovery
            // phase pending. Recollecting after a failed write could treat the
            // absent row as an opt-out and discard the mirror's only copy.
            final rejected = <String>{};
            await applyToStores(
              requireComplete: true,
              onPermanentReject: rejected.add,
            );
            final publications = local;
            if (publications is LocalPublicationStore) {
              for (final id in rejected) {
                await publications.cancelLocal(id);
              }
            }
            await collectLocal();
            await _markCollectionSourcesRecovered();
          },
        );
        refused = const [];
        return outcome;
      } on SyncRecordsRefused catch (error) {
        refused = error.records;
        return error.outcome;
      }
    }

    final first = await pass();
    // A retraction the server outranked has been re-dated to beat the record
    // that beat it. Push it now: the next run would only re-mint the same
    // losing date [collectLocal] computes, so waiting never resolves it. One
    // extra pass, never a loop — a second re-dating is left to the next run.
    // Named, because the gate only means what the comment above says while
    // this is the *re-dating* count and not, say, the number of records
    // applied — which would double every round's traffic on the hot path,
    // hidden inside the summed outcome.
    final redated = await runLocal(() async {
      // A domain edit may have landed while the last network request was in
      // flight. Stage it before applying the pulled mirror so the edit's
      // conflict tuple, rather than the stale pre-request snapshot, decides.
      await collectLocal();
      final recoveringCollections = _failedCollectionSources.isNotEmpty;
      final changed =
          await applyToStores(requireComplete: recoveringCollections);
      if (recoveringCollections) {
        await collectLocal(cancelMissing: false);
        await _markCollectionSourcesRecovered();
      }
      return changed;
    });
    // Counted apart from [redated] for the reason given there. Pushed by the
    // same one extra pass, so a retirement does not wait for the next run.
    final retired = await runLocal(_retireExpiredStatuses);
    var outcome = first;
    var ranSecondPass = false;
    if (redated != 0 || retired != 0) {
      ranSecondPass = true;
      final second = await pass();
      outcome = SyncOutcome(
        pulled: first.pulled + second.pulled,
        pushed: first.pushed + second.pushed,
        rounds: first.rounds + second.rounds,
      );
    }
    final describedRefusals = await runLocal(() async {
      // Re-stage anything edited during the optional second pass before the
      // final apply. A re-dating produced here deliberately waits for the next
      // scheduled sync rather than opening an unbounded network loop.
      await collectLocal();
      if (ranSecondPass) await applyToStores();
      await _pruneConfirmedTombstones();
      return [
        for (final record in refused) await _describeRefused(record.id),
      ];
    });
    if (describedRefusals.isEmpty) return outcome;
    throw SyncRecordsRefused(describedRefusals, outcome: outcome);
  }

  /// A refused record as the user knows it: what it is and what it is called.
  ///
  /// Read back from the mirror, where it is still the dirty copy this device
  /// sealed. Naming is only for the message, so a record that cannot be read
  /// back is reported by its id rather than failing the report of a refusal.
  Future<RefusedRecord> _describeRefused(String id) async {
    try {
      final sealed = await local.getRecord(id);
      if (sealed == null) return RefusedRecord(id);
      final dec = await codec.decrypt(sealed);
      final name = switch (dec.kind) {
        RecordKind.snippet => Snippet.fromJson(dec.data).title,
        RecordKind.serverConfig => ServerConfig.fromJson(dec.data).label,
        _ => null,
      };
      return RefusedRecord(id, kind: dec.kind, name: name);
    } catch (_) {
      return RefusedRecord(id);
    }
  }

  /// Authenticate a pulled record before its plaintext conflict tuple can
  /// enter the LWW mirror. A failure still advances the observed server
  /// sequence in [SyncEngine], so one corrupt row cannot trap every later
  /// pull, but it can never displace a pending local edit or reach a domain
  /// store.
  Future<bool> _validRemoteRecord(EncryptedRecord record) async {
    try {
      await codec.decrypt(record);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _eligibleLegacyMigration(DecryptedRecord record) => switch (record.kind) {
        RecordKind.serverConfig || RecordKind.hostKey => true,
        RecordKind.secret => syncSecrets && secretVault != null,
        RecordKind.snippet => snippetStore != null,
        RecordKind.assistantSettings => assistantStore != null,
        RecordKind.inboxApp => inboxAppStore != null,
        RecordKind.inboxStatus => inboxStatusStore != null,
        RecordKind.bookmark ||
        RecordKind.klabautermann ||
        RecordKind.unknown =>
          false,
      };
}
