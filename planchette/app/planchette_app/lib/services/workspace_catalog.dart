import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ghost_keystore/ghost_keystore.dart';
import 'package:path/path.dart' as paths;
import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';

import 'json_file.dart';

enum WorkspaceCredentialSync { disabled, enabled }

abstract interface class WorkspaceCatalogTransport
    implements SyncEnrollmentApi {
  void close();
}

typedef WorkspaceCatalogTransportFactory =
    WorkspaceCatalogTransport Function(String baseUrl, {String? token});

final class _HttpCatalogTransport extends HttpSyncClient
    implements WorkspaceCatalogTransport {
  _HttpCatalogTransport(String baseUrl, {String? token})
    : super(baseUrl: baseUrl) {
    this.token = token;
  }
}

/// An optional, pull-only view of the suite's encrypted server catalog.
/// Keep one instance per directory; direct-file use never opens the keystore.
class WorkspaceCatalog extends ChangeNotifier {
  WorkspaceCatalog({
    required Directory directory,
    MasterKeyManager? masterKeys,
    WorkspaceCatalogTransportFactory? transportFactory,
  }) : _directory = directory,
       // Keep the injectable collaborator private.
       // ignore: prefer_initializing_formals
       _masterKeys = masterKeys,
       _transportFactory = transportFactory ?? _HttpCatalogTransport.new,
       _state = _CatalogState(File(paths.join(directory.path, 'state.json'))),
       _serverStore = FileServerConfigStore(
         path: paths.join(directory.path, 'servers.json'),
       ),
       _records = PersistentLocalRecordStore(
         path: paths.join(directory.path, 'sync_records.json'),
       ),
       _hostKeys = FileHostKeyStore(
         File(paths.join(directory.path, 'host_keys.json')),
       ),
       _vaultStore = FileVaultStore(
         File(paths.join(directory.path, 'vault.json')),
       );

  static const _tokenName = 'sync.token';
  static const _hostKeyNotice = 'hostKeySyncConflicts';
  static const _credentialNotice = 'credentialSyncFailed';
  static const _recoveryNotice = 'vaultRecoveryDiscarded';
  static const _vaultKeyLength = 32;

  final Directory _directory;
  MasterKeyManager? _masterKeys;
  final WorkspaceCatalogTransportFactory _transportFactory;
  final _CatalogState _state;
  final FileServerConfigStore _serverStore;
  final PersistentLocalRecordStore _records;
  final FileHostKeyStore _hostKeys;
  final FileVaultStore _vaultStore;
  final _hostKeyMutations = HostKeyMutationGate();
  Future<void> _tail = Future<void>.value();
  List<ServerConfig> _servers = const [];
  List<HostKeyConflict> _hostKeyConflicts = const [];
  _ReportingVault? _vault;
  bool _loaded = false;
  bool _disposed = false;
  int _operations = 0;
  String? _error;

  List<ServerConfig> get servers => _servers;
  SyncAccount? get account => _state.currentAccount;
  bool get busy => _operations != 0;
  String? get error => _error;
  WorkspaceCredentialSync get credentialSync => _state.credentialSync;
  ConflictAwareHostKeyStore get hostKeys => _hostKeys;
  List<HostKeyConflict> get hostKeyConflicts => _hostKeyConflicts;

  List<String> get notices => List.unmodifiable([
    for (final notice in _state.noticeSet)
      switch (notice) {
        syncNoticeAccountAuthFailed =>
          'Your catalog session was rejected. Sign in again.',
        syncNoticePassphraseCheckFailed => syncPassphraseCheckFailedMessage,
        _hostKeyNotice =>
          'Synced host keys conflict with local trust. Local keys remain trusted.',
        _credentialNotice =>
          'Saved credentials could not sync. Refresh to retry; local credentials were kept.',
        _recoveryNotice =>
          'A vault recovery journal did not match the installed key. Its backup was preserved.',
        _ => 'Catalog warning: $notice',
      },
    if (_state.tripped.isNotEmpty)
      'Some catalog records are invalid or use a newer schema. They were preserved.',
    if (account != null && _state.unverified)
      'The encryption passphrase has not yet been verified against an account record.',
  ]);

