import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';

import 'legacy_migration_validation.dart';
import 'record_quota.dart';

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
  final int recordEnvelopeFloor;
  final int recordEnvelopeFloorSeq;

  const Account({
    required this.username,
    required this.generation,
    required this.authVerifierHash,
    required this.verifierSalt,
    required this.argonSalt,
    required this.argonParams,
    this.vaultKeyCheck,
    this.recordEnvelopeFloor = kCurrentRecordEnvelopeVersion,
    this.recordEnvelopeFloorSeq = 0,
  });

  Account withRecordEnvelopeFloor(int floor, {int? atSeq}) => Account(
    username: username,
    generation: generation,
    authVerifierHash: authVerifierHash,
    verifierSalt: verifierSalt,
    argonSalt: argonSalt,
    argonParams: argonParams,
    vaultKeyCheck: vaultKeyCheck,
    recordEnvelopeFloor: floor,
    recordEnvelopeFloorSeq: atSeq ?? recordEnvelopeFloorSeq,
  );
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

/// Descriptive installation metadata, never an authentication factor.
class SessionDevice {
  static const _maxBytes = 128;
  static final _idPattern = RegExp(r'^[A-Za-z0-9._:-]+$');
  static final _invalidName = RegExp(
    '[\u0000-\u001f\u007f-\u009f\u00ad\u200b-\u200f'
    '\u2028-\u202e\u2060-\u206f\ufeff]',
  );
  final String id;
  final String name;

  const SessionDevice({required this.id, required this.name});

  bool get isValid =>
      id.isNotEmpty &&
      utf8.encode(id).length <= _maxBytes &&
      _idPattern.hasMatch(id) &&
      name.isNotEmpty &&
      name.trim() == name &&
      utf8.encode(name).length <= _maxBytes &&
      !_invalidName.hasMatch(name);
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

/// The requested stable cursor cannot exist for this account generation.
class StorageCursorRejectedException implements Exception {
  const StorageCursorRejectedException();
}

/// A single stored row cannot fit the operator's configured response page.
class StoragePageTooSmallException implements Exception {
  const StoragePageTooSmallException();
}

/// The account claims a v2-only checkpoint while a legacy row still exists.
class StorageEnvelopeFloorViolationException implements Exception {
  const StorageEnvelopeFloorViolationException();
}

/// A write would grow an account past its durable storage budget.
class AccountQuotaExceededException implements Exception {
  const AccountQuotaExceededException();
}

/// Bounds one response page. Both dimensions apply at once.
class PullPageLimits {
  final int maxRecords;
  final int maxBodyBytes;

  const PullPageLimits({required this.maxRecords, required this.maxBodyBytes});
}

/// Bounds one account's current winning rows. Null means unbounded, which
/// preserves the public storage helpers used by tests and embedders; the HTTP
/// server always supplies its configured quota.
///
/// [maxRecords] counts live rows only. Rows are never removed, so a deletion
/// is a tombstone row; counting those would let ordinary churn fill an
/// account for good, with deleting things making it worse rather than better.
/// [maxBytes] still counts every row, tombstones included, so what an
/// account can make the server store stays bounded.
class AccountQuota {
  final int maxRecords;
  final int maxBytes;

  const AccountQuota({required this.maxRecords, required this.maxBytes});
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

/// The account already owns its maximum number of producer registrations.
final class InboxAppLimitException implements Exception {
  const InboxAppLimitException();
}

enum InboxAddStatus {
  added,

  /// The app was removed between the token check and the insert.
  unknownApp,

  /// The app already holds the maximum number of pending items.
  full,

  /// This account's pending inbox bytes reached the durable quota.
  accountFull,
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
  /// Verify that this backend can serve storage-backed requests.
  ///
  /// Memory and simple custom implementations need no probe. Persistent
  /// backends override this with a cheap real access so readiness cannot claim
  /// success after the connection has failed closed.
  Future<void> checkReady() async {}

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
    SessionDevice? device,
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
    SessionDevice? device,
  });

  /// Resolve a non-expired raw bearer token to its immutable principal.
  Future<AuthPrincipal?> principalForToken(String token, {required int now});

  Future<bool> revokeSession(AuthPrincipal principal);
  Future<bool> revokeAllSessions(AuthPrincipal principal);

