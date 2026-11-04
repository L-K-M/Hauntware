import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';

/// A registered account. The server holds only a salted *hash* of the auth
/// verifier plus the non-secret KDF salt/params a new device needs. It never
/// sees the vault key or any plaintext.
class Account {
  final String username;
  final String generation;
  final String authVerifierHash; // base64 of sha256(verifierSalt || verifier)
  final String verifierSalt; // base64
  final String argonSalt; // base64, echoed back at prelogin
  final Argon2Params argonParams;
  final String? vaultKeyCheck; // opaque, returned only after authentication

  const Account({
    required this.username,
    required this.generation,
    required this.authVerifierHash,
    required this.verifierSalt,
    required this.argonSalt,
    required this.argonParams,
    this.vaultKeyCheck,
  });
}

/// One authenticated session, bound to the exact account incarnation that
/// minted it. Re-registering the same username creates a new generation, so a
/// request already in flight cannot mutate the replacement account.
class AuthPrincipal {
  final String username;
  final String accountGeneration;
  final String tokenDigest;

  const AuthPrincipal({
    required this.username,
    required this.accountGeneration,
    required this.tokenDigest,
  });
}

class StalePrincipalException implements Exception {
  const StalePrincipalException();
}

class VaultKeyCheckInitializationException implements Exception {
  const VaultKeyCheckInitializationException();
}

/// A backend disabled after an unrecoverable transaction failure.
class StorageUnavailableException implements Exception {
  /// Retained for diagnostics, never included in the public error message.
  final Object? cause;

  const StorageUnavailableException({this.cause});

  @override
  String toString() => 'Sync storage unavailable; restart required.';
}

/// Transient storage contention; no batch was committed.
class StorageBusyException implements Exception {
  const StorageBusyException();
}

/// A registered inbox app as the server stores it. Like [Account], only a
/// salted hash of the deposit token is kept: a leaked database must not hand
/// out tokens that let anyone fill the user's inbox. The app key is never
/// here at all; it lives only in the producer and the user's vault.
class StoredInboxApp {
  final String username;
  final String appId;
  final String name;
  final String tokenHash; // base64 of sha256(tokenSalt || token)
  final String tokenSalt; // base64

  /// Milliseconds since the epoch.
  final int created;

  const StoredInboxApp({
    required this.username,
    required this.appId,
    required this.name,
    required this.tokenHash,
    required this.tokenSalt,
    required this.created,
  });
}

enum InboxAddStatus {
  added,

  /// The app was removed between the token check and the insert.
  unknownApp,

  /// The app already holds the maximum number of pending items.
  full,
}

/// What [Storage.addInboxItem] did. [received] is set only when [status] is
/// [InboxAddStatus.added].
class InboxAddResult {
  final InboxAddStatus status;
  final int? received;

  const InboxAddResult(this.status, [this.received]);
}

/// Persistence for the server. Records are stored as opaque [EncryptedRecord]s
/// (their `blob` is end-to-end encrypted and their `seq` is server-assigned).
/// Implemented in memory (tests) and over SQLite (production).
abstract class Storage {
  Future<Account?> getAccount(String username);
  Future<void> createAccount(Account account);
  Future<void> deleteAccount(String username);

