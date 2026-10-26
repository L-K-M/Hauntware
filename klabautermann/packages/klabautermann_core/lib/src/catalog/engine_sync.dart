/// Sync in the engine (03 §4.3, §4.4, D63): enrollment into the user's
/// Séance account, sync rounds and catalog writes through the catalog
/// library's `SyncEnrollment`, `RecordCoordinator` and `CatalogWriter`,
/// over the engine's own files in the support directory (03 §4.10).
/// The MVP ran pull-only (D14); v1 writes and pushes (M5 plan M05).
library;

import 'dart:async';
import 'dart:io';

import 'package:seance_core/catalog.dart'
    show
        CatalogMode,
        ConflictAwareHostKeyStore,
        FileServerConfigStore,
        HostKeyMutationGate,
        KdfDowngradeException,
        PersistentLocalRecordStore,
        PushPolicy,
        RecordCoordinator,
        RecordCrypto,
        SyncAccount,
        SyncAccountMode,
        SyncEnrollment,
        SyncEnrollmentApi,
        SyncTuple,
        WriteOutcome;
import 'package:seance_core/seance_core.dart'
    show
        ApiError,
        DecryptedRecord,
        HostKey,
        hostKeyLocator,
        HttpSyncClient,
        RecordCodec,
        RecordKind,
        Secret,
        SecretVault,
        ServerConfig,
        duplicateServerConfig,
        duplicateServerLabel,
        nextUpdatedAt,
        plannedCredential,
        plannedCredentialReadsStored,
        uuidV4,
        SyncEnrollmentMode,
        validateSyncEnrollment;

import '../engine/protocol.dart';
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'engine_vault.dart';
import 'keystore_channel.dart';
import 'klabautermann_records.dart';
import 'server_drafts.dart';
import 'sync_credentials.dart';
import 'sync_enrollment_file.dart';
import 'sync_state_file.dart';
import 'sync_verdict_files.dart';

/// The push policy every coordinator the engine builds runs under: local
/// edits seal through the catalog writer and every round pushes them (03
/// §4.4). The MVP ran pull-only (D14); v1 opened it (M5 plan M05, P9),
/// and the app's catalog writes test names the only requests that write.
const PushPolicy engineSyncPushPolicy = PushPolicy.normal;

/// The catalog library's files under the support directory (03 §4.10).
/// `host_keys.json` is not among them: the engine opens its one host-key
/// store with `openHostKeyPins` and hands it in (D61, D63), and
/// `vault.json` is [EngineVault]'s.
const String _syncRecordsFileName = 'sync_records.json';
const String _serversFileName = 'servers.json';

/// The sync server as enrollment and rounds reach it: the shared
/// `SyncEnrollmentApi` seam, which the app owns (catalog-library.md
/// section 10), plus releasing its connections.
abstract interface class SyncTransport implements SyncEnrollmentApi {
  void close();
}

/// Builds the transport for [baseUrl]; [token] restores a session for a
/// round, and enrollment passes none.
typedef SyncTransportFactory =
    SyncTransport Function(String baseUrl, {String? token});

/// Séance's HTTP sync client, which already has every member
/// [SyncTransport] names.
final class HttpSyncTransport extends HttpSyncClient implements SyncTransport {
  HttpSyncTransport(String baseUrl, {String? token}) : super(baseUrl: baseUrl) {
    this.token = token;
  }
}

/// The production [SyncTransportFactory].
SyncTransport httpSyncTransport(String baseUrl, {String? token}) =>
    HttpSyncTransport(baseUrl, token: token);