  ServerConfig? serverById(String id) {
    for (final server in _servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  /// Reads the cached catalog without contacting the server or OS keystore.
  Future<void> load() => _run(_load);

  Future<void> _load() async {
    if (_loaded) return;
    await _state.load();
    if (account != null) _servers = await _serverStore.load();
    _loaded = true;
  }

  Future<Secret?> secretById(String id) => _run(() async {
    await _load();
    if (account == null) return null;
    return (await _unlockVault()).getSecret(id);
  });

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required WorkspaceCredentialSync credentialSync,
  }) => _run(() async {
    await _load();
    final issue = validateSyncEnrollment(
      mode: SyncEnrollmentMode.login,
      baseUrl: baseUrl,
      username: username,
      password: password,
      encryptionPassphrase: encryptionPassphrase,
    );
    if (issue != null) {
      throw FormatException(switch (issue) {
        SyncEnrollmentIssue.invalidServerUrl =>
          'Enter an HTTP or HTTPS server URL.',
        SyncEnrollmentIssue.credentialsInUrl =>
          'Remove credentials from the server URL.',
        SyncEnrollmentIssue.missingUsername => 'Enter your account username.',
        SyncEnrollmentIssue.missingPassword => 'Enter your account password.',
        _ => 'Enter your encryption passphrase.',
      });
    }
    final normalizedUrl = _catalogUrl(baseUrl);
    final normalizedUser = username.trim();
    final current = account;
    if (current != null &&
        (current.baseUrl != normalizedUrl ||
            current.username != normalizedUser)) {
      throw StateError(
        'This workspace is enrolled with another account. Account switching is not supported.',
      );
    }

    await _directory.create(recursive: true);
    restrictDirectoryToOwner(_directory);
    await _unlockVault();
    final staging = await _directory.createTemp('enrollment-');
    WorkspaceCatalogTransport? api;
    try {
      api = _transportFactory(normalizedUrl);
      // Enrollment trials must not overwrite the live key, cursor or account.
      final draft = _CatalogState.draft(_state);
      final credentials = _EnrollmentCredentials();
      final records = PersistentLocalRecordStore(
        path: paths.join(staging.path, 'records.json'),
      );
      final result =
          await SyncEnrollment(
            credentials: credentials,
            state: draft,
            records: records,
            handlers: const [],
          ).login(
            api: api,
            baseUrl: normalizedUrl,
            username: normalizedUser,
            password: password,
            encryptionPassphrase: encryptionPassphrase,
            mode: SyncAccountMode.shared,
          );
      if (result.passphraseWarning != null) {
        await _state.setNotice(syncNoticePassphraseCheckFailed, true);
        throw StateError(result.passphraseWarning!);
      }
      final token = credentials.token;
      if (token == null || token.isEmpty) {
        throw StateError('The catalog server returned an empty session key.');
      }

      await _adoptVaultKey(result.vaultKey);
      await _keys.putApiKey(_tokenName, token);
      await _state.commitEnrollment(draft, credentialSync);
      await _records.resetSyncCursors();
      for (final record in await records.allRecords()) {
        await _records.putRemote(record);
      }
      await _records.setHighWaterSeq(await records.highWaterSeq());
      final coordinator = await _coordinator();
      await coordinator.applyPulled();
      await _finishApply(coordinator);
    } finally {
      api?.close();
      await staging.delete(recursive: true);
    }
  });

  Future<void> sync() => _run(() async {
    await _load();
    final current = account;
    if (current == null) throw StateError('Sign in to a catalog first.');
    final token = await _keys.getApiKey(_tokenName);
    if (token == null || token.isEmpty) {
      throw StateError(
        'The catalog session key is unavailable. Unlock your keystore or sign in again.',
      );
    }
    await _unlockVault();
    final coordinator = await _coordinator();
    final api = _transportFactory(current.baseUrl, token: token);
    try {
      final result = await coordinator.runRound(api);
      await _finishApply(coordinator);
      if (result.authFailed) {
        throw StateError('Your catalog session was rejected. Sign in again.');
      }
    } finally {
      api.close();
    }
  });

  MasterKeyManager get _keys => _masterKeys ??= MasterKeyManager(
    masterKeyEntry: 'planchette.vault.masterKey.v1',
    apiKeyPrefix: 'planchette.apikey.',
  );

  Future<_ReportingVault> _unlockVault() async {
    final hasVault =
        account != null ||
        await _vaultStore.file.exists() ||
        await File('${_vaultStore.file.path}.rekey').exists();
    final key = await _keys.probeKeystore(hasExistingVault: hasVault);
    if (key == null) {
      throw const KeystoreException(
        'Unlock your system keystore to read the catalog key.',
      );
    }
    if (key.length != _vaultKeyLength) {
      throw const FormatException('Invalid catalog vault key.');
    }
    final outcome = await _vaultStore.settleRekey(key);
    if (outcome == VaultRekeyOutcome.discarded) {
      await _state.setNotice(_recoveryNotice, true);
    }
    return _vault = _ReportingVault(_vaultStore, key);
  }

