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

/// Per-account bounds for the current winning record set.
final class AccountQuota {
  const AccountQuota({
    this.maxRecords = 100000,
    this.maxBytes = 1024 * 1024 * 1024,
  });

  final int maxRecords;
  final int maxBytes;
}

/// A push would grow an account farther beyond one of its storage caps.
class AccountQuotaExceededException implements Exception {
  const AccountQuotaExceededException();
}

/// An accepted push record could not be returned under the pull body cap.
class PushRecordTooLargeException implements Exception {
  const PushRecordTooLargeException(this.id);

  final String id;
}

/// A legacy stored row cannot fit in even an otherwise empty pull page.
class StoredPullRecordTooLargeException implements Exception {
  const StoredPullRecordTooLargeException(this.id);

  final String id;
}

/// The requested cursor is ahead of this account's current sequence stream.
class PullCursorRejectedException implements Exception {
  const PullCursorRejectedException();
}

/// Server-specific bounds and metadata included in every pull page.
final class PullPageOptions {
  const PullPageOptions({
    required this.maxRecords,
    required this.maxBodyBytes,
    required this.pushLimits,
    required this.recordEnvelopeVersion,
  });

  final int maxRecords;
  final int maxBodyBytes;
  final PushLimits pushLimits;
  final int recordEnvelopeVersion;
}

const int _maxStoredSequence = 9223372036854775807;

/// Reject a deployment that cannot emit even an empty, fenced response.
void validatePullPageOptions(
  PullPageOptions options, {
  String bodyLimitName = 'maxBodyBytes',
}) {
  if (options.maxRecords <= 0) {
    throw ArgumentError.value(
      options.maxRecords,
      'maxRecords',
      'must be a positive integer',
    );
  }
  final minimumBodyBytes = _finalPullPage(
    const [],
    _maxStoredSequence,
    options,
  ).encodedSizeBytes();
  if (options.maxBodyBytes < minimumBodyBytes) {
    throw ArgumentError.value(
      options.maxBodyBytes,
      bodyLimitName,
      'must be at least $minimumBodyBytes bytes for pull metadata',
    );
  }
}

/// Whether [record] can always travel alone under [options].
bool recordFitsPullPage(EncryptedRecord record, PullPageOptions options) {
  final sequenced = record.withSeq(_maxStoredSequence - 1);
  return PullResponse(
        records: [sequenced],
        latestSeq: _maxStoredSequence - 1,
        limits: options.pushLimits,
        recordEnvelopeVersion: options.recordEnvelopeVersion,
        through: _maxStoredSequence,
        nextSince: _maxStoredSequence - 1,
      ).encodedSizeBytes() <=
      options.maxBodyBytes;
}

/// Fill one pull page from an ascending, fence-bounded record iterable.
PullResponse buildPullPage(
  Iterable<EncryptedRecord> candidates, {
  required int since,
  required int through,
  required PullPageOptions options,
}) {
  validatePullPageOptions(options);
  final selected = <EncryptedRecord>[];
  final iterator = candidates.iterator;
  var hasCurrent = iterator.moveNext();
  var previousSeq = since;
  var selectedBytes = 0;

  while (hasCurrent) {
    final current = iterator.current;
    final seq = current.seq;
    if (seq == null || seq <= previousSeq || seq > through) {
      throw StateError('Storage returned an invalid pull sequence');
    }
    final hasFollowing = iterator.moveNext();

    if (selected.length >= options.maxRecords) {
      return _intermediatePullPage(selected, through, options);
    }

    final currentBytes = current.encodedJsonBytes();
    final candidateBytes = PullResponse.bodyBytesFor(
      recordCount: selected.length + 1,
      recordBytes: selectedBytes + currentBytes,
      latestSeq: hasFollowing ? seq : through,
      limits: options.pushLimits,
      recordEnvelopeVersion: options.recordEnvelopeVersion,
      through: through,
      nextSince: hasFollowing ? seq : null,
    );
    if (candidateBytes > options.maxBodyBytes) {
      if (selected.isEmpty) {
        throw StoredPullRecordTooLargeException(current.id);
      }
      return _intermediatePullPage(selected, through, options);
    }

    selected.add(current);
    selectedBytes += currentBytes;
    previousSeq = seq;
    if (!hasFollowing) return _finalPullPage(selected, through, options);
    if (selected.length == options.maxRecords) {
      return _intermediatePullPage(selected, through, options);
    }
    hasCurrent = true;
  }

  final response = _finalPullPage(selected, through, options);
  if (response.encodedSizeBytes() > options.maxBodyBytes) {
    throw const StoredPullRecordTooLargeException('<response metadata>');
  }
  return response;
}