/// Enrollment and rounds for one engine. Every operation returns its final
/// [SyncStatus] and never throws; the engine runs them one at a time.
///
/// Sync signs in and writes only while this process holds the support
/// directory alone (D63): the catalog library's stores write their files
/// whenever they change, so a second process over the same files would
/// race them, and the device id may then have been minted by either. With
/// [SupportDirectoryAccess.unguarded] the engine still reads the
/// enrollment file, to show the account, and refuses every operation.
final class EngineSync {
  EngineSync._({
    required this._access,
    required this._deviceId,
    required this._enrollment,
    required this._pinVerdicts,
    required this._tripwires,
    required this._hostKeys,
    required this._keystore,
    required this._vault,
    required this._transport,
    required String Function(String name) path,
    required this._account,
    required this._klabautermannRecords,
  }) : _records = PersistentLocalRecordStore(path: path(_syncRecordsFileName)),
       _servers = FileServerConfigStore(
         path: path(_serversFileName),
         syncDeviceId: () => _deviceId,
       ) {
    _handler = KlabautermannRecordHandler(
      store: _klabautermannRecords,
      servers: _servers,
    );
  }

  /// Opens the sync state files in [supportDirectory] (none of the catalog
  /// library's files is read before an operation needs it). [deviceId] is
  /// `settings.json`'s; without one, enrollment state is not opened and
  /// every operation is refused. [hostKeys] is the engine's one host-key
  /// store, which its links share, [keystore] the app's keystore, and
  /// [vault] the engine's one vault over `vault.json`. Never throws.
  static Future<EngineSync> open({
    required Directory supportDirectory,
    required SupportDirectoryAccess access,
    required String? deviceId,
    required ConflictAwareHostKeyStore hostKeys,
    required SyncKeystore keystore,
    required EngineVault vault,
    SyncTransportFactory transport = httpSyncTransport,
  }) async {
    final usableId = deviceId == null || deviceId.isEmpty ? null : deviceId;
    final enrollment = usableId == null
        ? null
        : await FileSyncEnrollmentState.open(
            supportDirectory,
            deviceId: usableId,
            access: access,
          );
    final account = await enrollment?.account();
    return EngineSync._(
      access: access,
      deviceId: usableId,
      enrollment: enrollment,
      pinVerdicts: await FilePinVerdictStore.open(
        supportDirectory,
        access: access,
      ),
      tripwires: await FileSyncTripwireStore.open(
        supportDirectory,
        access: access,
      ),
      hostKeys: hostKeys,
      keystore: keystore,
      vault: vault,
      transport: transport,
      path: (name) => '${supportDirectory.path}${Platform.pathSeparator}$name',
      account: _info(account),
      klabautermannRecords: await KlabautermannRecordStore.open(
        supportDirectory,
        access: access,
      ),
    );
  }

  static SyncAccountInfo? _info(SyncAccount? account) => account == null
      ? null
      : SyncAccountInfo(baseUrl: account.baseUrl, username: account.username);

  final SupportDirectoryAccess _access;
  final String? _deviceId;
  final FileSyncEnrollmentState? _enrollment;
  final FilePinVerdictStore _pinVerdicts;
  final FileSyncTripwireStore _tripwires;
  final ConflictAwareHostKeyStore _hostKeys;
  final SyncKeystore _keystore;
  final SyncTransportFactory _transport;
  final PersistentLocalRecordStore _records;
  final FileServerConfigStore _servers;
  final EngineVault _vault;
  final KlabautermannRecordStore _klabautermannRecords;
  late final KlabautermannRecordHandler _handler;
  final HostKeyMutationGate _hostKeyMutations = HostKeyMutationGate();
  SyncAccountInfo? _account;

  /// The device's "sync passwords" switch (03 §4.5, SYN-02), which the
  /// app keeps in `settings.json` as `klabautermann.sync.secrets` and
  /// sends with [SetSyncSecrets]. Off until it says otherwise: while off,
  /// a round applies no pulled `secret:` record.
  bool get syncSecrets => _syncSecrets;
  var _syncSecrets = false;

