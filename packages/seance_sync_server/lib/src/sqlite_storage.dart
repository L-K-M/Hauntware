import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'storage.dart';

enum _TransactionMode { read, write }

/// SQLite-backed [Storage] for production. Single file, no server process — the
/// whole deployment is this binary plus a `.sqlite` file. All record blobs are
/// already end-to-end encrypted; this layer only shuffles opaque bytes.
class SqliteStorage implements Storage {
  final Database _connection;
  StorageUnavailableException? _failure;

  SqliteStorage(this._connection) {
    _migrate();
  }

  Database get _db {
    final failure = _failure;
    if (failure != null) throw failure;
    return _connection;
  }

  /// Open (or create) the database at [path]. Use `:memory:` for ephemeral.
  factory SqliteStorage.open(String path) =>
      SqliteStorage(sqlite3.open(path));

  void _migrate() {
    _db.execute('PRAGMA journal_mode=WAL;');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS accounts (
        username TEXT PRIMARY KEY,
        auth_verifier_hash TEXT NOT NULL,
        verifier_salt TEXT NOT NULL,
        argon_salt TEXT NOT NULL,
        argon_params TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tokens (
        token TEXT PRIMARY KEY,
        username TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        username TEXT NOT NULL,
        id TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        deleted INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        blob BLOB NOT NULL,
        PRIMARY KEY (username, id)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS seqs (
        username TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      );
    ''');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS records_seq ON records(username, seq);');
    _migrateInbox();
  }

  /// The command inbox tables (docs/INBOX.md). Created if missing, so a
  /// database from before the inbox gains them on its next open and keeps
  /// everything else untouched. `app_id` alone is the key because the
  /// producer endpoint names only the app. The cascade is the schema's
  /// guarantee that no item outlives its app; foreign keys are off by
  /// default in SQLite and per connection, hence the pragma.
  void _migrateInbox() {
    _db.execute('PRAGMA foreign_keys=ON;');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS inbox_apps (
        app_id TEXT PRIMARY KEY,
        username TEXT NOT NULL,
        name TEXT NOT NULL,
        token_salt TEXT NOT NULL,
        token_hash TEXT NOT NULL,
        created INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS inbox_items (
        app_id TEXT NOT NULL
          REFERENCES inbox_apps(app_id) ON DELETE CASCADE,
        item_id TEXT NOT NULL,
        username TEXT NOT NULL,
        received INTEGER NOT NULL,
        blob BLOB NOT NULL,
        stored_at INTEGER NOT NULL,
        PRIMARY KEY (app_id, item_id)
      );
    ''');
    // Kept apart from `seqs`: record sequence numbers are the sync cursor,
    // and an inbox item must not move it.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS inbox_seqs (
        username TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS inbox_apps_user '
        'ON inbox_apps(username);');
    _db.execute('CREATE INDEX IF NOT EXISTS inbox_items_received '
        'ON inbox_items(username, received);');
    _db.execute('CREATE INDEX IF NOT EXISTS inbox_items_stored '
        'ON inbox_items(stored_at);');
  }