  /// Public metadata from the caller's current account generation. The caller
  /// must still hold a live session when this snapshot is taken.
  Future<List<SyncSessionInfo>> listSessionsFor(
    AuthPrincipal principal, {
    required int now,
  });

  /// Selectively revoke an opaque session id in the same transaction that
  /// revalidates the caller's generation and still-live bearer session.
  Future<RevokeSessionResponse> revokeSessionByIdFor(
    AuthPrincipal principal,
    String sessionId, {
    required int now,
  });
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
  ///
  /// A batch that would exceed [quota] throws [AccountQuotaExceededException]
  /// and commits nothing under [PushRefusalScope.batch]. Under
  /// [PushRefusalScope.record] it is applied entry by entry instead, in the
  /// same transaction: in list order, then the entries that did not fit once
  /// more, so a deletion anywhere in the batch makes room for a new id. An
  /// entry that still would grow a quota dimension past its cap is listed in
  /// [PushResponse.refused] without a sequence; every other entry is applied
  /// as usual. A batch that fits is stored whole in either scope.
  Future<PushResponse> pushRecords(
    String username,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
    PushRefusalScope refusalScope = PushRefusalScope.batch,
  });
  Future<PushResponse> pushRecordsFor(
    AuthPrincipal principal,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
    PushRefusalScope refusalScope = PushRefusalScope.batch,
  });

  /// Return records and their watermark from one consistent snapshot.
  Future<PullResponse> pullSnapshot(String username, int since);

  /// One bounded page from a stable account watermark. The first request
  /// omits [throughSeq] and captures the current sequence; continuations send
  /// it back so concurrent pushes wait for the next sync window.
  Future<PullResponse> pullPage(
    String username,
    int since, {
    int? throughSeq,
    required PullPageLimits limits,
    PushLimits? advertisedLimits,
  });
  Future<PullResponse> pullSnapshotFor(AuthPrincipal principal, int since);
  Future<PullResponse> pullPageFor(
    AuthPrincipal principal,
    int since, {
    int? throughSeq,
    required PullPageLimits limits,
    PushLimits? advertisedLimits,
  });

  /// Enumerate legacy rows by id. Current writers cannot add legacy rows, so
  /// removing rows concurrently cannot invalidate the lexical cursor.
  Future<LegacyRecordPage> legacyRecordPage(
    String username, {
    String? afterId,
    required PullPageLimits limits,
  });
  Future<LegacyRecordPage> legacyRecordPageFor(
    AuthPrincipal principal, {
    String? afterId,
    required PullPageLimits limits,
  });

  /// Atomically replace exact observed v1 rows and, when requested, advance
  /// the account floor only after proving no non-v2 row remains.
  Future<LegacyMigrationResponse> migrateLegacyRecords(
    String username,
    List<LegacyRecordMigration> migrations, {
    required bool finalize,
    AccountQuota? quota,
  });
  Future<LegacyMigrationResponse> migrateLegacyRecordsFor(
    AuthPrincipal principal,
    List<LegacyRecordMigration> migrations, {
    required bool finalize,
    AccountQuota? quota,
  });

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
    AuthPrincipal principal,
    StoredInboxApp app, {
    int maxApps = 50,
  });

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
    AccountQuota? quota,
    String? expectedGeneration,
    int maxAccountPendingItems = 5000,
    int maxAccountPendingBytes = 32 * 1024 * 1024,
  });

  /// [username]'s items with `received` greater than [since], ascending.
  Future<List<InboxItem>> inboxItemsSince(
    String username,
    int since, {
    int? limit,
  });

  /// One bounded page of pending items under a stable per-account received
  /// watermark.
  Future<InboxPage> inboxPage(
    String username,
    int since, {
    int? throughReceived,
    required PullPageLimits limits,
  });
  Future<List<InboxItem>> inboxItemsSinceFor(
    AuthPrincipal principal,
    int since,
  );
  Future<InboxPage> inboxPageFor(
    AuthPrincipal principal,
    int since, {
    int? throughReceived,
    required PullPageLimits limits,
  });

  /// Remove one item. Returns false when it is not (or no longer) there,
  /// which is how a device learns another one claimed it first.
  Future<bool> deleteInboxItem(String username, String appId, String itemId);
  Future<bool> deleteInboxItemFor(
    AuthPrincipal principal,
    String appId,
    String itemId,
  );

  /// Drop every item stored before [storedBefore] (ms since the epoch), in
  /// all accounts. Returns how many were dropped.
  Future<int> purgeInboxItems({required int storedBefore});
}