  /// Sets [syncSecrets]. Turning it on applies the stored `secret:`
  /// records rounds skipped while it was off, which no later pull
  /// delivers again (`RecordCoordinator.catchUpSecrets`). Never throws: a
  /// catch-up that fails, or finds no key, leaves them for the next
  /// switch-on, which every engine start is.
  Future<void> setSyncSecrets({required bool enabled}) async {
    final turnedOn = enabled && !_syncSecrets;
    _syncSecrets = enabled;
    if (!turnedOn ||
        _account == null ||
        _refusal(SyncOperation.round) != null) {
      return;
    }
    try {
      final key = await _keystore.readMasterKey();
      if (key != null) {
        await _vault.exclusive(() => _coordinator(key).catchUpSecrets());
      }
    } on Object {
      // Left for the next switch-on, as documented above.
    }
  }

  /// The enrolled account, or null.
  SyncAccountInfo? get account => _account;

  /// What was wrong with each sync state file at open.
  List<SyncStoreIssue> get issues => [
    for (final (name, issue) in [
      (syncEnrollmentFileName, _enrollment?.issue),
      (pinVerdictsFileName, _pinVerdicts.issue),
      (syncTripwiresFileName, _tripwires.issue),
      (klabautermannRecordsFileName, _klabautermannRecords.issue),
    ])
      if (issue != null)
        SyncStoreIssue(
          name,
          switch (issue.kind) {
            SyncStateIssueKind.recovered => SyncStoreIssueKind.recovered,
            SyncStateIssueKind.leftAsIs => SyncStoreIssueKind.leftAsIs,
            SyncStateIssueKind.newerVersion => SyncStoreIssueKind.newerVersion,
          },
          preservedAs: issue.preservedAs,
          detail: issue.detail,
        ),
  ];

  /// The account's servers as the last enrollment or round left them in
  /// `servers.json`, in the catalog's order; none when not enrolled, when
  /// another process may use the files, or when the file cannot be read.
  Future<List<ServerConfig>> servers() async {
    if (_account == null || _access != SupportDirectoryAccess.exclusive) {
      return const [];
    }
    try {
      return await _servers.load();
    } on Object {
      return const [];
    }
  }

  /// Whether the enrollment file asserts [release] for pin publication
  /// (D15); false while [release] is null or the file is unavailable. The
  /// enrollment sheet sets it before the account exists.
  bool pinPublicationAsserted(String? release) =>
      release != null && _enrollment?.pinPublicationAssertion == release;

  /// Asserts [release] for pin publication, or withdraws the assertion
  /// with null; pins already published stay. Throws when the enrollment
  /// file cannot be written.
  Future<void> setPinPublication(String? release) async =>
      _enrollment?.setPinPublicationAssertion(release);

  /// Publishes [pin], one the user confirmed, when the enrollment asserts
  /// [release] (D15, FL-22) and a synced server that is not excluded
  /// connects to its address, directly or as a hop of its route: a pin
  /// only excluded servers use stays on this device (divergence 1), as
  /// does one for an address no synced server names. Returns whether it
  /// was published. Never throws.
  Future<bool> publishPin(HostKey pin, {required String? release}) async {
    if (!pinPublicationAsserted(release)) return false;
    if (!_shared(pin, await servers())) return false;
    final written = await _write(
      'pin',
      (writes) async =>
          await writes.coordinator.writer.publishPin(pin) ==
              WriteOutcome.written
          ? const CatalogWritten(requestId: 'pin')
          : _refused('pin', CatalogWriteFailure.other),
    );
    return written is CatalogWritten;
  }

  /// Whether a server in [servers] that is not excluded reaches [pin]'s
  /// address, itself or through its jump hosts.
  static bool _shared(HostKey pin, List<ServerConfig> servers) {
    final byId = {for (final server in servers) server.id: server};
    bool at(ServerConfig server) =>
        hostKeyLocator(server.host, server.port) == pin.locator;
    for (final server in servers) {
      if (server.excludeFromSync) continue;
      final seen = <String>{};
      for (
        ServerConfig? hop = server;
        hop != null && seen.add(hop.id);
        hop = byId[hop.jumpHostId]
      ) {
        if (at(hop)) return true;
      }
    }
    return false;
  }

