import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/src/catalog/engine_sync.dart';
import 'package:klabautermann_core/src/catalog/keystore_channel.dart';
import 'package:klabautermann_core/src/catalog/sync_credentials.dart';
import 'package:seance_core/catalog.dart' show RecordCrypto;
import 'package:seance_core/seance_core.dart';

/// The account's name and password in every fake server.
const fakeSyncUser = 'ops';
const fakeSyncPassword = 'correct horse';

/// A Séance sync server in memory for one account: prelogin hands out the
/// KDF salt, login checks the verifier and mints a token, pulls serve the
/// held records in seq order, and a push merges each record under the
/// same LWW the server runs, minting a seq for each it takes.
final class FakeSyncServer {
  FakeSyncServer._(this.salt, this.keys);

  /// An account whose password is also its encryption passphrase.
  static Future<FakeSyncServer> create() async {
    final salt = List<int>.generate(16, (i) => i);
    final keys = await VaultCrypto.deriveKeys(
      passphrase: fakeSyncPassword,
      salt: salt,
      params: const Argon2Params(),
    );
    return FakeSyncServer._(salt, keys);
  }

  final List<int> salt;

  /// The account's derived keys; [VaultKeys.vaultKey] seals its records.
  final VaultKeys keys;

  final Map<String, EncryptedRecord> _records = {};
  var _seq = 0;

  /// Prelogin answers these instead of the account's own: the downgrade
  /// fixture.
  Argon2Params? preloginParams;

  /// Thrown by the next pull, once.
  Object? nextPullError;

  /// Holds every pull until it completes; [pullHeld] completes as one
  /// waits, so a test can act in the middle of a round. Both stay null
  /// unless a test sets them: completers cannot cross to an isolate.
  Completer<void>? pullGate;
  Completer<void>? pullHeld;

  /// Thrown by every call, as a server nobody can reach.
  Object? unreachable;

  /// Push requests, and every record they carried, in order.
  var pushes = 0;
  final pushed = <EncryptedRecord>[];

  /// The held record [id], or null.
  EncryptedRecord? record(String id) => _records[id];
  var transports = 0;

  /// Forgets the seeded records, so each test starts from an empty account.
  void clearRecords() {
    _records.clear();
    pushed.clear();
    _seq = 0;
  }

  /// Seals [server] as a `serverConfig` record under the account key and
  /// seeds it.
  Future<void> seedServer(ServerConfig server, {int updatedAt = 1}) async {
    final sealed = await RecordCrypto(RecordCodec(keys.vaultKey)).seal(
      DecryptedRecord(
        id: server.id,
        kind: RecordKind.serverConfig,
        updatedAt: updatedAt,
        deviceId: 'seance-device',
        data: server.toJson(),
      ),
    );
    _records[server.id] = sealed.withSeq(++_seq);
  }

  /// Seals [data] as a `klabautermann:` record under [id] and seeds it.
  Future<void> seedKlabautermann(
    String id,
    Map<String, Object?> data, {
    int updatedAt = 1,
  }) async {
    final sealed = await RecordCrypto(RecordCodec(keys.vaultKey)).seal(
      DecryptedRecord(
        id: id,
        kind: RecordKind.klabautermann,
        updatedAt: updatedAt,
        deviceId: 'klabautermann-device',
        data: data,
      ),
    );
    _records[id] = sealed.withSeq(++_seq);
  }

  /// Seals [secret] as its `secret:` record under the account key and
  /// seeds it, stamped [updatedAt].
  Future<void> seedSecret(Secret secret, {int updatedAt = 1}) async {
    final id = 'secret:${secret.id}';
    final sealed = await RecordCrypto(RecordCodec(keys.vaultKey)).seal(
      DecryptedRecord(
        id: id,
        kind: RecordKind.secret,
        updatedAt: updatedAt,
        deviceId: 'seance-device',
        data: secret.toJson(),
      ),
    );
    _records[id] = sealed.withSeq(++_seq);
  }

  /// The [SyncTransportFactory] over this server.
  SyncTransport transport(String baseUrl, {String? token}) {
    transports++;
    return _FakeTransport(this, token);
  }
}

/// A server config with the fields the fleet shows.
ServerConfig fakeServer(String id, String label, {String? jumpHostId}) =>
    ServerConfig(
      id: id,
      label: label,
      host: '$label.example.com',
      username: 'deploy',
      jumpHostId: jumpHostId,
      createdAt: 1,
      updatedAt: 1,
    );

final class _FakeTransport implements SyncTransport {
  _FakeTransport(this._server, this.token);

  final FakeSyncServer _server;

  @override
  String? token;

  void _reach() {
    if (_server.unreachable case final error?) throw error;
  }

  @override
  Future<void> register(RegisterRequest request) =>
      throw UnsupportedError('Klabautermann never registers');

  @override
  Future<PreloginResponse> prelogin(String username) async {
    _reach();
    return PreloginResponse(
      argonSalt: base64.encode(_server.salt),
      argonParams: _server.preloginParams ?? const Argon2Params(),
    );
  }

  @override
  Future<void> login(LoginRequest request) async {
    _reach();
    if (request.username != fakeSyncUser ||
        request.authVerifier != base64.encode(_server.keys.authVerifier)) {
      throw const ApiError(
        code: 'invalid_credentials',
        message: 'Invalid credentials',
      );
    }
    token = 'token-1';
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    _reach();
    if (_server.nextPullError case final error?) {
      _server.nextPullError = null;
      throw error;
    }
    if (_server.pullGate case final gate?) {
      if (_server.pullHeld case final held? when !held.isCompleted) {
        held.complete();
      }
      await gate.future;
    }
    if (token != 'token-1') {
      throw const ApiError(code: 'unauthorized', message: 'Invalid token');
    }
    final records =
        _server._records.values.where((r) => (r.seq ?? 0) > since).toList()
          ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(records: records, latestSeq: _server._seq);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    _reach();
    if (token != 'token-1') {
      throw const ApiError(code: 'unauthorized', message: 'Invalid token');
    }
    _server.pushes++;
    _server.pushed.addAll(records);
    final results = <PushResult>[];
    for (final incoming in records) {
      final held = _server._records[incoming.id];
      if (held != null && !identical(Lww.resolve(held, incoming), incoming)) {
        results.add(
          PushResult(id: incoming.id, seq: held.seq ?? 0, accepted: false),
        );
        continue;
      }
      final seq = ++_server._seq;
      _server._records[incoming.id] = incoming.withSeq(seq);
      results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
    }
    return PushResponse(results: results, latestSeq: _server._seq);
  }

  @override
  void close() {}
}

/// A [SyncKeystore] in memory, as the app's binding would answer it.
final class MemoryKeystore implements SyncKeystore {
  final Map<String, String> apiKeys = {};
  List<int>? masterKey;

  /// Makes every write throw, as the engine's port does for a locked
  /// keyring.
  bool refuseWrites = false;

  /// Hears each master key written.
  void Function(List<int> key)? onWrite;

  @override
  Future<void> putApiKey(String name, String value) async {
    if (refuseWrites) throw const SyncKeystoreRefusedException('locked');
    apiKeys[name] = value;
  }

  @override
  Future<String?> getApiKey(String name) async => apiKeys[name];

  @override
  Future<void> deleteApiKey(String name) async => apiKeys.remove(name);

  @override
  Future<List<int>?> readMasterKey() async => masterKey;

  @override
  Future<void> writeMasterKey(List<int> key) async {
    if (refuseWrites) throw const SyncKeystoreRefusedException('locked');
    masterKey = List.of(key);
    onWrite?.call(masterKey!);
  }
}
