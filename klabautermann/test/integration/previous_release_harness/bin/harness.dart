// The previous release's Séance and Poltergeist as two devices on one
// sync account (M5 plan M08b, X2; 03 §4.8, §11.2 item 2).
//
// previous_release.sh builds this file against the seance_core,
// seance_protocol and poltergeist_core of the latest release tag, so it
// may use only what that release has. It signs in to an account the
// current Klabautermann already wrote to, runs a Séance round and a
// Poltergeist round, each pushing a record of its own, and prints what
// it pushed as JSON. sync_convergence_test.dart then checks from the
// server that neither re-pushed or removed Klabautermann's records.
//
// Usage: harness --server URL --username NAME --password SECRET
// (the password is also the encryption passphrase). Exit 0 on success,
// 1 with the error on stderr otherwise.
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:seance_core/seance_core.dart' as seance;

Future<void> main(List<String> arguments) async {
  final options = _options(arguments);
  final dir = await Directory.systemTemp.createTemp('klab-previous-');
  try {
    final seanceServer = await _seanceRound(options);
    final bookmark = await _poltergeistRound(options, dir);
    stdout.writeln(
      jsonEncode({'seanceServer': seanceServer, 'bookmark': bookmark}),
    );
  } on Object catch (error, stack) {
    stderr
      ..writeln('previous-release harness failed: $error')
      ..writeln(stack);
    exitCode = 1;
  } finally {
    await dir.delete(recursive: true);
  }
}

typedef _Options = ({String server, String username, String password});

_Options _options(List<String> arguments) {
  final values = <String, String>{};
  for (var i = 0; i + 1 < arguments.length; i += 2) {
    values[arguments[i]] = arguments[i + 1];
  }
  String required(String name) =>
      values['--$name'] ??
      (throw ArgumentError(
        'usage: harness --server URL --username NAME '
        '--password SECRET (missing --$name)',
      ));
  return (
    server: required('server'),
    username: required('username'),
    password: required('password'),
  );
}

/// Signs in as Séance does, pulls the account, adds a server and pushes
/// it. Returns the server's record id, which is the server id.
Future<String> _seanceRound(_Options options) async {
  final api = seance.HttpSyncClient(baseUrl: options.server);
  try {
    final prelogin = await api.prelogin(options.username);
    final keys = await seance.VaultCrypto.deriveKeys(
      passphrase: options.password,
      salt: base64.decode(prelogin.argonSalt),
      params: prelogin.argonParams,
    );
    await api.login(
      seance.LoginRequest(
        username: options.username,
        authVerifier: base64.encode(keys.authVerifier),
      ),
    );
    final configs = _ListConfigStore();
    final coordinator = seance.SyncCoordinator(
      configStore: configs,
      hostKeyStore: seance.InMemoryHostKeyStore(),
      codec: seance.RecordCodec(keys.vaultKey),
      local: seance.InMemoryLocalRecordStore(),
      deviceId: 'previous-seance',
    );
    await coordinator.run(api);

    final now = DateTime.now().millisecondsSinceEpoch;
    const id = 'previous-seance-server';
    await configs.putServer(
      seance.ServerConfig(
        id: id,
        label: 'previous Séance',
        host: 'previous-seance.example.com',
        port: 22,
        username: 'deploy',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await coordinator.run(api);
    await coordinator.run(api);
    return id;
  } finally {
    api.close();
  }
}

/// Logs in as Poltergeist does, in separate mode, saves a bookmark and
/// pushes it. Returns the bookmark's record id.
Future<String> _poltergeistRound(_Options options, Directory dir) async {
  final api = _HttpEnrollmentClient(baseUrl: options.server);
  try {
    final state = _MemoryEnrollmentState('previous-poltergeist');
    final records = PersistentLocalRecordStore(
      path: '${dir.path}/sync_records.json',
    );
    final bookmarks = FileBookmarkStore(
      path: '${dir.path}/bookmarks.json',
      syncDeviceId: () => state.id,
    );
    final enrollment = SyncEnrollment(
      credentials: _MemoryCredentials(),
      state: state,
      records: records,
      handlers: [BookmarkHandler(bookmarks: bookmarks)],
    );
    final enrolled = await enrollment.login(
      api: api,
      baseUrl: options.server,
      username: options.username,
      password: options.password,
      encryptionPassphrase: options.password,
      mode: SyncAccountMode.separate,
    );
    if (enrolled.passphraseUnverified) {
      throw StateError('Poltergeist could not verify the passphrase');
    }
    final coordinator = RecordCoordinator(
      records: records,
      handlers: [BookmarkHandler(bookmarks: bookmarks)],
      hostKeys: InMemoryConflictAwareHostKeyStore(),
      hostKeyMutations: HostKeyMutationGate(),
      crypto: RecordCrypto(RecordCodec(enrolled.vaultKey)),
      deviceId: state.id,
      pinVerdicts: InMemoryPinVerdictStore(),
      tripwires: InMemorySyncTripwireStore(),
      catalogMode: CatalogMode.separate,
      pushPolicy: PushPolicy.normal,
      enrollment: state,
    );
    await coordinator.runRound(api);

    final now = DateTime.now().toUtc();
    const id = 'previous-poltergeist';
    final saved = await bookmarks.save(
      Bookmark(
        id: id,
        kind: BookmarkKind.localFolder,
        label: 'previous Poltergeist',
        localPath: '/home/user/previous',
        sortKey: 'm',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await coordinator.onBookmarkSaved(saved);
    await coordinator.runRound(api);
    await coordinator.runRound(api);
    return 'bookmark:$id';
  } finally {
    api.close();
  }
}

/// `HttpSyncClient` has every member [SyncEnrollmentApi] declares but
/// implements only `SyncApi`; the marker subclass closes the gap, as
/// Poltergeist's app and convergence test do.
final class _HttpEnrollmentClient extends HttpSyncClient
    implements SyncEnrollmentApi {
  _HttpEnrollmentClient({required super.baseUrl});
}

final class _MemoryCredentials implements SyncCredentialStore {
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

final class _MemoryEnrollmentState implements SyncEnrollmentState {
  _MemoryEnrollmentState(this.id);

  final String id;
  bool unverified = false;
  final Set<String> raised = {};
  SyncAccount? enrolled;

  @override
  Future<String> deviceId() async => id;
  @override
  Future<bool> passphraseUnverified() async => unverified;
  @override
  Future<void> setPassphraseUnverified(bool value) async => unverified = value;
  @override
  Future<Set<String>> notices() async => Set.of(raised);
  @override
  Future<void> setNotice(String notice, bool active) async =>
      active ? raised.add(notice) : raised.remove(notice);
  @override
  Future<SyncAccount?> account() async => enrolled;
  @override
  Future<void> setAccount(SyncAccount? account) async => enrolled = account;
}

final class _ListConfigStore extends seance.ConfigStore {
  final _servers = <String, seance.ServerConfig>{};

  @override
  Future<List<seance.ServerConfig>> listServers() async =>
      _servers.values.toList();
  @override
  Future<seance.ServerConfig?> getServer(String id) async => _servers[id];
  @override
  Future<void> putServer(seance.ServerConfig config) async =>
      _servers[config.id] = config;
  @override
  Future<void> deleteServer(String id) async => _servers.remove(id);
}