  /// The synced preferences of every server [servers] lists that is not
  /// excluded from sync, by server id (03 §4.8). A `pref` record whose
  /// server is absent stays stored, pending, and shows once the server
  /// arrives.
  Future<Map<String, ServerPrefs>> serverPrefs() async {
    // The servers first: a round applied while they load is then in prefs.
    final synced = await servers();
    final prefs = _klabautermannRecords.prefs();
    return {
      for (final server in synced)
        if (!server.excludeFromSync)
          if (prefs[server.id] case final serverPrefs?) server.id: serverPrefs,
    };
  }

  /// Every live `rule` record's alert rule (03 §4.8, ALR-01), whatever
  /// its scope names.
  Future<List<SyncedRule>> rules() async => _klabautermannRecords.rules();

  /// Signs in to the account [request] names (03 §4.3 step 1), re-keys the
  /// vault through its journal, and applies the pulled records.
  Future<SyncStatus> enroll(EnrollSync request) async {
    const operation = SyncOperation.enroll;
    if (_refusal(operation) case final refused?) return refused;
    final enrollment = _enrollment!;

    final baseUrl = request.baseUrl.trim();
    final username = request.username.trim();
    final issue = validateSyncEnrollment(
      mode: SyncEnrollmentMode.login,
      baseUrl: baseUrl,
      username: username,
      password: request.password,
      encryptionPassphrase: request.encryptionPassphrase,
    );
    if (issue != null) {
      return _failed(operation, SyncFailure.invalidRequest, issue.name);
    }
    final current = _account;
    if (current != null &&
        (current.baseUrl != baseUrl || current.username != username)) {
      return _failed(operation, SyncFailure.otherAccount, null);
    }

    final SyncTransport api;
    try {
      api = _transport(baseUrl);
    } on Object catch (error) {
      return _failedWith(operation, error);
    }
    try {
      // No save runs between the look for a vault and the key's install.
      final result = await _vault.exclusive(() async {
        final credentials = KeystoreSyncCredentialStore(
          keystore: _keystore,
          // Nothing to re-seal without a vault file (K49a's contract): a
          // first enrollment then installs the account key directly, where
          // staging would need a master key no install has yet.
          vaultJournal: await _vault.exists() ? _vault.store : null,
        );
        return SyncEnrollment(
          credentials: credentials,
          state: enrollment,
          records: _records,
          handlers: [_handler],
        ).login(
          api: api,
          baseUrl: baseUrl,
          username: username,
          password: request.password,
          encryptionPassphrase: request.encryptionPassphrase,
          mode: SyncAccountMode.shared,
        );
      });
      _account = SyncAccountInfo(baseUrl: baseUrl, username: username);
      await _vault.exclusive(() => _coordinator(result.vaultKey).applyPulled());
      return _status(
        operation,
        SyncPhase.succeeded,
        unverified: result.passphraseUnverified,
        budget: prefixBudgetOf(await _records.allRecords()),
      );
    } on Object catch (error) {
      // The store applies a change in memory before it saves, so a login
      // that got as far as the account shows it, as a restart would.
      _account = _info(await enrollment.account());
      return _failedWith(operation, error);
    } finally {
      api.close();
    }
  }

