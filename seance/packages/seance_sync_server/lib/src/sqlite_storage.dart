import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'legacy_migration_validation.dart';
import 'record_quota.dart';
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
  factory SqliteStorage.open(String path) => SqliteStorage(sqlite3.open(path));

  @override
  Future<void> checkReady() async {
    try {
      _db.select('PRAGMA schema_version');
    } on StorageUnavailableException {
      rethrow;
    } catch (error) {
      if (_isBusy(error)) throw const StorageBusyException();
      throw StorageUnavailableException(cause: error);
    }
  }

  void _migrate() {
    _db.execute('PRAGMA journal_mode=WAL;');
    _db.execute('BEGIN IMMEDIATE;');
    try {
      _db.execute('''
      CREATE TABLE IF NOT EXISTS accounts (
        username TEXT PRIMARY KEY,
        generation TEXT NOT NULL,
        auth_verifier_hash TEXT NOT NULL,
        verifier_salt TEXT NOT NULL,
        argon_salt TEXT NOT NULL,
        argon_params TEXT NOT NULL,
        vault_key_check TEXT,
        record_envelope_floor INTEGER NOT NULL DEFAULT 2
          CHECK(record_envelope_floor IN (1, 2)),
        record_envelope_floor_seq INTEGER NOT NULL DEFAULT 0
      );
    ''');
      final accountColumns = _db
          .select('PRAGMA table_info(accounts)')
          .map((row) => row['name'])
          .toSet();
      if (!accountColumns.contains('vault_key_check')) {
        _db.execute('ALTER TABLE accounts ADD COLUMN vault_key_check TEXT;');
      }
      if (!accountColumns.contains('generation')) {
        _db.execute('ALTER TABLE accounts ADD COLUMN generation TEXT;');
      }
      if (!accountColumns.contains('record_envelope_floor')) {
        // Every account predating the authenticated-envelope checkpoint may
        // still contain v1 rows. New accounts are inserted explicitly at 2.
        _db.execute(
          'ALTER TABLE accounts ADD COLUMN record_envelope_floor '
          'INTEGER NOT NULL DEFAULT 1 '
          'CHECK(record_envelope_floor IN (1, 2));',
        );
      }
      if (!accountColumns.contains('record_envelope_floor_seq')) {
        _db.execute(
          'ALTER TABLE accounts ADD COLUMN record_envelope_floor_seq '
          'INTEGER NOT NULL DEFAULT 0;',
        );
      }
      final missingGenerations = _db.select(
        'SELECT username FROM accounts WHERE generation IS NULL '
        "OR generation = ''",
      );
      for (final row in missingGenerations) {
        _db.execute('UPDATE accounts SET generation = ? WHERE username = ?', [
          base64Url.encode(secureRandomBytes(16)),
          row['username'],
        ]);
      }
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS accounts_generation_required_insert
        BEFORE INSERT ON accounts
        WHEN NEW.generation IS NULL OR NEW.generation = ''
        BEGIN SELECT RAISE(ABORT, 'account generation required'); END;
      ''');
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS accounts_generation_required_update
        BEFORE UPDATE OF generation ON accounts
        WHEN NEW.generation IS NULL OR NEW.generation = ''
        BEGIN SELECT RAISE(ABORT, 'account generation required'); END;
      ''');
      final tokenTable = _db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'tokens'",
      );
      if (tokenTable.isNotEmpty) {
        final tokenColumns = _db
            .select('PRAGMA table_info(tokens)')
            .map((row) => row['name'])
            .toSet();
        if (!tokenColumns.contains('token_digest') ||
            !tokenColumns.contains('account_generation') ||
            !tokenColumns.contains('issued_at') ||
            !tokenColumns.contains('expires_at')) {
          // Legacy rows contain permanent bearer secrets in plaintext. They
          // cannot be upgraded safely, so require one fresh login after update.
          _db.execute('DROP TABLE tokens;');
        }
      }
      _db.execute('''
      CREATE TABLE IF NOT EXISTS tokens (
        token_digest TEXT PRIMARY KEY,
        session_id TEXT NOT NULL UNIQUE,
        username TEXT NOT NULL,
        account_generation TEXT NOT NULL,
        issued_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        last_used_at INTEGER NOT NULL,
        device_id TEXT,
        device_name TEXT NOT NULL DEFAULT 'Unknown device'
      );
    ''');
      final sessionColumns = _db
          .select('PRAGMA table_info(tokens)')
          .map((row) => row['name'])
          .toSet();
      for (final column in {
        'session_id': 'TEXT',
        'last_used_at': 'INTEGER',
        'device_id': 'TEXT',
        'device_name': "TEXT NOT NULL DEFAULT 'Unknown device'",
      }.entries) {
        if (!sessionColumns.contains(column.key)) {
          _db.execute(
            'ALTER TABLE tokens ADD COLUMN ${column.key} ${column.value}',
          );
        }
      }
      // Existing hashed sessions remain valid but have no installation label.
      // Plaintext rows were invalidated above, never grandfathered here.
      while (true) {
        final rows = _db.select(
          "SELECT token_digest FROM tokens WHERE session_id IS NULL OR session_id = '' LIMIT 1",
        );
        if (rows.isEmpty) break;
        _db.execute('UPDATE tokens SET session_id = ? WHERE token_digest = ?', [
          newSessionId(),
          rows.single['token_digest'],
        ]);
      }
      _db.execute(
        'UPDATE tokens SET last_used_at = issued_at WHERE last_used_at IS NULL',
      );
      _db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS tokens_session_id ON tokens(session_id)',
      );
      _db.execute(
        'CREATE INDEX IF NOT EXISTS tokens_account_issued '
        'ON tokens(username, account_generation, issued_at);',
      );
      _db.execute('COMMIT;');
    } catch (_) {
      if (!_db.autocommit) _db.execute('ROLLBACK;');
      rethrow;
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        username TEXT NOT NULL,
        id TEXT NOT NULL,
        envelope_version INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        deleted INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        blob BLOB NOT NULL,
        encoded_size INTEGER NOT NULL,
        PRIMARY KEY (username, id)
      );
    ''');
    final recordColumns = _db
        .select('PRAGMA table_info(records)')
        .map((row) => row['name'])
        .toSet();
    if (!recordColumns.contains('envelope_version')) {
      // Rows written before protocol v3 are legacy v1 even when their blob
      // happens to contain a newer-looking payload. Never infer trust from
      // ciphertext the server cannot authenticate.
      _db.execute(
        'ALTER TABLE records ADD COLUMN envelope_version '
        'INTEGER NOT NULL DEFAULT 1;',
      );
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS seqs (
        username TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS records_seq ON records(username, seq);',
    );
    _migrateInbox();
    _migrateEncodedSizes();
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
        encoded_size INTEGER NOT NULL,
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
    _db.execute(
      'CREATE INDEX IF NOT EXISTS inbox_apps_user '
      'ON inbox_apps(username);',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS inbox_items_received '
      'ON inbox_items(username, received);',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS inbox_items_stored '
      'ON inbox_items(stored_at);',
    );
  }

  void _migrateEncodedSizes() {
    void addIfMissing(String table) {
      final columns = _db.select('PRAGMA table_info($table)');
      if (columns.any((row) => row['name'] == 'encoded_size')) return;
      _db.execute('ALTER TABLE $table ADD COLUMN encoded_size INTEGER');
    }

    /// Return one row after [rowId]. Reading one ciphertext at a time keeps a
    /// pre-quota database from being materialized in memory during startup.
    Row? nextRow(String selection, int? rowId) {
      final rows = _db.select(
        '$selection ${rowId == null ? '' : 'AND rowid > ? '} '
        'ORDER BY rowid LIMIT 1',
        [?rowId],
      );
      return rows.isEmpty ? null : rows.single;
    }

    _db.execute('BEGIN IMMEDIATE;');
    try {
      addIfMissing('records');
      addIfMissing('inbox_items');

      int? recordRowId;
      while (true) {
        final row = nextRow(
          'SELECT rowid AS migration_rowid, * FROM records '
          'WHERE encoded_size IS NULL',
          recordRowId,
        );
        if (row == null) break;
        recordRowId = row['migration_rowid'] as int;
        _db.execute('UPDATE records SET encoded_size = ? WHERE rowid = ?', [
          _rowToRecord(row).encodedJsonBytes(),
          recordRowId,
        ]);
      }

      int? inboxRowId;
      while (true) {
        final row = nextRow(
          'SELECT rowid AS migration_rowid, app_id, item_id, received, blob '
          'FROM inbox_items WHERE encoded_size IS NULL',
          inboxRowId,
        );
        if (row == null) break;
        inboxRowId = row['migration_rowid'] as int;
        final item = InboxItem(
          appId: row['app_id'] as String,
          itemId: row['item_id'] as String,
          received: row['received'] as int,
          blob: _blobOf(row),
        );
        _db.execute('UPDATE inbox_items SET encoded_size = ? WHERE rowid = ?', [
          item.encodedJsonBytes(),
          inboxRowId,
        ]);
      }

      _db.execute('COMMIT;');
    } catch (_) {
      if (!_db.autocommit) _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<Account?> getAccount(String username) async {
    final rows = _db.select('SELECT * FROM accounts WHERE username = ?', [
      username,
    ]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Account(
      username: r['username'] as String,
      generation: r['generation'] as String,
      authVerifierHash: r['auth_verifier_hash'] as String,
      verifierSalt: r['verifier_salt'] as String,
      argonSalt: r['argon_salt'] as String,
      argonParams: Argon2Params.fromJson(
        (jsonDecode(r['argon_params'] as String) as Map).cast(),
      ),
      vaultKeyCheck: r['vault_key_check'] as String?,
      recordEnvelopeFloor: r['record_envelope_floor'] as int,
      recordEnvelopeFloorSeq: r['record_envelope_floor_seq'] as int,
    );
  }

  @override
  Future<void> createAccount(Account account) async {
    _insertAccount(account);
  }

  void _insertAccount(Account account) {
    _db.execute(
      'INSERT INTO accounts (username, generation, auth_verifier_hash, '
      'verifier_salt, argon_salt, argon_params, vault_key_check, '
      'record_envelope_floor, record_envelope_floor_seq) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        account.username,
        account.generation,
        account.authVerifierHash,
        account.verifierSalt,
        account.argonSalt,
        jsonEncode(account.argonParams.toJson()),
        account.vaultKeyCheck,
        account.recordEnvelopeFloor,
        account.recordEnvelopeFloorSeq,
      ],
    );
    _db.execute('INSERT OR IGNORE INTO seqs (username, value) VALUES (?, 0)', [
      account.username,
    ]);
  }

  @override
  Future<void> deleteAccount(String username) async {
    // A failed cleanup must not remove the account while leaving usable
    // tokens or encrypted records behind. Reuse the record-write rollback and
    // contention policy so deletion either commits in full or can be retried.
    _transaction(_TransactionMode.write, () {
      _deleteAccountRows(username);
    });
  }

  void _deleteAccountRows(String username) {
    _db.execute('DELETE FROM accounts WHERE username = ?', [username]);
    _db.execute('DELETE FROM tokens WHERE username = ?', [username]);
    _db.execute('DELETE FROM records WHERE username = ?', [username]);
    _db.execute('DELETE FROM seqs WHERE username = ?', [username]);
    _db.execute('DELETE FROM inbox_items WHERE username = ?', [username]);
    _db.execute('DELETE FROM inbox_apps WHERE username = ?', [username]);
    _db.execute('DELETE FROM inbox_seqs WHERE username = ?', [username]);
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
    return _transaction(_TransactionMode.write, () {
      if (_accountGeneration(account.username) != null) return null;
      _deleteAccountRows(account.username);
      _insertAccount(account);
      return _issueToken(
        account,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        maxSessions: maxSessions,
        device: device,
      );
    });
  }

  @override
  Future<String> createToken(String username) async {
    final account = await getAccount(username);
    if (account == null) throw const StalePrincipalException();
    return _transaction(
      _TransactionMode.write,
      () => _issueToken(
        account,
        issuedAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: 0x7fffffffffffffff,
        maxSessions: 0x7fffffff,
      ),
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
    validateSessionPolicy(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
      device: device,
    );
    return _transaction(_TransactionMode.write, () {
      if (_accountGeneration(account.username) != account.generation) {
        return null;
      }
      return _issueToken(
        account,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        maxSessions: maxSessions,
        device: device,
      );
    });
  }

  String _issueToken(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
    SessionDevice? device,
  }) {
    _db.execute(
      'DELETE FROM tokens WHERE username = ? AND account_generation = ? '
      'AND expires_at <= ?',
      [account.username, account.generation, issuedAt],
    );
    if (device != null) {
      _db.execute(
        'DELETE FROM tokens WHERE username = ? AND account_generation = ? AND device_id = ?',
        [account.username, account.generation, device.id],
      );
    }
    final sessions = _db.select(
      'SELECT token_digest FROM tokens WHERE username = ? '
      'AND account_generation = ? ORDER BY last_used_at ASC, issued_at ASC, session_id ASC',
      [account.username, account.generation],
    );
    for (var i = 0; i <= sessions.length - maxSessions; i++) {
      _db.execute('DELETE FROM tokens WHERE token_digest = ?', [
        sessions[i]['token_digest'],
      ]);
    }
    while (true) {
      final token = base64Url.encode(secureRandomBytes(32));
      final digest = digestBearerToken(token);
      _db.execute(
        'INSERT OR IGNORE INTO tokens (token_digest, username, '
        'account_generation, issued_at, expires_at, session_id, last_used_at, '
        'device_id, device_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          digest,
          account.username,
          account.generation,
          issuedAt,
          expiresAt,
          newSessionId(),
          issuedAt,
          device?.id,
          device?.name ?? 'Unknown device',
        ],
      );
      if (_db.updatedRows == 1) return token;
    }
  }

  @override
  Future<AuthPrincipal?> principalForToken(
    String token, {
    required int now,
  }) async {
    final digest = digestBearerToken(token);
    final rows = _db.select(
      'SELECT t.username, t.account_generation, t.expires_at, t.last_used_at '
      'FROM tokens t JOIN accounts a ON a.username = t.username '
      'AND a.generation = t.account_generation WHERE t.token_digest = ?',
      [digest],
    );
    if (rows.isEmpty || (rows.first['expires_at'] as int) <= now) return null;
    if ((rows.first['last_used_at'] as int) <=
        now - const Duration(hours: 1).inMilliseconds) {
      _transaction(_TransactionMode.write, () {
        _db.execute(
          'UPDATE tokens SET last_used_at = ? WHERE token_digest = ? '
          'AND account_generation = ? AND expires_at > ?',
          [now, digest, rows.first['account_generation'], now],
        );
      });
    }
    return AuthPrincipal(
      username: rows.first['username'] as String,
      accountGeneration: rows.first['account_generation'] as String,
      tokenDigest: digest,
    );
  }

  String? _accountGeneration(String username) {
    final rows = _db.select(
      'SELECT generation FROM accounts WHERE username = ?',
      [username],
    );
    return rows.isEmpty ? null : rows.first['generation'] as String;
  }

  int _recordEnvelopeFloor(String username, [int? throughSeq]) {
    final rows = _db.select(
      'SELECT record_envelope_floor, record_envelope_floor_seq '
      'FROM accounts WHERE username = ?',
      [username],
    );
    if (rows.isEmpty) return kLegacyRecordEnvelopeVersion;
    final row = rows.single;
    final floor = row['record_envelope_floor'] as int;
    final checkpoint = row['record_envelope_floor_seq'] as int;
    if (floor == kCurrentRecordEnvelopeVersion &&
        throughSeq != null &&
        throughSeq < checkpoint) {
      return kLegacyRecordEnvelopeVersion;
    }
    return floor;
  }

  bool _isCurrent(AuthPrincipal principal) {
    final rows = _db.select(
      'SELECT 1 FROM accounts a JOIN tokens t ON t.username = a.username '
      'AND t.account_generation = a.generation WHERE a.username = ? '
      'AND a.generation = ? AND t.token_digest = ?',
      [principal.username, principal.accountGeneration, principal.tokenDigest],
    );
    return rows.isNotEmpty;
  }

  void _requireCurrent(AuthPrincipal principal) {
    if (!_isCurrent(principal)) throw const StalePrincipalException();
  }

  @override
  Future<bool> revokeSession(AuthPrincipal principal) async =>
      _transaction(_TransactionMode.write, () {
        if (!_isCurrent(principal)) return false;
        _db.execute('DELETE FROM tokens WHERE token_digest = ?', [
          principal.tokenDigest,
        ]);
        return _db.updatedRows == 1;
      });

  @override
  Future<bool> revokeAllSessions(AuthPrincipal principal) async =>
      _transaction(_TransactionMode.write, () {
        if (!_isCurrent(principal)) return false;
        _db.execute(
          'DELETE FROM tokens WHERE username = ? AND account_generation = ?',
          [principal.username, principal.accountGeneration],
        );
        return true;
      });

  void _requireSessionAt(AuthPrincipal principal, int now) {
    _requireCurrent(principal);
    final rows = _db.select(
      'SELECT expires_at FROM tokens WHERE token_digest = ?',
      [principal.tokenDigest],
    );
    if ((rows.single['expires_at'] as int) <= now) {
      throw const StalePrincipalException();
    }
  }

  @override
  Future<List<SyncSessionInfo>> listSessionsFor(
    AuthPrincipal principal, {
    required int now,
  }) async => _transaction(_TransactionMode.write, () {
    _requireSessionAt(principal, now);
    _db.execute(
      'DELETE FROM tokens WHERE username = ? AND account_generation = ? AND expires_at <= ?',
      [principal.username, principal.accountGeneration, now],
    );
    final rows = _db.select(
      'SELECT * FROM tokens WHERE username = ? AND account_generation = ? '
      'ORDER BY last_used_at DESC, issued_at DESC, session_id ASC',
      [principal.username, principal.accountGeneration],
    );
    return [
      for (final row in rows)
        SyncSessionInfo(
          id: row['session_id'] as String,
          deviceId: row['device_id'] as String?,
          deviceName: row['device_name'] as String,
          createdAt: row['issued_at'] as int,
          expiresAt: row['expires_at'] as int,
          lastUsedAt: row['last_used_at'] as int,
          legacy: row['device_id'] == null,
          current: row['token_digest'] == principal.tokenDigest,
        ),
    ];
  });

  @override
  Future<RevokeSessionResponse> revokeSessionByIdFor(
    AuthPrincipal principal,
    String sessionId, {
    required int now,
  }) async => _transaction(_TransactionMode.write, () {
    _requireSessionAt(principal, now);
    final rows = _db.select(
      'SELECT token_digest FROM tokens WHERE session_id = ? '
      'AND username = ? AND account_generation = ? AND expires_at > ?',
      [sessionId, principal.username, principal.accountGeneration, now],
    );
    if (rows.isEmpty) {
      return const RevokeSessionResponse(revoked: false, current: false);
    }
    final digest = rows.single['token_digest'] as String;
    _db.execute('DELETE FROM tokens WHERE token_digest = ?', [digest]);
    return RevokeSessionResponse(
      revoked: true,
      current: digest == principal.tokenDigest,
    );
  });

  @override
  Future<bool> deleteAccountFor(AuthPrincipal principal) async =>
      _transaction(_TransactionMode.write, () {
        if (!_isCurrent(principal)) return false;
        _deleteAccountRows(principal.username);
        return true;
      });

  @override
  Future<String> initializeVaultKeyCheckFor(
    AuthPrincipal principal,
    String vaultKeyCheck,
  ) async => _transaction(_TransactionMode.write, () {
    _requireCurrent(principal);
    final rows = _db.select(
      'SELECT vault_key_check FROM accounts WHERE username = ? '
      'AND generation = ?',
      [principal.username, principal.accountGeneration],
    );
    final existing = rows.single['vault_key_check'] as String?;
    if (existing != null) return existing;
    final recordCount =
        _db.select('SELECT COUNT(*) AS n FROM records WHERE username = ?', [
              principal.username,
            ]).single['n']
            as int;
    if (recordCount != 0) {
      throw const VaultKeyCheckInitializationException();
    }
    _db.execute(
      'UPDATE accounts SET vault_key_check = ? WHERE username = ? '
      'AND generation = ? AND vault_key_check IS NULL',
      [vaultKeyCheck, principal.username, principal.accountGeneration],
    );
    if (_db.updatedRows == 1) return vaultKeyCheck;
    final winner =
        _db.select(
              'SELECT vault_key_check FROM accounts WHERE username = ? '
              'AND generation = ?',
              [principal.username, principal.accountGeneration],
            ).single['vault_key_check']
            as String?;
    if (winner == null) throw const StalePrincipalException();
    return winner;
  });

  @override
  Future<PushResponse> pushRecords(
    String username,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
    PushRefusalScope refusalScope = PushRefusalScope.batch,
  }) async {
    // A no-op push must not contend with writers.
    final mode = records.isEmpty
        ? _TransactionMode.read
        : _TransactionMode.write;
    return _transaction(
      mode,
      () => _pushRecords(
        username,
        records,
        quota: quota,
        refusalScope: refusalScope,
      ),
    );
  }

  /// Runs inside the caller's transaction. Under [PushRefusalScope.record]
  /// the whole batch is tried first behind a savepoint, so a batch that fits
  /// commits exactly as a batch-scoped one does.
  PushResponse _pushRecords(
    String username,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
    required PushRefusalScope refusalScope,
  }) {
    if (quota == null || refusalScope == PushRefusalScope.batch) {
      return _pushBatch(username, records, quota: quota);
    }
    _db.execute('SAVEPOINT $_wholeBatchSavepoint');
    try {
      final whole = _pushBatch(username, records, quota: quota);
      _db.execute('RELEASE $_wholeBatchSavepoint');
      return whole;
    } on AccountQuotaExceededException {
      _db.execute('ROLLBACK TO $_wholeBatchSavepoint');
      _db.execute('RELEASE $_wholeBatchSavepoint');
    }
    return _pushEachRecord(username, records, quota: quota);
  }

  static const _wholeBatchSavepoint = 'push_whole_batch';

  PushResponse _pushBatch(
    String username,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
  }) {
    final before = quota == null ? null : _recordUsage(username);
    final results = <PushResult>[];
    var changed = false;
    for (final incoming in records) {
      final existing = _getRecord(username, incoming.id);
      if (existing != null &&
          !identical(Lww.resolve(existing, incoming), incoming)) {
        results.add(
          PushResult(id: incoming.id, seq: existing.seq ?? 0, accepted: false),
        );
        continue;
      }

      final seq = _nextSeq(username);
      _putRecord(username, incoming.withSeq(seq));
      results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
      changed = true;
    }
    if (changed && quota != null) {
      final after = _recordUsage(username);
      enforceAccountQuota(
        beforeCount: before!.$1,
        beforeBytes: before.$2,
        afterCount: after.$1,
        afterBytes: after.$2,
        quota: quota,
      );
    }
    return PushResponse(results: results, latestSeq: _latestSeq(username));
  }

  /// [Storage.pushRecords] under [PushRefusalScope.record] once the batch as
  /// a whole did not fit. Usage is tracked as the entries apply rather than
  /// re-summed per entry, which would scan the account once per record.
  PushResponse _pushEachRecord(
    String username,
    List<EncryptedRecord> records, {
    required AccountQuota quota,
  }) {
    final start = _recordUsage(username);
    RecordUsage usage = (count: start.$1, bytes: start.$2);
    final results = <PushResult>[];
    var pending = records;
    for (var pass = 0; pass < perRecordQuotaPasses; pass++) {
      final deferred = <EncryptedRecord>[];
      for (final incoming in pending) {
        final existing = _getRecord(username, incoming.id);
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

        // Sized with the sequence it would get, as the stored row is.
        final candidate = incoming.withSeq(_latestSeq(username) + 1);
        final after = usageAfterReplacing(
          usage,
          existing: existing,
          existingBytes: existing == null
              ? 0
              : _storedSize(username, incoming.id),
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

        final seq = _nextSeq(username);
        _putRecord(username, candidate);
        results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
        usage = after;
      }
      pending = deferred;
    }
    final refused = [
      for (final record in pending)
        PushRefusal(id: record.id, reason: PushRefusalReason.accountQuota),
    ];
    return PushResponse(
      results: results,
      refused: refused,
      latestSeq: _latestSeq(username),
    );
  }

  /// The bytes a stored row counts toward the quota: its recorded size, which
  /// is what [_recordUsage] sums.
  int _storedSize(String username, String id) =>
      _db.select(
            'SELECT encoded_size FROM records WHERE username = ? AND id = ?',
            [username, id],
          ).single['encoded_size']
          as int;

  @override
  Future<PushResponse> pushRecordsFor(
    AuthPrincipal principal,
    List<EncryptedRecord> records, {
    AccountQuota? quota,
    PushRefusalScope refusalScope = PushRefusalScope.batch,
  }) async {
    final mode = records.isEmpty
        ? _TransactionMode.read
        : _TransactionMode.write;
    return _transaction(mode, () {
      _requireCurrent(principal);
      return _pushRecords(
        principal.username,
        records,
        quota: quota,
        refusalScope: refusalScope,
      );
    });
  }

  @override
  Future<PullResponse> pullSnapshot(String username, int since) async =>
      _transaction(_TransactionMode.read, () {
        final watermark = _latestSeq(username);
        return PullResponse(
          records: _recordsSince(username, since, through: watermark),
          latestSeq: watermark,
          recordEnvelopeFloor: _recordEnvelopeFloor(username, watermark),
        );
      });

  @override
  Future<PullResponse> pullSnapshotFor(
    AuthPrincipal principal,
    int since,
  ) async => _transaction(_TransactionMode.read, () {
    _requireCurrent(principal);
    final watermark = _latestSeq(principal.username);
    return PullResponse(
      records: _recordsSince(principal.username, since, through: watermark),
      latestSeq: watermark,
      recordEnvelopeFloor: _recordEnvelopeFloor(principal.username, watermark),
    );
  });

  @override
  Future<PullResponse> pullPage(
    String username,
    int since, {
    int? throughSeq,
    required PullPageLimits limits,
    PushLimits? advertisedLimits,
  }) async => _transaction(
    _TransactionMode.read,
    () => _pullPage(
      username,
      since,
      throughSeq: throughSeq,
      limits: limits,
      advertisedLimits: advertisedLimits,
    ),
  );

  @override
  Future<PullResponse> pullPageFor(
    AuthPrincipal principal,
    int since, {
    int? throughSeq,
    required PullPageLimits limits,
    PushLimits? advertisedLimits,
  }) async => _transaction(_TransactionMode.read, () {
    _requireCurrent(principal);
    return _pullPage(
      principal.username,
      since,
      throughSeq: throughSeq,
      limits: limits,
      advertisedLimits: advertisedLimits,
    );
  });

  PullResponse _pullPage(
    String username,
    int since, {
    int? throughSeq,
    required PullPageLimits limits,
    PushLimits? advertisedLimits,
  }) {
    final latest = _latestSeq(username);
    final through = throughSeq ?? latest;
    final floor = _recordEnvelopeFloor(username, through);
    if (through < since || through > latest) {
      throw const StorageCursorRejectedException();
    }
    final statement = _db.prepare(
      'SELECT * FROM records WHERE username = ? AND seq > ? '
      'AND seq <= ? ORDER BY seq ASC',
    );
    final cursor = statement.selectCursor([username, since, through]);
    final records = <EncryptedRecord>[];
    var recordBytes = 0;
    var hasMore = false;
    try {
      while (cursor.moveNext()) {
        final candidate = _rowToRecord(cursor.current);
        if (records.length == limits.maxRecords) {
          hasMore = true;
          break;
        }
        final nextBytes = recordBytes + candidate.encodedJsonBytes();
        final fits =
            PullResponse.bodyBytesFor(
              recordCount: records.length + 1,
              recordBytes: nextBytes,
              latestSeq: through,
              recordEnvelopeFloor: floor,
              throughSeq: through,
              hasMore: false,
              limits: advertisedLimits,
            ) <=
            limits.maxBodyBytes;
        if (!fits) {
          if (records.isEmpty) throw const StoragePageTooSmallException();
          hasMore = true;
          break;
        }
        records.add(candidate);
        recordBytes = nextBytes;
      }
    } finally {
      statement.dispose();
    }
    return PullResponse(
      records: records,
      latestSeq: through,
      recordEnvelopeFloor: floor,
      throughSeq: through,
      hasMore: hasMore,
      limits: advertisedLimits,
    );
  }

  @override
  Future<LegacyRecordPage> legacyRecordPage(
    String username, {
    String? afterId,
    required PullPageLimits limits,
  }) async => _transaction(
    _TransactionMode.read,
    () => _legacyRecordPage(username, afterId: afterId, limits: limits),
  );

  @override
  Future<LegacyRecordPage> legacyRecordPageFor(
    AuthPrincipal principal, {
    String? afterId,
    required PullPageLimits limits,
  }) async => _transaction(_TransactionMode.read, () {
    _requireCurrent(principal);
    return _legacyRecordPage(
      principal.username,
      afterId: afterId,
      limits: limits,
    );
  });

  LegacyRecordPage _legacyRecordPage(
    String username, {
    String? afterId,
    required PullPageLimits limits,
  }) {
    final floor = _recordEnvelopeFloor(username);
    final statement = _db.prepare(
      afterId == null
          ? 'SELECT * FROM records WHERE username = ? '
                'AND envelope_version = ? ORDER BY id ASC'
          : 'SELECT * FROM records WHERE username = ? '
                'AND envelope_version = ? AND id > ? ORDER BY id ASC',
    );
    final cursor = statement.selectCursor([
      username,
      kLegacyRecordEnvelopeVersion,
      ?afterId,
    ]);
    final records = <EncryptedRecord>[];
    var recordBytes = 0;
    var hasMore = false;
    try {
      while (cursor.moveNext()) {
        final candidate = _rowToRecord(cursor.current);
        if (floor == kCurrentRecordEnvelopeVersion) {
          throw const StorageEnvelopeFloorViolationException();
        }
        if (records.length == limits.maxRecords) {
          hasMore = true;
          break;
        }
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
          hasMore = true;
          break;
        }
        records.add(candidate);
        recordBytes = nextBytes;
      }
    } finally {
      statement.dispose();
    }
    return LegacyRecordPage(
      records: records,
      nextId: records.isEmpty ? null : records.last.id,
      hasMore: hasMore,
      recordEnvelopeFloor: floor,
    );
  }

  @override
  Future<LegacyMigrationResponse> migrateLegacyRecords(
    String username,
    List<LegacyRecordMigration> migrations, {
    required bool finalize,
    AccountQuota? quota,
  }) async => _transaction(_TransactionMode.write, () {
    return _migrateLegacyRecords(
      username,
      migrations,
      finalize: finalize,
      quota: quota,
    );
  });

  @override
  Future<LegacyMigrationResponse> migrateLegacyRecordsFor(
    AuthPrincipal principal,
    List<LegacyRecordMigration> migrations, {
    required bool finalize,
    AccountQuota? quota,
  }) async => _transaction(_TransactionMode.write, () {
    _requireCurrent(principal);
    return _migrateLegacyRecords(
      principal.username,
      migrations,
      finalize: finalize,
      quota: quota,
    );
  });

  LegacyMigrationResponse _migrateLegacyRecords(
    String username,
    List<LegacyRecordMigration> migrations, {
    required bool finalize,
    AccountQuota? quota,
  }) {
    validateLegacyMigrationBatch(migrations);
    final before = quota == null ? null : _recordUsage(username);
    var migrated = 0;
    var stale = 0;
    for (final migration in migrations) {
      final existing = _getRecord(username, migration.expected.id);
      if (existing == null ||
          !sameEncryptedRecord(existing, migration.expected)) {
        stale++;
        continue;
      }

      _db.execute('DELETE FROM records WHERE username = ? AND id = ?', [
        username,
        migration.expected.id,
      ]);
      final replacement = migration.replacement;
      final target = _getRecord(username, replacement.id);
      if (target == null ||
          (target.envelopeVersion == kCurrentRecordEnvelopeVersion &&
              identical(Lww.resolve(target, replacement), replacement))) {
        _putRecord(username, replacement.withSeq(_nextSeq(username)));
      }
      migrated++;
    }

    if (migrated != 0 && quota != null) {
      final after = _recordUsage(username);
      enforceAccountQuota(
        beforeCount: before!.$1,
        beforeBytes: before.$2,
        afterCount: after.$1,
        afterBytes: after.$2,
        quota: quota,
      );
    }

    if (finalize &&
        _recordEnvelopeFloor(username) < kCurrentRecordEnvelopeVersion) {
      final remaining = _db.select(
        'SELECT 1 FROM records WHERE username = ? '
        'AND envelope_version != ? LIMIT 1',
        [username, kCurrentRecordEnvelopeVersion],
      );
      if (remaining.isEmpty && _accountGeneration(username) != null) {
        final checkpoint = _nextSeq(username);
        _db.execute(
          'UPDATE accounts SET record_envelope_floor = ?, '
          'record_envelope_floor_seq = ? '
          'WHERE username = ? AND record_envelope_floor < ?',
          [
            kCurrentRecordEnvelopeVersion,
            checkpoint,
            username,
            kCurrentRecordEnvelopeVersion,
          ],
        );
      }
    }
    return LegacyMigrationResponse(
      migrated: migrated,
      stale: stale,
      latestSeq: _latestSeq(username),
      recordEnvelopeFloor: _recordEnvelopeFloor(username),
    );
  }

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

  static bool _isBusy(Object error) =>
      error is SqliteException &&
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
      stderr.writeln(
        'Transaction failed (${_diagnosticCause(cause)}); '
        'cleanup failed (${_diagnosticCause(cleanupCause)}). $_failure',
      );
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
      'SELECT * FROM records WHERE username = ? AND id = ?',
      [username, id],
    );
    return rows.isEmpty ? null : _rowToRecord(rows.first);
  }

  @override
  Future<void> putRecord(String username, EncryptedRecord record) async =>
      _putRecord(username, record);

  void _putRecord(String username, EncryptedRecord record) {
    _db.execute(
      '''INSERT INTO records (username, id, envelope_version, updated_at, device_id, deleted, seq, blob, encoded_size)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(username, id) DO UPDATE SET
           envelope_version=excluded.envelope_version,
           updated_at=excluded.updated_at, device_id=excluded.device_id,
           deleted=excluded.deleted, seq=excluded.seq, blob=excluded.blob,
           encoded_size=excluded.encoded_size''',
      [
        username,
        record.id,
        record.envelopeVersion,
        record.updatedAt,
        record.deviceId,
        record.deleted ? 1 : 0,
        record.seq ?? 0,
        record.blob,
        record.encodedJsonBytes(),
      ],
    );
  }

  /// Live rows and the bytes of every row. See [AccountQuota] for why a
  /// tombstone counts toward bytes but not rows.
  (int, int) _recordUsage(String username) {
    final row = _db.select(
      'SELECT COALESCE(SUM(deleted = 0), 0) AS n, '
      'COALESCE(SUM(encoded_size), 0) AS bytes '
      'FROM records WHERE username = ?',
      [username],
    ).single;
    return (row['n'] as int, row['bytes'] as int);
  }

  @override
  Future<List<EncryptedRecord>> recordsSince(
    String username,
    int since,
  ) async => _recordsSince(username, since);

  List<EncryptedRecord> _recordsSince(
    String username,
    int since, {
    int? through,
  }) {
    final rows = _db.select(
      through == null
          ? 'SELECT * FROM records WHERE username = ? AND seq > ? '
                'ORDER BY seq ASC'
          : 'SELECT * FROM records WHERE username = ? AND seq > ? '
                'AND seq <= ? ORDER BY seq ASC',
      [username, since, ?through],
    );
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
    final rows = _db.select('SELECT value FROM seqs WHERE username = ?', [
      username,
    ]);
    return rows.first['value'] as int;
  }

  @override
  Future<int> latestSeq(String username) async => _latestSeq(username);

  int _latestSeq(String username) {
    final rows = _db.select('SELECT value FROM seqs WHERE username = ?', [
      username,
    ]);
    return rows.isEmpty ? 0 : rows.first['value'] as int;
  }

  EncryptedRecord _rowToRecord(Row r) => EncryptedRecord(
    envelopeVersion: r['envelope_version'] as int,
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
        return _createInboxApp(app);
      });

  bool _createInboxApp(StoredInboxApp app) {
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
  }

  @override
  Future<bool> createInboxAppFor(
    AuthPrincipal principal,
    StoredInboxApp app, {
    int maxApps = 50,
  }) async => _transaction(_TransactionMode.write, () {
    _requireCurrent(principal);
    if (app.username != principal.username) {
      throw ArgumentError.value(app.username, 'app.username');
    }
    final count =
        _db.select('SELECT COUNT(*) AS n FROM inbox_apps WHERE username = ?', [
              principal.username,
            ]).single['n']
            as int;
    if (count >= maxApps) throw const InboxAppLimitException();
    return _createInboxApp(app);
  });

  @override
  Future<StoredInboxApp?> getInboxApp(String appId) async {
    final rows = _db.select('SELECT * FROM inbox_apps WHERE app_id = ?', [
      appId,
    ]);
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
    return _listInboxApps(username);
  }

  List<InboxAppInfo> _listInboxApps(String username) {
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
  Future<List<InboxAppInfo>> listInboxAppsFor(AuthPrincipal principal) async =>
      _transaction(_TransactionMode.read, () {
        _requireCurrent(principal);
        return _listInboxApps(principal.username);
      });

  @override
  Future<bool> deleteInboxApp(String username, String appId) async =>
      _transaction(_TransactionMode.write, () {
        return _deleteInboxApp(username, appId);
      });

  bool _deleteInboxApp(String username, String appId) {
    // Explicit as well as cascaded, so the items go even on a
    // connection that was opened without the foreign-key pragma.
    _db.execute('DELETE FROM inbox_items WHERE app_id = ? AND username = ?', [
      appId,
      username,
    ]);
    _db.execute('DELETE FROM inbox_apps WHERE app_id = ? AND username = ?', [
      appId,
      username,
    ]);
    return _db.updatedRows == 1;
  }

  @override
  Future<bool> deleteInboxAppFor(AuthPrincipal principal, String appId) async =>
      _transaction(_TransactionMode.write, () {
        _requireCurrent(principal);
        return _deleteInboxApp(principal.username, appId);
      });

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
  }) async =>
      // One write transaction, so two concurrent deposits cannot both pass
      // the pending cap or draw the same `received` number.
      _transaction(_TransactionMode.write, () {
        final apps = _db.select(
          'SELECT username FROM inbox_apps WHERE app_id = ? '
          'AND (? IS NULL OR token_salt = ?)',
          [appId, expectedGeneration, expectedGeneration],
        );
        if (apps.isEmpty) {
          return const InboxAddResult(InboxAddStatus.unknownApp);
        }
        final username = apps.first['username'] as String;
        final pending =
            _db.select(
                  'SELECT COUNT(*) AS n FROM inbox_items WHERE app_id = ?',
                  [appId],
                ).first['n']
                as int;
        if (pending >= maxPending) {
          return const InboxAddResult(InboxAddStatus.full);
        }
        final usage = _db.select(
          'SELECT COUNT(*) AS n, COALESCE(SUM(length(blob)), 0) AS bytes FROM inbox_items WHERE username = ?',
          [username],
        ).single;
        if ((usage['n'] as int) >= maxAccountPendingItems ||
            (usage['bytes'] as int) + blob.length > maxAccountPendingBytes) {
          return const InboxAddResult(InboxAddStatus.accountFull);
        }
        final sequenceRows = _db.select(
          'SELECT value FROM inbox_seqs WHERE username = ?',
          [username],
        );
        final received =
            (sequenceRows.isEmpty ? 0 : sequenceRows.single['value'] as int) +
            1;
        final item = InboxItem(
          appId: appId,
          itemId: itemId,
          received: received,
          blob: blob,
        );
        if (quota != null) {
          final usage = _inboxUsage(username);
          if (usage.$1 + 1 > quota.maxRecords ||
              usage.$2 + item.encodedJsonBytes() > quota.maxBytes) {
            return const InboxAddResult(InboxAddStatus.accountFull);
          }
        }
        _db.execute(
          'INSERT INTO inbox_seqs (username, value) VALUES (?, 1) '
          'ON CONFLICT(username) DO UPDATE SET value = value + 1',
          [username],
        );
        _db.execute(
          'INSERT INTO inbox_items (app_id, item_id, username, received, '
          'blob, stored_at, encoded_size) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            appId,
            itemId,
            username,
            received,
            blob,
            storedAt,
            item.encodedJsonBytes(),
          ],
        );
        return InboxAddResult(InboxAddStatus.added, received);
      });

  (int, int) _inboxUsage(String username) {
    final row = _db.select(
      'SELECT COUNT(*) AS n, COALESCE(SUM(encoded_size), 0) AS bytes '
      'FROM inbox_items WHERE username = ?',
      [username],
    ).single;
    return (row['n'] as int, row['bytes'] as int);
  }

  @override
  Future<List<InboxItem>> inboxItemsSince(
    String username,
    int since, {
    int? limit,
  }) async {
    return _inboxItemsSince(username, since, limit: limit);
  }

  List<InboxItem> _inboxItemsSince(String username, int since, {int? limit}) {
    if (limit != null && limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    final rows = _db.select(
      'SELECT app_id, item_id, received, blob FROM inbox_items '
      'WHERE username = ? AND received > ? ORDER BY received ASC'
      '${limit == null ? '' : ' LIMIT ?'}',
      [username, since, ?limit],
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
  Future<List<InboxItem>> inboxItemsSinceFor(
    AuthPrincipal principal,
    int since,
  ) async => _transaction(_TransactionMode.read, () {
    _requireCurrent(principal);
    return _inboxItemsSince(principal.username, since);
  });

  @override
  Future<InboxPage> inboxPage(
    String username,
    int since, {
    int? throughReceived,
    required PullPageLimits limits,
  }) async => _transaction(
    _TransactionMode.read,
    () => _inboxPage(
      username,
      since,
      throughReceived: throughReceived,
      limits: limits,
    ),
  );

  @override
  Future<InboxPage> inboxPageFor(
    AuthPrincipal principal,
    int since, {
    int? throughReceived,
    required PullPageLimits limits,
  }) async => _transaction(_TransactionMode.read, () {
    _requireCurrent(principal);
    return _inboxPage(
      principal.username,
      since,
      throughReceived: throughReceived,
      limits: limits,
    );
  });

  InboxPage _inboxPage(
    String username,
    int since, {
    int? throughReceived,
    required PullPageLimits limits,
  }) {
    final rows = _db.select('SELECT value FROM inbox_seqs WHERE username = ?', [
      username,
    ]);
    final latest = rows.isEmpty ? 0 : rows.single['value'] as int;
    final through = throughReceived ?? latest;
    if (through < since || through > latest) {
      throw const StorageCursorRejectedException();
    }
    final statement = _db.prepare(
      'SELECT app_id, item_id, received, blob FROM inbox_items '
      'WHERE username = ? AND received > ? AND received <= ? '
      'ORDER BY received ASC',
    );
    final cursor = statement.selectCursor([username, since, through]);
    final items = <InboxItem>[];
    var itemBytes = 0;
    var hasMore = false;
    try {
      while (cursor.moveNext()) {
        final row = cursor.current;
        final candidate = InboxItem(
          appId: row['app_id'] as String,
          itemId: row['item_id'] as String,
          received: row['received'] as int,
          blob: _blobOf(row),
        );
        if (items.length == limits.maxRecords) {
          hasMore = true;
          break;
        }
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
          hasMore = true;
          break;
        }
        items.add(candidate);
        itemBytes = nextBytes;
      }
    } finally {
      statement.dispose();
    }
    return InboxPage(
      items: items,
      throughReceived: through,
      nextReceived: items.isEmpty ? since : items.last.received,
      hasMore: hasMore,
    );
  }

  @override
  Future<bool> deleteInboxItem(
    String username,
    String appId,
    String itemId,
  ) async {
    return _deleteInboxItem(username, appId, itemId);
  }

  bool _deleteInboxItem(String username, String appId, String itemId) {
    _db.execute(
      'DELETE FROM inbox_items WHERE username = ? AND app_id = ? '
      'AND item_id = ?',
      [username, appId, itemId],
    );
    return _db.updatedRows == 1;
  }

  @override
  Future<bool> deleteInboxItemFor(
    AuthPrincipal principal,
    String appId,
    String itemId,
  ) async => _transaction(_TransactionMode.write, () {
    _requireCurrent(principal);
    return _deleteInboxItem(principal.username, appId, itemId);
  });

  @override
  Future<int> purgeInboxItems({required int storedBefore}) async {
    _db.execute('DELETE FROM inbox_items WHERE stored_at < ?', [storedBefore]);
    return _db.updatedRows;
  }

  void close() => _connection.dispose();
}