  Future<void> _adoptVaultKey(List<int> key) async {
    final vault = _vault!;
    if (listEquals(vault.vaultKey, key)) return;
    // Refuse to retire a key while any existing entry is unreadable.
    for (final blob in (await _vaultStore.allSecretBlobs()).values) {
      await VaultCrypto.openJson(vault.vaultKey, blob);
    }
    await _vaultStore.stageRekey(currentKey: vault.vaultKey, newKey: key);
    try {
      await _keys.setKeystoreKey(key);
    } catch (_) {
      // A keystore may write and then throw; only its read-back can settle.
      _vault = null;
      await _unlockVault();
      rethrow;
    }
    await _vaultStore.settleRekey(key);
    _vault = _ReportingVault(_vaultStore, key);
  }

  Future<RecordCoordinator> _coordinator() async => RecordCoordinator(
    records: _records,
    handlers: const [],
    hostKeys: _hostKeys,
    hostKeyMutations: _hostKeyMutations,
    crypto: RecordCrypto(RecordCodec(_vault!.vaultKey)),
    deviceId: await _state.deviceId(),
    pinVerdicts: _state,
    tripwires: _state,
    catalogMode: CatalogMode.shared,
    pushPolicy: PushPolicy.none,
    servers: _serverStore,
    secrets: _vault,
    syncSecrets: credentialSync == WorkspaceCredentialSync.enabled,
    enrollment: _state,
    onCatalogReplaced: (snapshot) => _servers = snapshot,
  );