  /// One round on the enrolled account: a pull, then a push of what this
  /// device sealed.
  Future<SyncStatus> runRound() async {
    const operation = SyncOperation.round;
    if (_refusal(operation) case final refused?) return refused;
    final account = _account;
    if (account == null) {
      return _failed(operation, SyncFailure.notEnrolled, null);
    }

    final SyncTransport api;
    final RecordCoordinator coordinator;
    try {
      final token = await KeystoreSyncCredentialStore(
        keystore: _keystore,
      ).readToken();
      final key = await _keystore.readMasterKey();
      if (token == null || key == null) {
        return _failed(
          operation,
          SyncFailure.keystoreUnavailable,
          token == null ? 'no session token' : 'no vault key',
        );
      }
      api = _transport(account.baseUrl, token: token);
      coordinator = _coordinator(key);
    } on Object catch (error) {
      return _failedWith(operation, error);
    }

    try {
      // The coordinator writes pulled secrets through the vault's store,
      // so the round holds the vault as a save does: a save's read and
      // write would otherwise interleave with a pulled secret's and drop
      // one. A save asked for meanwhile waits for the round.
      final result = await _vault.exclusive(() => coordinator.runRound(api));
      if (result.authFailed) {
        return _failed(operation, SyncFailure.sessionRejected, null);
      }
      return _status(
        operation,
        SyncPhase.succeeded,
        unverified: await _enrollment!.passphraseUnverified(),
        budget: prefixBudgetOf(await _records.allRecords()),
      );
    } on Object catch (error) {
      return _failedWith(operation, error);
    } finally {
      api.close();
    }
  }

  /// The synced server [serverId] as the server editor shows it, or null
  /// when the catalog lists none by that id or cannot be read.
  Future<ServerDraft?> serverDraft(String serverId) async {
    for (final server in await servers()) {
      if (server.id == serverId) return serverDraftOf(server);
    }
    return null;
  }

  /// The synced server [serverId] as the catalog stores it, or null when
  /// it holds none or cannot be read.
  Future<ServerConfig?> storedServer(String serverId) async {
    try {
      return await _servers.byId(serverId);
    } on Object {
      return null;
    }
  }

  /// Saves [request]'s draft (03 §4.4, FL-03). The credential goes first,
  /// so the stored config never names an entry the vault lacks; then the
  /// config, sealed with its `serverConfig` record and, while the server
  /// opts in, its credential's. A server newly excluded from sync takes
  /// its synced preferences back with it (03 §4.8).
  Future<EngineEvent> saveServer(SaveServer request) async {
    final requestId = request.requestId;
    final draft = request.draft;
    if (serverDraftProblem(draft) case final problem?) {
      return _refused(requestId, problem);
    }
    return _write(requestId, (writes) async {
      final existing = await _servers.byId(draft.id);
      // The stored entry's id, or a new one for a server that has none.
      final secretId = existing?.secretRef ?? uuidV4();
      final secret = await _plannedSecret(
        draft,
        request.credential,
        secretId,
        writes.vault,
      );
      if (secret != null) {
        await writes.vault.putLocalSecret(
          secret,
          updatedAt: writes.coordinator.writer.now().millisecondsSinceEpoch,
        );
      }

      final config = serverConfigOfDraft(
        draft,
        existing: existing,
        secretRef: secret != null ? secretId : existing?.secretRef,
        now: writes.coordinator.writer.now(),
      );
      final writer = writes.coordinator.writer;
      if (await writer.saveServer(config) == WriteOutcome.refusedPullOnly) {
        return _refused(requestId, CatalogWriteFailure.other, 'pull-only');
      }
      if (secret != null) await writer.secretSaved(secretId);
      if (config.excludeFromSync && existing?.excludeFromSync != true) {
        await _retractPrefs(writes, config.id);
      }
      return CatalogWritten(
        requestId: requestId,
        serverId: config.id,
        credentialWritten: secret != null,
      );
    });
  }

  /// The vault entry [entry]'s boxes plan for [draft] under [secretId],
  /// or null when they plan none (`plannedCredential`): reading the stored
  /// entry only where the plan carries part of it over.
  Future<Secret?> _plannedSecret(
    ServerDraft draft,
    ServerCredentialEntry? entry,
    String secretId,
    SecretVault vault,
  ) async {
    if (entry == null) return null;
    final auth = authMethodOf(draft.auth);
    final readsStored = plannedCredentialReadsStored(
      auth: auth,
      referenceKeyFile: entry.referenceKeyFile,
      keyPassphrase: entry.keyPassphrase,
    );
    return plannedCredential(
      auth: auth,
      referenceKeyFile: entry.referenceKeyFile,
      password: entry.password,
      keyPem: entry.keyPem,
      keyPassphrase: entry.keyPassphrase,
      secretId: secretId,
      stored: readsStored ? await vault.getSecret(secretId) : null,
    );
  }