  /// Atomically create a new account and its first session. Returns null when
  /// the username already exists.
  Future<String?> registerAccount(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
  });

  /// Compatibility helper for tests and maintenance code. Production login
  /// uses [createTokenFor] so deletion/re-registration cannot race minting.
  Future<String> createToken(String username);
  Future<String?> usernameForToken(String token);

  /// Mint a session only if [account] is still the current generation.
  Future<String?> createTokenFor(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
  });

  /// Resolve a non-expired raw bearer token to its immutable principal.
  Future<AuthPrincipal?> principalForToken(String token, {required int now});

  Future<bool> revokeSession(AuthPrincipal principal);
  Future<bool> revokeAllSessions(AuthPrincipal principal);
  Future<bool> deleteAccountFor(AuthPrincipal principal);

  /// Set an empty legacy account's key check exactly once. A concurrent
  /// winner is returned so the caller can authenticate it with its vault key.
  Future<String> initializeVaultKeyCheckFor(
    AuthPrincipal principal,
    String vaultKeyCheck,
  );

  /// Resolve LWW, allocate sequences and commit a whole batch atomically.
  /// A rejected LWW write is a result; a storage failure commits nothing.
  /// Process entries in list order, including repeated ids. Later entries resolve
  /// against earlier staged writes. Empty batches return the current watermark.
  Future<PushResponse> pushRecords(
      String username, List<EncryptedRecord> records);
  Future<PushResponse> pushRecordsFor(
      AuthPrincipal principal, List<EncryptedRecord> records);

  /// Return records and their watermark from one consistent snapshot.
  Future<PullResponse> pullSnapshot(String username, int since);
  Future<PullResponse> pullSnapshotFor(AuthPrincipal principal, int since);

  // Compatibility primitives; sync handlers must use the atomic operations.
  Future<EncryptedRecord?> getRecord(String username, String id);

  /// Store [record] (which must have a non-null seq) as the current version.
  Future<void> putRecord(String username, EncryptedRecord record);

  /// Records with seq strictly greater than [since], in ascending seq order.
  Future<List<EncryptedRecord>> recordsSince(String username, int since);

  /// Allocate the next monotonic sequence number for [username].
  Future<int> nextSeq(String username);
  Future<int> latestSeq(String username);

  // --- Command inbox (docs/INBOX.md). App ids are unique across accounts,
  // because the producer endpoint names only the app. ---

  /// Register [app]. Returns false, changing nothing, when its id is taken
  /// by any account.
  Future<bool> createInboxApp(StoredInboxApp app);
  Future<bool> createInboxAppFor(
      AuthPrincipal principal, StoredInboxApp app);

  /// The app with [appId] in any account, for checking a deposit token.
  Future<StoredInboxApp?> getInboxApp(String appId);

  /// [username]'s apps with their pending item counts, oldest first.
  Future<List<InboxAppInfo>> listInboxApps(String username);
  Future<List<InboxAppInfo>> listInboxAppsFor(AuthPrincipal principal);

  /// Remove [username]'s app and every item pending for it. Returns false
  /// when [username] has no such app.
  Future<bool> deleteInboxApp(String username, String appId);
  Future<bool> deleteInboxAppFor(AuthPrincipal principal, String appId);

  /// Queue [blob] for [appId]'s account under the next per-account
  /// `received` number, unless the app already holds [maxPending] items.
  /// [storedAt] (ms since the epoch) is what retention is measured from.
  Future<InboxAddResult> addInboxItem(
    String appId,
    String itemId,
    Uint8List blob, {
    required int storedAt,
    required int maxPending,
  });

  /// [username]'s items with `received` greater than [since], ascending.
  Future<List<InboxItem>> inboxItemsSince(String username, int since);
  Future<List<InboxItem>> inboxItemsSinceFor(
      AuthPrincipal principal, int since);

  /// Remove one item. Returns false when it is not (or no longer) there,
  /// which is how a device learns another one claimed it first.
  Future<bool> deleteInboxItem(String username, String appId, String itemId);
  Future<bool> deleteInboxItemFor(
      AuthPrincipal principal, String appId, String itemId);

  /// Drop every item stored before [storedBefore] (ms since the epoch), in
  /// all accounts. Returns how many were dropped.
  Future<int> purgeInboxItems({required int storedBefore});
}

class _MemoryInboxItem {
  final String username;
  final String appId;
  final String itemId;
  final int received;
  final Uint8List blob;
  final int storedAt;

  _MemoryInboxItem(this.username, this.appId, this.itemId, this.received,
      this.blob, this.storedAt);

  InboxItem toItem() => InboxItem(
      appId: appId, itemId: itemId, received: received, blob: blob);
}

class _MemorySession {
  final String username;
  final String accountGeneration;
  final int issuedAt;
  final int expiresAt;