  @override
  Future<Account?> getAccount(String username) async {
    final rows = _db
        .select('SELECT * FROM accounts WHERE username = ?', [username]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Account(
      username: r['username'] as String,
      authVerifierHash: r['auth_verifier_hash'] as String,
      verifierSalt: r['verifier_salt'] as String,
      argonSalt: r['argon_salt'] as String,
      argonParams: Argon2Params.fromJson(
          (jsonDecode(r['argon_params'] as String) as Map).cast()),
    );
  }

  @override
  Future<void> createAccount(Account account) async {
    _db.execute(
      'INSERT INTO accounts (username, auth_verifier_hash, verifier_salt, argon_salt, argon_params) VALUES (?, ?, ?, ?, ?)',
      [
        account.username,
        account.authVerifierHash,
        account.verifierSalt,
        account.argonSalt,
        jsonEncode(account.argonParams.toJson()),
      ],
    );
    _db.execute('INSERT OR IGNORE INTO seqs (username, value) VALUES (?, 0)',
        [account.username]);
  }

  @override
  Future<void> deleteAccount(String username) async {
    // A failed cleanup must not remove the account while leaving usable
    // tokens or encrypted records behind. Reuse the record-write rollback and
    // contention policy so deletion either commits in full or can be retried.
    _transaction(_TransactionMode.write, () {
      _db.execute('DELETE FROM accounts WHERE username = ?', [username]);
      _db.execute('DELETE FROM tokens WHERE username = ?', [username]);
      _db.execute('DELETE FROM records WHERE username = ?', [username]);
      _db.execute('DELETE FROM seqs WHERE username = ?', [username]);
      _db.execute('DELETE FROM inbox_items WHERE username = ?', [username]);
      _db.execute('DELETE FROM inbox_apps WHERE username = ?', [username]);
      _db.execute('DELETE FROM inbox_seqs WHERE username = ?', [username]);
    });
  }

  @override
  Future<String> createToken(String username) async {
    final token = base64Url.encode(secureRandomBytes(32));
    _db.execute('INSERT INTO tokens (token, username) VALUES (?, ?)',
        [token, username]);
    return token;
  }

  @override
  Future<String?> usernameForToken(String token) async {
    final rows =
        _db.select('SELECT username FROM tokens WHERE token = ?', [token]);
    return rows.isEmpty ? null : rows.first['username'] as String;
  }

  @override
  Future<PushResponse> pushRecords(
      String username, List<EncryptedRecord> records) async {
    // A no-op push must not contend with writers.
    final mode = records.isEmpty
        ? _TransactionMode.read
        : _TransactionMode.write;
    return _transaction(mode, () {
      final results = <PushResult>[];
      for (final incoming in records) {
        final existing = _getRecord(username, incoming.id);
        if (existing != null &&
            !identical(Lww.resolve(existing, incoming), incoming)) {
          results.add(PushResult(
              id: incoming.id, seq: existing.seq ?? 0, accepted: false));
          continue;
        }

        final seq = _nextSeq(username);
        _putRecord(username, incoming.withSeq(seq));
        results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
      }
      return PushResponse(results: results, latestSeq: _latestSeq(username));
    });
  }

  @override
  Future<PullResponse> pullSnapshot(String username, int since) async =>
      _transaction(_TransactionMode.read, () {
        final watermark = _latestSeq(username);
        return PullResponse(
          records: _recordsSince(username, since, through: watermark),
          latestSeq: watermark,
        );
      });

  T _transaction<T>(_TransactionMode mode, T Function() action) {
    // No awaits while the connection owns a transaction. Acquire the write
    // lock before comparing LWW so another process cannot commit a stale winner.
    _begin(mode);
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (e) {
      _rollback(e);
      final failure = _failure;
      if (failure != null) throw failure;
      if (_isBusy(e)) throw const StorageBusyException();
      rethrow;
    }
  }

  void _begin(_TransactionMode mode) {
    try {
      _db.execute(mode == _TransactionMode.write ? 'BEGIN IMMEDIATE' : 'BEGIN');
    } on SqliteException catch (e) {
      if (_isBusy(e)) throw const StorageBusyException();
      rethrow;
    }
  }

  static bool _isBusy(Object error) => error is SqliteException &&
      (error.resultCode == SqlError.SQLITE_BUSY ||
          error.resultCode == SqlError.SQLITE_LOCKED);

  static String _diagnosticCause(Object error) => error is SqliteException
      ? 'SQLite ${error.extendedResultCode}'
      : error.runtimeType.toString();

  void _rollback(Object cause) {
    final Object cleanupCause;
    try {
      // SQLite may already have rolled back after a trigger or storage error.
      if (!_db.autocommit) _db.execute('ROLLBACK');
      return;
    } catch (e) {
      cleanupCause = e;
    }

    // Never reuse a connection whose transaction state is uncertain.
    _failure = StorageUnavailableException(cause: cause);
    try {
      // Log types/codes, not SQL, parameters, messages or ciphertext.
      stderr.writeln('Transaction failed (${_diagnosticCause(cause)}); '
          'cleanup failed (${_diagnosticCause(cleanupCause)}). $_failure');
    } catch (_) {
      // Diagnostics must not replace the original failure.
    }

    try {
      _connection.dispose();
    } catch (_) {
      // Preserve the original write/commit failure, not a cleanup exception.
    }
  }

  @override
  Future<EncryptedRecord?> getRecord(String username, String id) async =>
      _getRecord(username, id);

  EncryptedRecord? _getRecord(String username, String id) {
    final rows = _db.select(
        'SELECT * FROM records WHERE username = ? AND id = ?', [username, id]);
    return rows.isEmpty ? null : _rowToRecord(rows.first);
  }

  @override
  Future<void> putRecord(String username, EncryptedRecord record) async =>
      _putRecord(username, record);

  void _putRecord(String username, EncryptedRecord record) {
    _db.execute(
      '''INSERT INTO records (username, id, updated_at, device_id, deleted, seq, blob)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(username, id) DO UPDATE SET
           updated_at=excluded.updated_at, device_id=excluded.device_id,
           deleted=excluded.deleted, seq=excluded.seq, blob=excluded.blob''',
      [
        username,
        record.id,
        record.updatedAt,
        record.deviceId,
        record.deleted ? 1 : 0,
        record.seq ?? 0,
        record.blob,
      ],
    );
  }

  @override
  Future<List<EncryptedRecord>> recordsSince(
          String username, int since) async =>
      _recordsSince(username, since);

  List<EncryptedRecord> _recordsSince(String username, int since,
      {int? through}) {
    final rows = _db.select(
        through == null
            ? 'SELECT * FROM records WHERE username = ? AND seq > ? '
                'ORDER BY seq ASC'
            : 'SELECT * FROM records WHERE username = ? AND seq > ? '
                'AND seq <= ? ORDER BY seq ASC',
        [username, since, if (through != null) through]);
    return rows.map(_rowToRecord).toList();
  }

  @override
  Future<int> nextSeq(String username) async => _nextSeq(username);

  int _nextSeq(String username) {
    _db.execute(
      '''INSERT INTO seqs (username, value) VALUES (?, 1)
         ON CONFLICT(username) DO UPDATE SET value = value + 1''',
      [username],
    );
    final rows =
        _db.select('SELECT value FROM seqs WHERE username = ?', [username]);
    return rows.first['value'] as int;
  }

  @override
  Future<int> latestSeq(String username) async => _latestSeq(username);

  int _latestSeq(String username) {
    final rows =
        _db.select('SELECT value FROM seqs WHERE username = ?', [username]);
    return rows.isEmpty ? 0 : rows.first['value'] as int;
  }

  EncryptedRecord _rowToRecord(Row r) => EncryptedRecord(
        id: r['id'] as String,
        updatedAt: r['updated_at'] as int,
        deviceId: r['device_id'] as String,
        deleted: (r['deleted'] as int) != 0,
        seq: r['seq'] as int,
        blob: _blobOf(r),
      );

  static Uint8List _blobOf(Row r) => r['blob'] is Uint8List
      ? r['blob'] as Uint8List
      : Uint8List.fromList((r['blob'] as List).cast<int>());

  @override
  Future<bool> createInboxApp(StoredInboxApp app) async =>
      _transaction(_TransactionMode.write, () {
        _db.execute(
          'INSERT OR IGNORE INTO inbox_apps (app_id, username, name, '
          'token_salt, token_hash, created) VALUES (?, ?, ?, ?, ?, ?)',
          [
            app.appId,
            app.username,
            app.name,
            app.tokenSalt,
            app.tokenHash,
            app.created,
          ],
        );
        return _db.updatedRows == 1;
      });

  @override
  Future<StoredInboxApp?> getInboxApp(String appId) async {
    final rows =
        _db.select('SELECT * FROM inbox_apps WHERE app_id = ?', [appId]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return StoredInboxApp(
      username: r['username'] as String,
      appId: r['app_id'] as String,
      name: r['name'] as String,
      tokenHash: r['token_hash'] as String,
      tokenSalt: r['token_salt'] as String,
      created: r['created'] as int,
    );
  }

  @override
  Future<List<InboxAppInfo>> listInboxApps(String username) async {
    final rows = _db.select(
      'SELECT a.app_id, a.name, a.created, '
      '(SELECT COUNT(*) FROM inbox_items i WHERE i.app_id = a.app_id) '
      'AS pending FROM inbox_apps a WHERE a.username = ? '
      'ORDER BY a.created ASC, a.app_id ASC',
      [username],
    );
    return [
      for (final r in rows)
        InboxAppInfo(
          appId: r['app_id'] as String,
          name: r['name'] as String,
          created: r['created'] as int,
          pending: r['pending'] as int,
        ),
    ];
  }

  @override
  Future<bool> deleteInboxApp(String username, String appId) async =>
      _transaction(_TransactionMode.write, () {
        // Explicit as well as cascaded, so the items go even on a
        // connection that was opened without the foreign-key pragma.
        _db.execute(
          'DELETE FROM inbox_items WHERE app_id = ? AND username = ?',
          [appId, username],
        );
        _db.execute(
          'DELETE FROM inbox_apps WHERE app_id = ? AND username = ?',
          [appId, username],
        );
        return _db.updatedRows == 1;
      });

  @override
  Future<InboxAddResult> addInboxItem(
    String appId,
    String itemId,
    Uint8List blob, {
    required int storedAt,
    required int maxPending,
  }) async =>
      // One write transaction, so two concurrent deposits cannot both pass
      // the pending cap or draw the same `received` number.
      _transaction(_TransactionMode.write, () {
        final apps = _db.select(
            'SELECT username FROM inbox_apps WHERE app_id = ?', [appId]);
        if (apps.isEmpty) {
          return const InboxAddResult(InboxAddStatus.unknownApp);
        }
        final username = apps.first['username'] as String;
        final pending = _db.select(
            'SELECT COUNT(*) AS n FROM inbox_items WHERE app_id = ?',
            [appId]).first['n'] as int;
        if (pending >= maxPending) {
          return const InboxAddResult(InboxAddStatus.full);
        }
        _db.execute(
          'INSERT INTO inbox_seqs (username, value) VALUES (?, 1) '
          'ON CONFLICT(username) DO UPDATE SET value = value + 1',
          [username],
        );
        final received = _db.select(
            'SELECT value FROM inbox_seqs WHERE username = ?',
            [username]).first['value'] as int;
        _db.execute(
          'INSERT INTO inbox_items (app_id, item_id, username, received, '
          'blob, stored_at) VALUES (?, ?, ?, ?, ?, ?)',
          [appId, itemId, username, received, blob, storedAt],
        );
        return InboxAddResult(InboxAddStatus.added, received);
      });

  @override
  Future<List<InboxItem>> inboxItemsSince(String username, int since) async {
    final rows = _db.select(
      'SELECT app_id, item_id, received, blob FROM inbox_items '
      'WHERE username = ? AND received > ? ORDER BY received ASC',
      [username, since],
    );
    return [
      for (final r in rows)
        InboxItem(
          appId: r['app_id'] as String,
          itemId: r['item_id'] as String,
          received: r['received'] as int,
          blob: _blobOf(r),
        ),
    ];
  }

  @override
  Future<bool> deleteInboxItem(
      String username, String appId, String itemId) async {
    _db.execute(
      'DELETE FROM inbox_items WHERE username = ? AND app_id = ? '
      'AND item_id = ?',
      [username, appId, itemId],
    );
    return _db.updatedRows == 1;
  }

  @override
  Future<int> purgeInboxItems({required int storedBefore}) async {
    _db.execute(
        'DELETE FROM inbox_items WHERE stored_at < ?', [storedBefore]);
    return _db.updatedRows;
  }

  void close() => _connection.dispose();
}