  Future<void> _finishApply(RecordCoordinator coordinator) async {
    // Retry credentials skipped behind the apply cursor, including failed writes.
    await coordinator.catchUpSecrets();
    _hostKeyConflicts = List.unmodifiable(await coordinator.pinConflicts());
    await _state.setNotice(_hostKeyNotice, _hostKeyConflicts.isNotEmpty);
    final failed = _vault?.writeFailure;
    await _state.setNotice(_credentialNotice, failed != null);
    if (failed != null) {
      throw StateError('Saved credentials could not sync: $failed');
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    if (_disposed) return Future.error(StateError('Catalog is disposed.'));
    _operations++;
    notifyListeners();
    final result = _tail.then((_) async {
      _error = null;
      try {
        if (_disposed) throw StateError('Catalog is disposed.');
        return await operation();
      } catch (error) {
        _error = error.toString();
        rethrow;
      } finally {
        _operations--;
        if (!_disposed) notifyListeners();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String _catalogUrl(String input) {
  final uri = Uri.parse(input.trim());
  if (!const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Use an HTTP or HTTPS URL without credentials, query or fragment.',
    );
  }
  return uri.toString().replaceFirst(RegExp(r'/+$'), '');
}

final class _ReportingVault extends SecretVault {
  _ReportingVault(super.store, super.vaultKey);
  Object? writeFailure;

  @override
  Future<void> putSecret(Secret secret) async {
    try {
      await super.putSecret(secret);
    } catch (error) {
      writeFailure = error;
      rethrow;
    }
  }
}

final class _EnrollmentCredentials implements SyncCredentialStore {
  String? token;

  @override
  Future<void> writeToken(String token) async => this.token = token;
  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> deleteToken() async => token = null;
  @override
  Future<void> writeVaultKey(List<int> vaultKey) async {}
}

/// Account, consent and security notices fail closed together in one file.
/// Private callers already hold WorkspaceCatalog's operation queue.
final class _CatalogState
    implements SyncEnrollmentState, PinVerdictStore, SyncTripwireStore {
  _CatalogState(this._file);
  _CatalogState.draft(_CatalogState source)
    : _file = null,
      _loaded = true,
      _data = Map.of(source._data);

  static const _version = 1;
  final File? _file;
  bool _loaded = false;
  Map<String, dynamic> _data = {
    'version': _version,
    'account': null,
    'deviceId': null,
    'passphraseUnverified': true,
    'credentialSync': WorkspaceCredentialSync.disabled.name,
    'notices': <String>[],
    'tripwires': <String>[],
    'negativePins': <String>[],
    'keptPins': <String, String>{},
  };

  SyncAccount? get currentAccount {
    final raw = _data['account'] as Map?;
    if (raw == null) return null;
    return SyncAccount(
      baseUrl: raw['baseUrl'] as String,
      username: raw['username'] as String,
      mode: SyncAccountMode.shared,
    );
  }

  WorkspaceCredentialSync get credentialSync =>
      WorkspaceCredentialSync.values.byName(_data['credentialSync'] as String);
  bool get unverified => _data['passphraseUnverified'] as bool;
  Set<String> get noticeSet => Set<String>.from(_data['notices'] as List);
  Set<String> get tripped => Set<String>.from(_data['tripwires'] as List);

  Future<void> load() async {
    if (_loaded) return;
    final file = _file!;
    if (!await file.exists()) {
      _loaded = true;
      return;
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic> || raw['version'] is! int) {
      throw const FormatException(
        'Invalid workspace catalog state. Restore its backup.',
      );
    }
    if (raw['version'] != _version) {
      throw const FormatException(
        'Unsupported workspace catalog state version. Update Planchette or restore its backup.',
      );
    }
    final account = raw['account'];
    final deviceId = raw['deviceId'];
    if (!raw.containsKey('account') ||
        (deviceId != null && (deviceId is! String || deviceId.isEmpty)) ||
        raw['passphraseUnverified'] is! bool ||
        !WorkspaceCredentialSync.values.any(
          (value) => value.name == raw['credentialSync'],
        ) ||
        ['notices', 'tripwires', 'negativePins'].any(
          (key) =>
              raw[key] is! List ||
              (raw[key] as List).any((value) => value is! String),
        ) ||
        raw['keptPins'] is! Map ||
        (raw['keptPins'] as Map).values.any((value) => value is! String)) {
      throw const FormatException(
        'Invalid workspace catalog state. Restore its backup.',
      );
    }
    if (account != null) {
      if (account is! Map ||
          account['baseUrl'] is! String ||
          account['username'] is! String ||
          (account['username'] as String).trim().isEmpty ||
          account['mode'] != SyncAccountMode.shared.name ||
          deviceId == null ||
          _catalogUrl(account['baseUrl'] as String) != account['baseUrl']) {
        throw const FormatException(
          'Invalid catalog account. Restore its backup.',
        );
      }
    }
    _data = raw;
    _loaded = true;
  }

  Future<void> _save(Map<String, dynamic> changes) async {
    final next = {..._data, ...changes};
    final file = _file;
    if (file != null) await writeJsonFileAtomically(file, next);
    _data = next;
  }

  Future<void> commitEnrollment(
    _CatalogState draft,
    WorkspaceCredentialSync credentialSync,
  ) => _save({...draft._data, 'credentialSync': credentialSync.name});

  @override
  Future<String> deviceId() async {
    final existing = _data['deviceId'] as String?;
    if (existing != null) return existing;
    final minted = uuidV4();
    await _save({'deviceId': minted});
    return minted;
  }

  @override
  Future<SyncAccount?> account() async => currentAccount;
  @override
  Future<void> setAccount(SyncAccount? account) => _save({
    'account': account == null
        ? null
        : {
            'baseUrl': account.baseUrl,
            'username': account.username,
            'mode': account.mode.name,
          },
  });
  @override
  Future<bool> passphraseUnverified() async => unverified;
  @override
  Future<void> setPassphraseUnverified(bool value) =>
      _save({'passphraseUnverified': value});
  @override
  Future<Set<String>> notices() async => noticeSet;
  @override
  Future<void> setNotice(String notice, bool active) =>
      _setMembership('notices', notice, active);
  @override
  Future<Set<String>> trippedIds() async => tripped;
  @override
  Future<void> trip(String id) => _setMembership('tripwires', id, true);
  @override
  Future<void> clear(String id) => _setMembership('tripwires', id, false);
  @override
  Future<Set<String>> negativePins() async =>
      Set<String>.from(_data['negativePins'] as List);
  @override
  Future<void> addNegativePin(String locator) async {
    final kept = Map<String, String>.from(_data['keptPins'] as Map)
      ..remove(locator);
    await _save({
      'negativePins': {...await negativePins(), locator}.toList()..sort(),
      'keptPins': kept,
    });
  }

  @override
  Future<void> removeNegativePin(String locator) =>
      _setMembership('negativePins', locator, false);
  @override
  Future<String?> rejectedFingerprintFor(String locator) async =>
      (_data['keptPins'] as Map)[locator] as String?;
  @override
  Future<void> recordKeptVerdict(String locator, String rejectedFingerprint) =>
      _save({
        'keptPins': {..._data['keptPins'] as Map, locator: rejectedFingerprint},
      });

  Future<void> _setMembership(String key, String value, bool active) async {
    final next = Set<String>.from(_data[key] as List);
    if (active ? !next.add(value) : !next.remove(value)) return;
    await _save({key: next.toList()..sort()});
  }
}