  const _MemorySession({
    required this.username,
    required this.accountGeneration,
    required this.issuedAt,
    required this.expiresAt,
  });
}

String digestBearerToken(String token) =>
    VaultCrypto.hashAuthVerifier(utf8.encode(token), const []);

void validateSessionPolicy({
  required int issuedAt,
  required int expiresAt,
  required int maxSessions,
}) {
  if (expiresAt <= issuedAt) {
    throw ArgumentError.value(expiresAt, 'expiresAt', 'must follow issuedAt');
  }
  if (maxSessions <= 0) {
    throw ArgumentError.value(maxSessions, 'maxSessions', 'must be positive');
  }
}

class InMemoryStorage implements Storage {
  final Map<String, Account> _accounts = {};
  final Map<String, _MemorySession> _tokens = {}; // digest -> session
  final Map<String, Map<String, EncryptedRecord>> _records = {};
  final Map<String, int> _seq = {};
  final Map<String, StoredInboxApp> _inboxApps = {}; // appId -> app
  final List<_MemoryInboxItem> _inboxItems = []; // in received order
  final Map<String, int> _inboxReceived = {}; // username -> last received

  @override
  Future<Account?> getAccount(String username) async => _accounts[username];

  @override
  Future<void> createAccount(Account account) async {
    _accounts[account.username] = account;
    _records[account.username] = {};
    _seq[account.username] = 0;
  }

  @override
  Future<void> deleteAccount(String username) async {
    _accounts.remove(username);
    _records.remove(username);
    _seq.remove(username);
    _tokens.removeWhere((_, session) => session.username == username);
    _inboxApps.removeWhere((_, app) => app.username == username);
    _inboxItems.removeWhere((item) => item.username == username);
    _inboxReceived.remove(username);
  }