int _recordBytes(Iterable<EncryptedRecord> records) =>
    records.fold(0, (total, record) => total + record.encodedJsonBytes());

int _liveCount(Iterable<EncryptedRecord> records) =>
    records.where((record) => !record.deleted).length;

int _inboxBytes(Iterable<InboxItem> items) =>
    items.fold(0, (total, item) => total + item.encodedJsonBytes());

void enforceAccountQuota({
  required int beforeCount,
  required int beforeBytes,
  required int afterCount,
  required int afterBytes,
  required AccountQuota quota,
}) {
  if (exceedsAccountQuota(
    beforeCount: beforeCount,
    beforeBytes: beforeBytes,
    afterCount: afterCount,
    afterBytes: afterBytes,
    quota: quota,
  )) {
    throw const AccountQuotaExceededException();
  }
}

class _MemoryInboxItem {
  final String username;
  final String appId;
  final String itemId;
  final int received;
  final Uint8List blob;
  final int storedAt;

  _MemoryInboxItem(
    this.username,
    this.appId,
    this.itemId,
    this.received,
    this.blob,
    this.storedAt,
  );

  InboxItem toItem() =>
      InboxItem(appId: appId, itemId: itemId, received: received, blob: blob);
}

class _MemorySession {
  final String id;
  final String username;
  final String accountGeneration;
  final int issuedAt;
  final int expiresAt;
  final int lastUsedAt;
  final SessionDevice? device;

  const _MemorySession({
    required this.id,
    required this.username,
    required this.accountGeneration,
    required this.issuedAt,
    required this.expiresAt,
    required this.lastUsedAt,
    this.device,
  });

  _MemorySession touched(int now) => _MemorySession(
    id: id,
    username: username,
    accountGeneration: accountGeneration,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    lastUsedAt: now,
    device: device,
  );

  SyncSessionInfo info({required bool current}) => SyncSessionInfo(
    id: id,
    deviceId: device?.id,
    deviceName: device?.name ?? 'Unknown device',
    createdAt: issuedAt,
    expiresAt: expiresAt,
    lastUsedAt: lastUsedAt,
    legacy: device == null,
    current: current,
  );
}

String digestBearerToken(String token) =>
    VaultCrypto.hashAuthVerifier(utf8.encode(token), const []);

String newSessionId() =>
    base64Url.encode(secureRandomBytes(16)).replaceAll('=', '');