  /// Duplicates the synced server [request] names (FL-03, M5 plan M09b):
  /// the credential is copied into a vault entry of the copy's own first,
  /// so the stored config never names an entry the vault lacks, then the
  /// copy is sealed as a new server. A source entry this device lacks
  /// copies as no credential, as Séance's duplicate does.
  Future<EngineEvent> duplicateServer(DuplicateServer request) =>
      _write(request.requestId, (writes) async {
        final source = await _servers.byId(request.serverId);
        if (source == null) {
          return _refused(request.requestId, CatalogWriteFailure.unknownTarget);
        }
        final writer = writes.coordinator.writer;
        final now = writer.now().millisecondsSinceEpoch;
        final sourceRef = source.secretRef;
        final stored = sourceRef == null
            ? null
            : await writes.vault.getSecret(sourceRef);
        final secret = stored?.copyWith(id: uuidV4());
        if (secret != null) {
          await writes.vault.putLocalSecret(secret, updatedAt: now);
        }

        final config = duplicateServerConfig(
          source,
          id: uuidV4(),
          label: duplicateServerLabel(source.label, [
            for (final server in await servers()) server.label,
          ]),
          secretRef: secret?.id,
          now: now,
        );
        if (await writer.saveServer(config) == WriteOutcome.refusedPullOnly) {
          return _refused(
            request.requestId,
            CatalogWriteFailure.other,
            'pull-only',
          );
        }
        if (secret != null) await writer.secretSaved(secret.id);
        return CatalogWritten(
          requestId: request.requestId,
          serverId: config.id,
          credentialWritten: secret != null,
        );
      });

  /// Deletes the synced server [request] names: its tombstone persists
  /// before its row drops, its credential's record is retracted unless
  /// another server shares it, and its synced preferences go (03 §4.4).
  Future<EngineEvent> deleteServer(DeleteServer request) =>
      _write(request.requestId, (writes) async {
        final existing = await _servers.byId(request.serverId);
        if (existing == null) {
          return _refused(request.requestId, CatalogWriteFailure.unknownTarget);
        }
        await writes.coordinator.writer.deleteServer(existing);
        await _retractPrefs(writes, existing.id);
        return CatalogWritten(
          requestId: request.requestId,
          serverId: existing.id,
        );
      });

  /// Seals the synced server's `pref` record [request] carries, or its
  /// removal (03 §4.8). An excluded server's preferences stay local.
  Future<EngineEvent> setServerPrefs(SetServerPrefs request) =>
      _write(request.requestId, (writes) async {
        final serverId = request.serverId;
        final server = await _servers.byId(serverId);
        if (server == null || server.excludeFromSync) {
          return _refused(request.requestId, CatalogWriteFailure.unknownTarget);
        }
        final recordId = KlabautermannRecordType.pref.idOf(serverId);
        final prefs = request.prefs;
        final payload = prefs == null
            ? removedPayload(recordId)
            : encodeServerPrefs(serverId, prefs);
        if (prefs != null && !_decodes(() => decodeServerPrefs(payload))) {
          return _refused(request.requestId, CatalogWriteFailure.invalidDraft);
        }
        if (await _sealKlabautermann(writes, recordId, payload)
            case final failure?) {
          return _refused(request.requestId, failure);
        }
        return CatalogWritten(requestId: request.requestId, serverId: serverId);
      });

