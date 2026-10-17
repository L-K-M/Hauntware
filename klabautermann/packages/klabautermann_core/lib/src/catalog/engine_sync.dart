/// Pull-only sync in the engine (03 §4.3, §4.4, D14, D63): enrollment into
/// the user's Séance account and sync rounds through the catalog library's
/// `SyncEnrollment` and `RecordCoordinator`, over the engine's own files
/// in the support directory (03 §4.10).
library;

import 'dart:async';
import 'dart:io';

import 'package:seance_core/catalog.dart'
    show
        CatalogMode,
        ConflictAwareHostKeyStore,
        FileServerConfigStore,
        FileVaultStore,
        HostKeyMutationGate,
        KdfDowngradeException,
        PersistentLocalRecordStore,
        PushPolicy,
        RecordCoordinator,
        RecordCrypto,
        SyncAccount,
        SyncAccountMode,
        SyncEnrollment,
        SyncEnrollmentApi;
import 'package:seance_core/seance_core.dart'
    show
        ApiError,
        HttpSyncClient,
        RecordCodec,
        ServerConfig,
        SyncEnrollmentMode,
        validateSyncEnrollment;

import '../engine/protocol.dart';
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'keystore_channel.dart';
import 'sync_credentials.dart';
import 'sync_enrollment_file.dart';
import 'sync_state_file.dart';
import 'sync_verdict_files.dart';

/// The push policy every coordinator the engine builds runs under (D14):
/// pull-only, so no record is sealed, written to the catalog or pushed.
/// The app's pull-only test permits sync requests only while this holds.
const PushPolicy engineSyncPushPolicy = PushPolicy.none;

/// The catalog library's files under the support directory (03 §4.10).
/// `host_keys.json` is not among them: the engine opens its one host-key
/// store with `openHostKeyPins` and hands it in (D61, D63).
const String _syncRecordsFileName = 'sync_records.json';
const String _serversFileName = 'servers.json';
const String _vaultFileName = 'vault.json';

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
    required this._transport,
    required this._path,
    required this._account,
  }) : _records = PersistentLocalRecordStore(path: _path(_syncRecordsFileName)),
       _servers = FileServerConfigStore(
         path: _path(_serversFileName),
         syncDeviceId: () => _deviceId,
       ),
       _vault = FileVaultStore(File(_path(_vaultFileName)));

  /// Opens the sync state files in [supportDirectory] (none of the catalog
  /// library's files is read before an operation needs it). [deviceId] is
  /// `settings.json`'s; without one, enrollment state is not opened and
  /// every operation is refused. [hostKeys] is the engine's one host-key
  /// store, which its links share, and [keystore] the app's
  /// keystore. Never throws.
  static Future<EngineSync> open({
    required Directory supportDirectory,
    required SupportDirectoryAccess access,
    required String? deviceId,
    required ConflictAwareHostKeyStore hostKeys,
    required SyncKeystore keystore,
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
      transport: transport,
      path: (name) => '${supportDirectory.path}${Platform.pathSeparator}$name',
      account: _info(account),
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
  final String Function(String name) _path;
  final PersistentLocalRecordStore _records;
  final FileServerConfigStore _servers;
  final FileVaultStore _vault;
  final HostKeyMutationGate _hostKeyMutations = HostKeyMutationGate();
  SyncAccountInfo? _account;

  /// The enrolled account, or null.
  SyncAccountInfo? get account => _account;

  /// What was wrong with each sync state file at open.
  List<SyncStoreIssue> get issues => [
    for (final (name, issue) in [
      (syncEnrollmentFileName, _enrollment?.issue),
      (pinVerdictsFileName, _pinVerdicts.issue),
      (syncTripwiresFileName, _tripwires.issue),
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

    final api = _transport(baseUrl);
    try {
      final credentials = KeystoreSyncCredentialStore(
        keystore: _keystore,
        // Nothing to re-seal without a vault file (K49a's contract): a
        // first enrollment then installs the account key directly, where
        // staging would need a master key no install has yet.
        vaultJournal: await _vaultExists() ? _vault : null,
      );
      final result =
          await SyncEnrollment(
            credentials: credentials,
            state: enrollment,
            records: _records,
            handlers: const [],
          ).login(
            api: api,
            baseUrl: baseUrl,
            username: username,
            password: request.password,
            encryptionPassphrase: request.encryptionPassphrase,
            mode: SyncAccountMode.shared,
          );
      _account = SyncAccountInfo(baseUrl: baseUrl, username: username);
      await _coordinator(result.vaultKey).applyPulled();
      return _status(
        operation,
        SyncPhase.succeeded,
        unverified: result.passphraseUnverified,
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

  /// One pull-only round on the enrolled account.
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
      final result = await coordinator.runRound(api);
      if (result.authFailed) {
        return _failed(operation, SyncFailure.sessionRejected, null);
      }
      return _status(
        operation,
        SyncPhase.succeeded,
        unverified: await _enrollment!.passphraseUnverified(),
      );
    } on Object catch (error) {
      return _failedWith(operation, error);
    } finally {
      api.close();
    }
  }

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

  /// A pull-only, shared-mode coordinator over the account key [key]
  /// (03 §4.2, §4.4): it materializes pulled `serverConfig` records into
  /// `servers.json`, quarantines pulled pins against the engine's host-key
  /// store, and applies no `secret:` record, since no vault and no
  /// `syncSecrets` switch is wired yet (03 §4.5).
  RecordCoordinator _coordinator(List<int> key) => RecordCoordinator(
    records: _records,
    handlers: const [],
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
  );

  Future<bool> _vaultExists() async =>
      await File(_path(_vaultFileName)).exists() ||
      await File('${_path(_vaultFileName)}.rekey').exists();

  SyncStatus _status(
    SyncOperation operation,
    SyncPhase phase, {
    bool unverified = false,
    SyncFailure? failure,
    String? detail,
  }) => SyncStatus(
    phase,
    operation: operation,
    account: _account,
    failure: failure,
    passphraseUnverified: unverified,
    detail: detail,
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