int compareSessionsNewestFirst(SyncSessionInfo a, SyncSessionInfo b) {
  final byUse = b.lastUsedAt.compareTo(a.lastUsedAt);
  if (byUse != 0) return byUse;
  final byTime = b.createdAt.compareTo(a.createdAt);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

void validateSessionPolicy({
  required int issuedAt,
  required int expiresAt,
  required int maxSessions,
  SessionDevice? device,
}) {
  if (expiresAt <= issuedAt) {
    throw ArgumentError.value(expiresAt, 'expiresAt', 'must follow issuedAt');
  }
  if (maxSessions <= 0) {
    throw ArgumentError.value(maxSessions, 'maxSessions', 'must be positive');
  }
  if (device != null && !device.isValid) {
    throw ArgumentError.value(device, 'device', 'invalid device metadata');
  }
}

class InMemoryStorage implements Storage {
  final Map<String, Account> _accounts = {};
  final Map<String, _MemorySession> _tokens = {}; // digest -> session
  final Map<String, Map<String, EncryptedRecord>> _records = {};
  final Map<String, int> _seq = {};
  final Map<String, StoredInboxApp> _inboxApps = {}; // appId -> app
  final List<_MemoryInboxItem> _inboxItems = []; // in received order

  @override
  Future<void> checkReady() async {}
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
    SessionDevice? device,
  }) async {
    validateSessionPolicy(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
      device: device,
    );
    if (_accounts.containsKey(account.username)) return null;
    final username = account.username;
    _tokens.removeWhere((_, session) => session.username == username);
    _inboxApps.removeWhere((_, app) => app.username == username);
    _inboxItems.removeWhere((item) => item.username == username);
    _inboxReceived.remove(username);
    _accounts[account.username] = account;
    _records[account.username] = {};
    _seq[account.username] = 0;
    return _issueToken(
      account,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
      device: device,
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
      (await principalForToken(
        token,
        now: DateTime.now().millisecondsSinceEpoch,
      ))?.username;

  @override
  Future<String?> createTokenFor(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
    SessionDevice? device,
  }) async {
    if (_accounts[account.username]?.generation != account.generation) {
      return null;
    }
    return _issueToken(
      account,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
      device: device,
    );
  }

  String _issueToken(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
    SessionDevice? device,
  }) {
    validateSessionPolicy(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
      device: device,
    );
    _tokens.removeWhere(
      (_, session) =>
          session.expiresAt <= issuedAt ||
          (device != null &&
              session.username == account.username &&
              session.accountGeneration == account.generation &&
              session.device?.id == device.id),
    );
    final own =
        _tokens.entries
            .where(
              (entry) =>
                  entry.value.username == account.username &&
                  entry.value.accountGeneration == account.generation,
            )
            .toList()
          ..sort((a, b) {
            final byUse = a.value.lastUsedAt.compareTo(b.value.lastUsedAt);
            if (byUse != 0) return byUse;
            final byTime = a.value.issuedAt.compareTo(b.value.issuedAt);
            return byTime != 0 ? byTime : a.value.id.compareTo(b.value.id);
          });
    while (own.length >= maxSessions) {
      final oldest = own.removeAt(0);
      _tokens.remove(oldest.key);
    }
    final token = base64Url.encode(secureRandomBytes(32));
    _tokens[digestBearerToken(token)] = _MemorySession(
      id: newSessionId(),
      username: account.username,
      accountGeneration: account.generation,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      lastUsedAt: issuedAt,
      device: device,
    );
    return token;
  }

  @override
  Future<AuthPrincipal?> principalForToken(
    String token, {
    required int now,
  }) async {
    final digest = digestBearerToken(token);
    var session = _tokens[digest];
    if (session == null) return null;
    if (session.expiresAt <= now ||
        _accounts[session.username]?.generation != session.accountGeneration) {
      _tokens.remove(digest);
      return null;
    }
    if (session.lastUsedAt <= now - const Duration(hours: 1).inMilliseconds) {
      session = session.touched(now);
      _tokens[digest] = session;
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
    _tokens.removeWhere(
      (_, session) =>
          session.username == principal.username &&
          session.accountGeneration == principal.accountGeneration,
    );
    return true;
  }

  void _requireSessionAt(AuthPrincipal principal, int now) {
    _requireCurrent(principal);
    if (_tokens[principal.tokenDigest]!.expiresAt <= now) {
      throw const StalePrincipalException();
    }
  }

  @override
  Future<List<SyncSessionInfo>> listSessionsFor(
    AuthPrincipal principal, {
    required int now,
  }) async {
    _requireSessionAt(principal, now);
    _tokens.removeWhere((_, session) => session.expiresAt <= now);
    final sessions = [
      for (final entry in _tokens.entries)
        if (entry.value.username == principal.username &&
            entry.value.accountGeneration == principal.accountGeneration)
          entry.value.info(current: entry.key == principal.tokenDigest),
    ]..sort(compareSessionsNewestFirst);
    return sessions;
  }

  @override
  Future<RevokeSessionResponse> revokeSessionByIdFor(
    AuthPrincipal principal,
    String sessionId, {
    required int now,
  }) async {
    _requireSessionAt(principal, now);
    final matches = _tokens.entries.where(
      (entry) =>
          entry.value.id == sessionId &&
          entry.value.username == principal.username &&
          entry.value.accountGeneration == principal.accountGeneration &&
          entry.value.expiresAt > now,
    );
    if (matches.isEmpty) {
      return const RevokeSessionResponse(revoked: false, current: false);
    }
    final digest = matches.single.key;
    _tokens.remove(digest);
    return RevokeSessionResponse(
      revoked: true,
      current: digest == principal.tokenDigest,
    );
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
      recordEnvelopeFloor: account.recordEnvelopeFloor,
      recordEnvelopeFloorSeq: account.recordEnvelopeFloorSeq,
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
    String username,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
    PushRefusalScope refusalScope = PushRefusalScope.batch,
  }) async {
    try {
      return _pushBatch(username, records, quota: quota);
    } on AccountQuotaExceededException {
      if (refusalScope == PushRefusalScope.batch) rethrow;
    }
    return _pushEachRecord(username, records, quota: quota!);
  }

  PushResponse _pushBatch(
    String username,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
  }) {
    // Stage without awaits so failures and concurrent requests see no partial batch.
    final current = _records[username] ?? const <String, EncryptedRecord>{};
    final staged = Map<String, EncryptedRecord>.of(current);
    var seq = _seq[username] ?? 0;
    final results = <PushResult>[];
    var changed = false;
    for (final incoming in records) {
      final existing = staged[incoming.id];
      if (existing != null &&
          !identical(Lww.resolve(existing, incoming), incoming)) {
        results.add(
          PushResult(id: incoming.id, seq: existing.seq ?? 0, accepted: false),
        );
        continue;
      }

      seq++;
      staged[incoming.id] = incoming.withSeq(seq);
      results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
      changed = true;
    }

    if (changed && quota != null) {
      enforceAccountQuota(
        beforeCount: _liveCount(current.values),
        beforeBytes: _recordBytes(current.values),
        afterCount: _liveCount(staged.values),
        afterBytes: _recordBytes(staged.values),
        quota: quota,
      );
    }

    _records[username] = staged;
    _seq[username] = seq;
    return PushResponse(results: results, latestSeq: seq);
  }

  /// [Storage.pushRecords] under [PushRefusalScope.record] once the batch as
  /// a whole did not fit. Staged as [_pushBatch] is, without awaits.
  PushResponse _pushEachRecord(
    String username,
    List<EncryptedRecord> records, {
    required AccountQuota quota,
  }) {
    final current = _records[username] ?? const <String, EncryptedRecord>{};
    final staged = Map<String, EncryptedRecord>.of(current);
    var seq = _seq[username] ?? 0;
    RecordUsage usage = (
      count: _liveCount(current.values),
      bytes: _recordBytes(current.values),
    );
    final results = <PushResult>[];
    var pending = records;
    for (var pass = 0; pass < perRecordQuotaPasses; pass++) {
      final deferred = <EncryptedRecord>[];
      for (final incoming in pending) {
        final existing = staged[incoming.id];
        if (existing != null &&
            !identical(Lww.resolve(existing, incoming), incoming)) {
          results.add(
            PushResult(
              id: incoming.id,
              seq: existing.seq ?? 0,
              accepted: false,
            ),
          );
          continue;
        }

        final candidate = incoming.withSeq(seq + 1);
        final after = usageAfterReplacing(
          usage,
          existing: existing,
          existingBytes: existing?.encodedJsonBytes() ?? 0,
          replacement: candidate,
        );
        if (exceedsAccountQuota(
          beforeCount: usage.count,
          beforeBytes: usage.bytes,
          afterCount: after.count,
          afterBytes: after.bytes,
          quota: quota,
        )) {
          deferred.add(incoming);
          continue;
        }

        seq++;
        staged[incoming.id] = candidate;
        results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
        usage = after;
      }
      pending = deferred;
    }
    final refused = [
      for (final record in pending)
        PushRefusal(id: record.id, reason: PushRefusalReason.accountQuota),
    ];

    _records[username] = staged;
    _seq[username] = seq;
    return PushResponse(results: results, refused: refused, latestSeq: seq);
  }

  @override
  Future<PushResponse> pushRecordsFor(
    AuthPrincipal principal,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
    PushRefusalScope refusalScope = PushRefusalScope.batch,
  }) {
    _requireCurrent(principal);
    return pushRecords(
      principal.username,
      records,
      quota: quota,
      refusalScope: refusalScope,
    );
  }

  @override
  Future<PullResponse> pullSnapshot(String username, int since) async {
    // Copy the rows and watermark in one synchronous turn.
    final watermark = _seq[username] ?? 0;
    final records =
        (_records[username]?.values ?? const <EncryptedRecord>[])
            .where((r) => (r.seq ?? 0) > since && (r.seq ?? 0) <= watermark)
            .toList()
          ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(
      records: records,
      latestSeq: watermark,
      recordEnvelopeFloor: _recordEnvelopeFloor(username, watermark),
    );
  }

  @override
  Future<PullResponse> pullPage(
    String username,
    int since, {
    int? throughSeq,
    required PullPageLimits limits,
    PushLimits? advertisedLimits,
  }) async {
    final latest = _seq[username] ?? 0;
    final through = throughSeq ?? latest;
    if (through < since || through > latest) {
      throw const StorageCursorRejectedException();
    }
    final candidates =
        (_records[username]?.values ?? const <EncryptedRecord>[]).where((
          record,
        ) {
          final seq = record.seq ?? 0;
          return seq > since && seq <= through;
        }).toList()..sort((a, b) => a.seq!.compareTo(b.seq!));
    final records = <EncryptedRecord>[];
    var recordBytes = 0;
    for (final candidate in candidates) {
      if (records.length == limits.maxRecords) break;
      final nextBytes = recordBytes + candidate.encodedJsonBytes();
      final fits =
          PullResponse.bodyBytesFor(
            recordCount: records.length + 1,
            recordBytes: nextBytes,
            latestSeq: through,
            throughSeq: through,
            hasMore: false,
            limits: advertisedLimits,
          ) <=
          limits.maxBodyBytes;
      if (!fits) {
        if (records.isEmpty) throw const StoragePageTooSmallException();
        break;
      }
      records.add(candidate);
      recordBytes = nextBytes;
    }
    final next = records.isEmpty ? since : records.last.seq!;
    final hasMore = candidates.any((record) => record.seq! > next);
    return PullResponse(
      records: records,
      latestSeq: through,
      recordEnvelopeFloor: _recordEnvelopeFloor(username, through),
      throughSeq: through,
      hasMore: hasMore,
      limits: advertisedLimits,
    );
  }

  @override
  Future<PullResponse> pullSnapshotFor(AuthPrincipal principal, int since) {
    _requireCurrent(principal);
    return pullSnapshot(principal.username, since);
  }

  @override
  Future<PullResponse> pullPageFor(
    AuthPrincipal principal,
    int since, {
    int? throughSeq,
    required PullPageLimits limits,
    PushLimits? advertisedLimits,
  }) {
    _requireCurrent(principal);
    return pullPage(
      principal.username,
      since,
      throughSeq: throughSeq,
      limits: limits,
      advertisedLimits: advertisedLimits,
    );
  }

  int _recordEnvelopeFloor(String username, [int? throughSeq]) {
    final account = _accounts[username];
    if (account == null) return kLegacyRecordEnvelopeVersion;
    if (account.recordEnvelopeFloor == kCurrentRecordEnvelopeVersion &&
        throughSeq != null &&
        throughSeq < account.recordEnvelopeFloorSeq) {
      return kLegacyRecordEnvelopeVersion;
    }
    return account.recordEnvelopeFloor;
  }

  @override
  Future<LegacyRecordPage> legacyRecordPage(
    String username, {
    String? afterId,
    required PullPageLimits limits,
  }) async {
    final floor = _recordEnvelopeFloor(username);
    final candidates =
        (_records[username]?.values ?? const <EncryptedRecord>[])
            .where(
              (record) =>
                  record.envelopeVersion == kLegacyRecordEnvelopeVersion &&
                  (afterId == null || record.id.compareTo(afterId) > 0),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    if (floor == kCurrentRecordEnvelopeVersion && candidates.isNotEmpty) {
      throw const StorageEnvelopeFloorViolationException();
    }
    final records = <EncryptedRecord>[];
    var recordBytes = 0;
    for (final candidate in candidates) {
      if (records.length == limits.maxRecords) break;
      final nextBytes = recordBytes + candidate.encodedJsonBytes();
      final fits =
          LegacyRecordPage.bodyBytesFor(
            recordCount: records.length + 1,
            recordBytes: nextBytes,
            nextId: candidate.id,
            hasMore: false,
            recordEnvelopeFloor: floor,
          ) <=
          limits.maxBodyBytes;
      if (!fits) {
        if (records.isEmpty) throw const StoragePageTooSmallException();
        break;
      }
      records.add(candidate);
      recordBytes = nextBytes;
    }
    final nextId = records.isEmpty ? null : records.last.id;
    return LegacyRecordPage(
      records: records,
      nextId: nextId,
      hasMore: candidates.length > records.length,
      recordEnvelopeFloor: floor,
    );
  }

  @override
  Future<LegacyRecordPage> legacyRecordPageFor(
    AuthPrincipal principal, {
    String? afterId,
    required PullPageLimits limits,
  }) {
    _requireCurrent(principal);
    return legacyRecordPage(
      principal.username,
      afterId: afterId,
      limits: limits,
    );
  }

  @override
  Future<LegacyMigrationResponse> migrateLegacyRecords(
    String username,
    List<LegacyRecordMigration> migrations, {
    required bool finalize,
    AccountQuota? quota,
  }) async {
    validateLegacyMigrationBatch(migrations);
    final current = _records[username] ?? const <String, EncryptedRecord>{};
    final staged = Map<String, EncryptedRecord>.of(current);
    var seq = _seq[username] ?? 0;
    var migrated = 0;
    var stale = 0;
    for (final migration in migrations) {
      final existing = staged[migration.expected.id];
      if (existing == null ||
          !sameEncryptedRecord(existing, migration.expected)) {
        stale++;
        continue;
      }

      staged.remove(migration.expected.id);
      final replacement = migration.replacement;
      final target = staged[replacement.id];
      if (target == null ||
          (target.envelopeVersion == kCurrentRecordEnvelopeVersion &&
              identical(Lww.resolve(target, replacement), replacement))) {
        seq++;
        staged[replacement.id] = replacement.withSeq(seq);
      }
      migrated++;
    }

    if (migrated != 0 && quota != null) {
      enforceAccountQuota(
        beforeCount: _liveCount(current.values),
        beforeBytes: _recordBytes(current.values),
        afterCount: _liveCount(staged.values),
        afterBytes: _recordBytes(staged.values),
        quota: quota,
      );
    }
    _records[username] = staged;
    _seq[username] = seq;

    var floor = _recordEnvelopeFloor(username);
    if (finalize &&
        floor < kCurrentRecordEnvelopeVersion &&
        !staged.values.any(
          (record) => record.envelopeVersion != kCurrentRecordEnvelopeVersion,
        )) {
      final account = _accounts[username];
      if (account != null) {
        floor = kCurrentRecordEnvelopeVersion;
        seq++;
        _seq[username] = seq;
        _accounts[username] = account.withRecordEnvelopeFloor(
          floor,
          atSeq: seq,
        );
      }
    }
    return LegacyMigrationResponse(
      migrated: migrated,
      stale: stale,
      latestSeq: seq,
      recordEnvelopeFloor: floor,
    );
  }

  @override
  Future<LegacyMigrationResponse> migrateLegacyRecordsFor(
    AuthPrincipal principal,
    List<LegacyRecordMigration> migrations, {
    required bool finalize,
    AccountQuota? quota,
  }) {
    _requireCurrent(principal);
    return migrateLegacyRecords(
      principal.username,
      migrations,
      finalize: finalize,
      quota: quota,
    );
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
    AuthPrincipal principal,
    StoredInboxApp app, {
    int maxApps = 50,
  }) {
    _requireCurrent(principal);
    if (app.username != principal.username) {
      throw ArgumentError.value(app.username, 'app.username');
    }
    if (_inboxApps.values
            .where((entry) => entry.username == principal.username)
            .length >=
        maxApps) {
      throw const InboxAppLimitException();
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
  Future<bool> deleteInboxAppFor(AuthPrincipal principal, String appId) {
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
    AccountQuota? quota,
    String? expectedGeneration,
    int maxAccountPendingItems = 5000,
    int maxAccountPendingBytes = 32 * 1024 * 1024,
  }) async {
    final app = _inboxApps[appId];
    if (app == null ||
        (expectedGeneration != null && app.tokenSalt != expectedGeneration)) {
      return const InboxAddResult(InboxAddStatus.unknownApp);
    }
    if (_inboxItems.where((i) => i.appId == appId).length >= maxPending) {
      return const InboxAddResult(InboxAddStatus.full);
    }
    final accountItems = _inboxItems.where(
      (item) => item.username == app.username,
    );
    final accountBytes = accountItems.fold<int>(
      0,
      (total, item) => total + item.blob.length,
    );
    if (accountItems.length >= maxAccountPendingItems ||
        accountBytes + blob.length > maxAccountPendingBytes) {
      return const InboxAddResult(InboxAddStatus.accountFull);
    }
    final received = (_inboxReceived[app.username] ?? 0) + 1;
    if (quota != null) {
      final current = [
        for (final item in _inboxItems)
          if (item.username == app.username) item.toItem(),
      ];
      final incoming = InboxItem(
        appId: appId,
        itemId: itemId,
        received: received,
        blob: blob,
      );
      final afterBytes = _inboxBytes(current) + incoming.encodedJsonBytes();
      if (current.length + 1 > quota.maxRecords ||
          afterBytes > quota.maxBytes) {
        return const InboxAddResult(InboxAddStatus.accountFull);
      }
    }
    _inboxReceived[app.username] = received;
    _inboxItems.add(
      _MemoryInboxItem(app.username, appId, itemId, received, blob, storedAt),
    );
    return InboxAddResult(InboxAddStatus.added, received);
  }

  @override
  Future<List<InboxItem>> inboxItemsSince(
    String username,
    int since, {
    int? limit,
  }) async {
    if (limit != null && limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    final result = <InboxItem>[];
    for (final item in _inboxItems) {
      if (item.username != username || item.received <= since) continue;
      result.add(item.toItem());
      if (limit != null && result.length == limit) break;
    }
    return result;
  }

  @override
  Future<InboxPage> inboxPage(
    String username,
    int since, {
    int? throughReceived,
    required PullPageLimits limits,
  }) async {
    final latest = _inboxReceived[username] ?? 0;
    final through = throughReceived ?? latest;
    if (through < since || through > latest) {
      throw const StorageCursorRejectedException();
    }
    final candidates = [
      for (final item in _inboxItems)
        if (item.username == username &&
            item.received > since &&
            item.received <= through)
          item.toItem(),
    ]..sort((a, b) => a.received.compareTo(b.received));
    final items = <InboxItem>[];
    var itemBytes = 0;
    for (final candidate in candidates) {
      if (items.length == limits.maxRecords) break;
      final nextBytes = itemBytes + candidate.encodedJsonBytes();
      final fits =
          InboxPage.bodyBytesFor(
            itemCount: items.length + 1,
            itemBytes: nextBytes,
            throughReceived: through,
            nextReceived: candidate.received,
            hasMore: false,
          ) <=
          limits.maxBodyBytes;
      if (!fits) {
        if (items.isEmpty) throw const StoragePageTooSmallException();
        break;
      }
      items.add(candidate);
      itemBytes = nextBytes;
    }
    final next = items.isEmpty ? since : items.last.received;
    final hasMore = candidates.any((item) => item.received > next);
    return InboxPage(
      items: items,
      throughReceived: through,
      nextReceived: next,
      hasMore: hasMore,
    );
  }

  @override
  Future<List<InboxItem>> inboxItemsSinceFor(
    AuthPrincipal principal,
    int since,
  ) {
    _requireCurrent(principal);
    return inboxItemsSince(principal.username, since);
  }

  @override
  Future<InboxPage> inboxPageFor(
    AuthPrincipal principal,
    int since, {
    int? throughReceived,
    required PullPageLimits limits,
  }) {
    _requireCurrent(principal);
    return inboxPage(
      principal.username,
      since,
      throughReceived: throughReceived,
      limits: limits,
    );
  }

  @override
  Future<bool> deleteInboxItem(
    String username,
    String appId,
    String itemId,
  ) async {
    final before = _inboxItems.length;
    _inboxItems.removeWhere(
      (i) => i.username == username && i.appId == appId && i.itemId == itemId,
    );
    return _inboxItems.length != before;
  }

  @override
  Future<bool> deleteInboxItemFor(
    AuthPrincipal principal,
    String appId,
    String itemId,
  ) {
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