PullResponse _intermediatePullPage(
  List<EncryptedRecord> records,
  int through,
  PullPageOptions options,
) {
  final next = records.last.seq!;
  return PullResponse(
    records: List.unmodifiable(records),
    latestSeq: next,
    limits: options.pushLimits,
    recordEnvelopeVersion: options.recordEnvelopeVersion,
    through: through,
    nextSince: next,
  );
}

PullResponse _finalPullPage(
  List<EncryptedRecord> records,
  int through,
  PullPageOptions options,
) =>
    PullResponse(
      records: List.unmodifiable(records),
      latestSeq: through,
      limits: options.pushLimits,
      recordEnvelopeVersion: options.recordEnvelopeVersion,
      through: through,
    );

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
    String username,
    List<EncryptedRecord> records, {
    AccountQuota quota = const AccountQuota(),
    PullPageOptions? pullOptions,
  });

  /// Return one bounded page under a stable account watermark.
  Future<PullResponse> pullPage(
    String username,
    int since, {
    int? through,
    required PullPageOptions options,
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

/// Compatibility helper for storage-focused tests and tools that need an
/// unbounded logical snapshot without going through HTTP.
extension StorageSnapshotCompatibility on Storage {
  Future<PullResponse> pullSnapshot(String username, int since) => pullPage(
        username,
        since,
        options: const PullPageOptions(
          maxRecords: 1000000,
          maxBodyBytes: 1024 * 1024 * 1024,
          pushLimits: PushLimits(),
          recordEnvelopeVersion: kRecordEnvelopeVersion,
        ),
      );
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
  final Map<String, int> _recordCounts = {};
  final Map<String, int> _recordBytes = {};
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
    _recordCounts[account.username] = 0;
    _recordBytes[account.username] = 0;
  }

  @override
  Future<void> deleteAccount(String username) async {
    _accounts.remove(username);
    _records.remove(username);
    _seq.remove(username);
    _recordCounts.remove(username);
    _recordBytes.remove(username);
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
    String username,
    List<EncryptedRecord> records, {
    AccountQuota quota = const AccountQuota(),
    PullPageOptions? pullOptions,
  }) async {
    // Stage without awaits so failures and concurrent requests see no partial batch.
    final staged = Map<String, EncryptedRecord>.of(_records[username] ?? {});
    final int initialCount = _recordCounts[username] ?? staged.length;
    final int initialBytes = _recordBytes[username] ??
        staged.values.fold<int>(
            0, (sum, record) => sum + record.encodedJsonBytes());
    var count = initialCount;
    var bytes = initialBytes;
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
      final stored = incoming.withSeq(seq);
      if (pullOptions != null && !recordFitsPullPage(stored, pullOptions)) {
        throw PushRecordTooLargeException(incoming.id);
      }
      if (existing == null) count++;
      bytes += stored.encodedJsonBytes() -
          (existing?.encodedJsonBytes() ?? 0);
      staged[incoming.id] = stored;
      results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
    }

    final growsPastRecordCap =
        count > quota.maxRecords && count > initialCount;
    final growsPastByteCap = bytes > quota.maxBytes && bytes > initialBytes;
    if (growsPastRecordCap || growsPastByteCap) {
      throw const AccountQuotaExceededException();
    }

    _records[username] = staged;
    _seq[username] = seq;
    _recordCounts[username] = count;
    _recordBytes[username] = bytes;
    return PushResponse(results: results, latestSeq: seq);
  }

  @override
  Future<PullResponse> pullPage(
    String username,
    int since, {
    int? through,
    required PullPageOptions options,
  }) async {
    // Copy the rows and watermark in one synchronous turn.
    final watermark = _seq[username] ?? 0;
    if (since < 0 || (through != null && through < since)) {
      throw ArgumentError('Invalid pull cursor');
    }
    if (since > watermark || (through != null && through > watermark)) {
      throw const PullCursorRejectedException();
    }
    final fence = through ?? watermark;
    final records = (_records[username]?.values ?? const <EncryptedRecord>[])
        .where((r) => (r.seq ?? 0) > since && (r.seq ?? 0) <= fence)
        .toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return buildPullPage(
      records,
      since: since,
      through: fence,
      options: options,
    );
  }

  @override
  Future<EncryptedRecord?> getRecord(String username, String id) async =>
      _records[username]?[id];

  @override
  Future<void> putRecord(String username, EncryptedRecord record) async {
    final records = _records[username] ??= {};
    final prior = records[record.id];
    records[record.id] = record;
    _recordCounts[username] = records.length;
    _recordBytes[username] = (_recordBytes[username] ?? 0) +
        record.encodedJsonBytes() -
        (prior?.encodedJsonBytes() ?? 0);
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