  /// Seals the alert rule [request] carries as its `rule` record (03
  /// §4.8).
  Future<EngineEvent> putRule(PutRule request) =>
      _write(request.requestId, (writes) async {
        final ruleId = request.ruleId.trim();
        final target = request.target?.trim();
        if (ruleId.isEmpty || (target != null && target.isEmpty)) {
          return _refused(request.requestId, CatalogWriteFailure.invalidDraft);
        }
        final type = KlabautermannRecordType.rule;
        final recordId = type.idOf(ruleId);
        if (!_klabautermannRecords.isLive(recordId) &&
            _klabautermannRecords.liveCount(type) >= type.countCap!) {
          return _refused(request.requestId, CatalogWriteFailure.tooMany);
        }
        final payload = encodeSyncedRule(
          SyncedRule(id: ruleId, rule: request.rule, target: target),
        );
        if (await _sealKlabautermann(writes, recordId, payload)
            case final failure?) {
          return _refused(request.requestId, failure);
        }
        return CatalogWritten(requestId: request.requestId);
      });

  /// Seals the removal of the alert rule [request] names (03 §4.8).
  Future<EngineEvent> removeRule(RemoveRule request) =>
      _write(request.requestId, (writes) async {
        final recordId = KlabautermannRecordType.rule.idOf(request.ruleId);
        if (!_klabautermannRecords.isLive(recordId)) {
          return _refused(request.requestId, CatalogWriteFailure.unknownTarget);
        }
        await _sealKlabautermann(writes, recordId, removedPayload(recordId));
        return CatalogWritten(requestId: request.requestId);
      });

  /// Runs a catalog write: refused before [body] without exclusive access,
  /// an enrolled account or the account key, and with the vault held, as
  /// a round holds it, so a pulled secret and a written one never
  /// interleave on the vault file. Never throws.
  Future<EngineEvent> _write(
    String requestId,
    Future<EngineEvent> Function(_Writes writes) body,
  ) async {
    if (_refusal(SyncOperation.round) != null) {
      return _refused(requestId, CatalogWriteFailure.directoryShared);
    }
    if (_account == null) {
      return _refused(requestId, CatalogWriteFailure.notEnrolled);
    }
    try {
      final key = await _keystore.readMasterKey();
      if (key == null) {
        return _refused(requestId, CatalogWriteFailure.keystoreUnavailable);
      }
      return await _vault.exclusive(
        () => body(
          _Writes(
            _coordinator(key),
            SecretVault(_vault.store, key),
            RecordCrypto(RecordCodec(key)),
          ),
        ),
      );
    } on Object catch (error) {
      return _refused(requestId, switch (error) {
        SyncKeystoreRefusedException() =>
          CatalogWriteFailure.keystoreUnavailable,
        SyncStateReadOnlyException() => CatalogWriteFailure.storeUnavailable,
        _ => CatalogWriteFailure.other,
      }, '$error');
    }
  }

  /// Seals [payload] as the `klabautermann:` record [recordId], stamped
  /// past the version this device holds, and keeps it in the record store
  /// so the engine reads it before the push returns. Returns why it was
  /// refused, or null.
  Future<CatalogWriteFailure?> _sealKlabautermann(
    _Writes writes,
    String recordId,
    Map<String, Object?> payload,
  ) async {
    final writer = writes.coordinator.writer;
    final record = DecryptedRecord(
      id: recordId,
      kind: RecordKind.klabautermann,
      updatedAt: nextUpdatedAt(
        _klabautermannRecords.tupleOf(recordId)?.updatedAt,
        now: writer.now().millisecondsSinceEpoch,
      ),
      deviceId: writer.deviceId,
      data: payload,
    );
    final type = KlabautermannRecordType.named(
      parseKlabautermannId(recordId)!.type,
    )!;
    // Every device refuses a blob past its type's cap (03 §4.8), so one
    // is never sealed.
    if ((await writes.crypto.seal(record)).blob.length > type.blobCap) {
      return CatalogWriteFailure.tooLarge;
    }
    if (await writer.sealLocal(record) == WriteOutcome.refusedPullOnly) {
      return CatalogWriteFailure.other;
    }
    await _klabautermannRecords.put(
      recordId,
      SyncTuple(updatedAt: record.updatedAt, deviceId: record.deviceId),
      payload,
    );
    return null;
  }

