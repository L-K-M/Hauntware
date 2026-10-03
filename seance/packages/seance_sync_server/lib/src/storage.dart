import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';

/// A registered account. The server holds only a salted *hash* of the auth
/// verifier plus the non-secret KDF salt/params a new device needs. It never
/// sees the vault key or any plaintext.
class Account {
  final String username;
  final String authVerifierHash; // base64 of sha256(verifierSalt || verifier)
  final String verifierSalt; // base64
  final String argonSalt; // base64, echoed back at prelogin
  final Argon2Params argonParams;

  const Account({
    required this.username,
    required this.authVerifierHash,
    required this.verifierSalt,
    required this.argonSalt,
    required this.argonParams,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'authVerifierHash': authVerifierHash,
        'verifierSalt': verifierSalt,
        'argonSalt': argonSalt,
        'argonParams': argonParams.toJson(),
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        username: json['username'] as String,
        authVerifierHash: json['authVerifierHash'] as String,
        verifierSalt: json['verifierSalt'] as String,
        argonSalt: json['argonSalt'] as String,
        argonParams:
            Argon2Params.fromJson((json['argonParams'] as Map).cast()),
      );
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

  /// Create and persist a bearer token for [username]; returns the token.
  Future<String> createToken(String username);
  Future<String?> usernameForToken(String token);

  /// Resolve LWW, allocate sequences and commit a whole batch atomically.
  /// A rejected LWW write is a result; a storage failure commits nothing.
  /// Process entries in list order, including repeated ids. Later entries resolve
  /// against earlier staged writes. Empty batches return the current watermark.
  Future<PushResponse> pushRecords(
      String username, List<EncryptedRecord> records);

  /// Return records and their watermark from one consistent snapshot.
  Future<PullResponse> pullSnapshot(String username, int since);

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

  /// The app with [appId] in any account, for checking a deposit token.
  Future<StoredInboxApp?> getInboxApp(String appId);

  /// [username]'s apps with their pending item counts, oldest first.
  Future<List<InboxAppInfo>> listInboxApps(String username);

  /// Remove [username]'s app and every item pending for it. Returns false
  /// when [username] has no such app.
  Future<bool> deleteInboxApp(String username, String appId);

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

  /// Remove one item. Returns false when it is not (or no longer) there,
  /// which is how a device learns another one claimed it first.
  Future<bool> deleteInboxItem(String username, String appId, String itemId);

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

class InMemoryStorage implements Storage {
  final Map<String, Account> _accounts = {};
  final Map<String, String> _tokens = {}; // token -> username
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
    _tokens.removeWhere((_, u) => u == username);
    _inboxApps.removeWhere((_, app) => app.username == username);
    _inboxItems.removeWhere((item) => item.username == username);
    _inboxReceived.remove(username);
  }

  @override
  Future<String> createToken(String username) async {
    final token = base64Url.encode(secureRandomBytes(32));
    _tokens[token] = username;
    return token;
  }

  @override
  Future<String?> usernameForToken(String token) async => _tokens[token];

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
  Future<bool> deleteInboxApp(String username, String appId) async {
    if (_inboxApps[appId]?.username != username) return false;
    _inboxApps.remove(appId);
    _inboxItems.removeWhere((i) => i.appId == appId);
    return true;
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
  Future<bool> deleteInboxItem(
      String username, String appId, String itemId) async {
    final before = _inboxItems.length;
    _inboxItems.removeWhere((i) =>
        i.username == username && i.appId == appId && i.itemId == itemId);
    return _inboxItems.length != before;
  }

  @override
  Future<int> purgeInboxItems({required int storedBefore}) async {
    final before = _inboxItems.length;
    _inboxItems.removeWhere((i) => i.storedAt < storedBefore);
    return before - _inboxItems.length;
  }
}