  @override
  Future<String?> registerAccount(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
  }) async {
    validateSessionPolicy(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
    );
    if (_accounts.containsKey(account.username)) return null;
    _accounts[account.username] = account;
    _records[account.username] = {};
    _seq[account.username] = 0;
    return _issueToken(
      account,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
    );
  }

  @override
  Future<String> createToken(String username) async {
    final account = _accounts[username];
    if (account == null) throw const StalePrincipalException();
    return _issueToken(
      account,
      issuedAt: 0,
      expiresAt: 0x7fffffffffffffff,
      maxSessions: 0x7fffffff,
    );
  }

  @override
  Future<String?> usernameForToken(String token) async =>
      (await principalForToken(token, now: DateTime.now().millisecondsSinceEpoch))
          ?.username;

  @override
  Future<String?> createTokenFor(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
  }) async {
    if (_accounts[account.username]?.generation != account.generation) {
      return null;
    }
    return _issueToken(
      account,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
    );
  }

  String _issueToken(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
  }) {
    validateSessionPolicy(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
    );
    _tokens.removeWhere((_, session) => session.expiresAt <= issuedAt);
    final own = _tokens.entries
        .where((entry) =>
            entry.value.username == account.username &&
            entry.value.accountGeneration == account.generation)
        .toList()
      ..sort((a, b) {
        final byTime = a.value.issuedAt.compareTo(b.value.issuedAt);
        return byTime != 0 ? byTime : a.key.compareTo(b.key);
      });
    while (own.length >= maxSessions) {
      final oldest = own.removeAt(0);
      _tokens.remove(oldest.key);
    }
    final token = base64Url.encode(secureRandomBytes(32));
    _tokens[digestBearerToken(token)] = _MemorySession(
      username: account.username,
      accountGeneration: account.generation,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
    return token;
  }

  @override
  Future<AuthPrincipal?> principalForToken(String token, {required int now}) async {
    final digest = digestBearerToken(token);
    final session = _tokens[digest];
    if (session == null) return null;
    if (session.expiresAt <= now ||
        _accounts[session.username]?.generation != session.accountGeneration) {
      _tokens.remove(digest);
      return null;
    }
    return AuthPrincipal(
      username: session.username,
      accountGeneration: session.accountGeneration,
      tokenDigest: digest,
    );
  }

  @override
  Future<bool> revokeSession(AuthPrincipal principal) async {
    if (!_isCurrent(principal)) return false;
    return _tokens.remove(principal.tokenDigest) != null;
  }

  @override
  Future<bool> revokeAllSessions(AuthPrincipal principal) async {
    if (!_isCurrent(principal)) return false;
    _tokens.removeWhere((_, session) =>
        session.username == principal.username &&
        session.accountGeneration == principal.accountGeneration);
    return true;
  }

  @override
  Future<bool> deleteAccountFor(AuthPrincipal principal) async {
    if (!_isCurrent(principal)) return false;
    await deleteAccount(principal.username);
    return true;
  }

  @override
  Future<String> initializeVaultKeyCheckFor(
    AuthPrincipal principal,
    String vaultKeyCheck,
  ) async {
    _requireCurrent(principal);
    final account = _accounts[principal.username]!;
    final existing = account.vaultKeyCheck;
    if (existing != null) return existing;
    if (_records[principal.username]?.isNotEmpty ?? false) {
      throw const VaultKeyCheckInitializationException();
    }
    _accounts[principal.username] = Account(
      username: account.username,
      generation: account.generation,
      authVerifierHash: account.authVerifierHash,
      verifierSalt: account.verifierSalt,
      argonSalt: account.argonSalt,
      argonParams: account.argonParams,
      vaultKeyCheck: vaultKeyCheck,
    );
    return vaultKeyCheck;
  }

  bool _isCurrent(AuthPrincipal principal) {
    if (_accounts[principal.username]?.generation !=
        principal.accountGeneration) {
      return false;
    }
    final session = _tokens[principal.tokenDigest];
    return session?.username == principal.username &&
        session?.accountGeneration == principal.accountGeneration;
  }

  void _requireCurrent(AuthPrincipal principal) {
    if (!_isCurrent(principal)) throw const StalePrincipalException();
  }

  @override
  Future<PushResponse> pushRecords(
      String username, List<EncryptedRecord> records) async {
    // Stage without awaits so failures and concurrent requests see no partial batch.
    final staged = Map<String, EncryptedRecord>.of(_records[username] ?? {});
    var seq = _seq[username] ?? 0;
    final results = <PushResult>[];
    for (final incoming in records) {
      final existing = staged[incoming.id];
      if (existing != null &&
          !identical(Lww.resolve(existing, incoming), incoming)) {
        results.add(PushResult(
            id: incoming.id, seq: existing.seq ?? 0, accepted: false));
        continue;
      }

      seq++;
      staged[incoming.id] = incoming.withSeq(seq);
      results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
    }

    _records[username] = staged;
    _seq[username] = seq;
    return PushResponse(results: results, latestSeq: seq);
  }

  @override
  Future<PushResponse> pushRecordsFor(
      AuthPrincipal principal, List<EncryptedRecord> records) {
    _requireCurrent(principal);
    return pushRecords(principal.username, records);
  }

  @override
  Future<PullResponse> pullSnapshot(String username, int since) async {
    // Copy the rows and watermark in one synchronous turn.
    final watermark = _seq[username] ?? 0;
    final records = (_records[username]?.values ?? const <EncryptedRecord>[])
        .where((r) => (r.seq ?? 0) > since && (r.seq ?? 0) <= watermark)
        .toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(records: records, latestSeq: watermark);
  }

  @override
  Future<PullResponse> pullSnapshotFor(
      AuthPrincipal principal, int since) {
    _requireCurrent(principal);
    return pullSnapshot(principal.username, since);
  }

  @override
  Future<EncryptedRecord?> getRecord(String username, String id) async =>
      _records[username]?[id];

  @override
  Future<void> putRecord(String username, EncryptedRecord record) async {
    (_records[username] ??= {})[record.id] = record;
  }

  @override
  Future<List<EncryptedRecord>> recordsSince(String username, int since) async {
    final all = _records[username]?.values ?? const <EncryptedRecord>[];
    final list = all.where((r) => (r.seq ?? 0) > since).toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return list;
  }

  @override
  Future<int> nextSeq(String username) async {
    final next = (_seq[username] ?? 0) + 1;
    _seq[username] = next;
    return next;
  }

  @override
  Future<int> latestSeq(String username) async => _seq[username] ?? 0;

  @override
  Future<bool> createInboxApp(StoredInboxApp app) async {
    if (_inboxApps.containsKey(app.appId)) return false;
    _inboxApps[app.appId] = app;
    return true;
  }

  @override
  Future<bool> createInboxAppFor(
      AuthPrincipal principal, StoredInboxApp app) {
    _requireCurrent(principal);
    if (app.username != principal.username) {
      throw ArgumentError.value(app.username, 'app.username');
    }
    return createInboxApp(app);
  }

  @override
  Future<StoredInboxApp?> getInboxApp(String appId) async => _inboxApps[appId];

  @override
  Future<List<InboxAppInfo>> listInboxApps(String username) async {
    final apps = _inboxApps.values.where((a) => a.username == username).toList()
      ..sort((a, b) => a.created.compareTo(b.created));
    return [
      for (final app in apps)
        InboxAppInfo(
          appId: app.appId,
          name: app.name,
          created: app.created,
          pending: _inboxItems.where((i) => i.appId == app.appId).length,
        ),
    ];
  }

  @override
  Future<List<InboxAppInfo>> listInboxAppsFor(AuthPrincipal principal) {
    _requireCurrent(principal);
    return listInboxApps(principal.username);
  }

  @override
  Future<bool> deleteInboxApp(String username, String appId) async {
    if (_inboxApps[appId]?.username != username) return false;
    _inboxApps.remove(appId);
    _inboxItems.removeWhere((i) => i.appId == appId);
    return true;
  }

  @override
  Future<bool> deleteInboxAppFor(
      AuthPrincipal principal, String appId) {
    _requireCurrent(principal);
    return deleteInboxApp(principal.username, appId);
  }

  @override
  Future<InboxAddResult> addInboxItem(
    String appId,
    String itemId,
    Uint8List blob, {
    required int storedAt,
    required int maxPending,
  }) async {
    final app = _inboxApps[appId];
    if (app == null) return const InboxAddResult(InboxAddStatus.unknownApp);
    if (_inboxItems.where((i) => i.appId == appId).length >= maxPending) {
      return const InboxAddResult(InboxAddStatus.full);
    }
    final received = (_inboxReceived[app.username] ?? 0) + 1;
    _inboxReceived[app.username] = received;
    _inboxItems.add(_MemoryInboxItem(
        app.username, appId, itemId, received, blob, storedAt));
    return InboxAddResult(InboxAddStatus.added, received);
  }

  @override
  Future<List<InboxItem>> inboxItemsSince(String username, int since) async => [
        for (final item in _inboxItems)
          if (item.username == username && item.received > since)
            item.toItem(),
      ];

  @override
  Future<List<InboxItem>> inboxItemsSinceFor(
      AuthPrincipal principal, int since) {
    _requireCurrent(principal);
    return inboxItemsSince(principal.username, since);
  }

  @override
  Future<bool> deleteInboxItem(
      String username, String appId, String itemId) async {
    final before = _inboxItems.length;
    _inboxItems.removeWhere((i) =>
        i.username == username && i.appId == appId && i.itemId == itemId);
    return _inboxItems.length != before;
  }

  @override
  Future<bool> deleteInboxItemFor(
      AuthPrincipal principal, String appId, String itemId) {
    _requireCurrent(principal);
    return deleteInboxItem(principal.username, appId, itemId);
  }

  @override
  Future<int> purgeInboxItems({required int storedBefore}) async {
    final before = _inboxItems.length;
    _inboxItems.removeWhere((i) => i.storedAt < storedBefore);
    return before - _inboxItems.length;
  }
}