  /// Seals the removal of [serverId]'s `pref` record when the store holds
  /// a live one.
  Future<void> _retractPrefs(_Writes writes, String serverId) async {
    final recordId = KlabautermannRecordType.pref.idOf(serverId);
    if (!_klabautermannRecords.isLive(recordId)) return;
    await _sealKlabautermann(writes, recordId, removedPayload(recordId));
  }

  static bool _decodes(void Function() decode) {
    try {
      decode();
      return true;
    } on FormatException {
      return false;
    }
  }

  CatalogWriteRefused _refused(
    String requestId,
    CatalogWriteFailure failure, [
    String? detail,
  ]) => CatalogWriteRefused(
    requestId: requestId,
    failure: failure,
    detail: detail,
  );

  /// The failure that stops [operation] before it starts, or null.
  SyncStatus? _refusal(SyncOperation operation) {
    if (_access != SupportDirectoryAccess.exclusive) {
      return _failed(operation, SyncFailure.directoryShared, null);
    }
    if (_enrollment == null) {
      return _failed(operation, SyncFailure.noDeviceId, null);
    }
    return null;
  }

  /// A shared-mode coordinator over the account key [key]
  /// (03 §4.2, §4.4): it materializes pulled `serverConfig` records into
  /// `servers.json`, quarantines pulled pins against the engine's host-key
  /// store, materializes `klabautermann:` records (4.8), and applies
  /// pulled `secret:` records into the vault only while [syncSecrets] is
  /// on (03 §4.5); the vault's key is the account key.
  RecordCoordinator _coordinator(List<int> key) => RecordCoordinator(
    records: _records,
    handlers: [_handler],
    hostKeys: _hostKeys,
    hostKeyMutations: _hostKeyMutations,
    crypto: RecordCrypto(RecordCodec(key)),
    deviceId: _deviceId!,
    pinVerdicts: _pinVerdicts,
    tripwires: _tripwires,
    catalogMode: CatalogMode.shared,
    pushPolicy: engineSyncPushPolicy,
    servers: _servers,
    enrollment: _enrollment,
    secrets: _syncSecrets ? SecretVault(_vault.store, key) : null,
    syncSecrets: _syncSecrets,
  );

  SyncStatus _status(
    SyncOperation operation,
    SyncPhase phase, {
    bool unverified = false,
    SyncFailure? failure,
    String? detail,
    SyncPrefixBudget? budget,
  }) => SyncStatus(
    phase,
    operation: operation,
    account: _account,
    failure: failure,
    passphraseUnverified: unverified,
    detail: detail,
    prefixBudget: budget,
  );

  SyncStatus _failed(
    SyncOperation operation,
    SyncFailure failure,
    String? detail,
  ) => _status(operation, SyncPhase.failed, failure: failure, detail: detail);

  SyncStatus _failedWith(SyncOperation operation, Object error) =>
      _failed(operation, _classify(error), '$error');

  static SyncFailure _classify(Object error) => switch (error) {
    KdfDowngradeException() => SyncFailure.kdfDowngrade,
    ApiError(code: 'invalid_credentials') => SyncFailure.credentialsRejected,
    ApiError(code: 'unauthorized') => SyncFailure.sessionRejected,
    ApiError() => SyncFailure.serverError,
    IOException() || TimeoutException() => SyncFailure.unreachable,
    SyncKeystoreRefusedException() ||
    SyncVaultKeyUnavailableException() => SyncFailure.keystoreUnavailable,
    SyncStateReadOnlyException() => SyncFailure.storeUnavailable,
    _ => SyncFailure.other,
  };
}

/// What a catalog write works through: a coordinator under the account
/// key, the vault the key opens, and the key's record crypto.
final class _Writes {
  const _Writes(this.coordinator, this.vault, this.crypto);

  final RecordCoordinator coordinator;
  final SecretVault vault;
  final RecordCrypto crypto;
}
