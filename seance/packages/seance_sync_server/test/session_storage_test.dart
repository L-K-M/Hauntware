import 'dart:convert';
import 'dart:io';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Account _account(String username) => Account(
  username: username,
  authVerifierHash: 'hash',
  verifierSalt: 'salt',
  argonSalt: 'argon',
  argonParams: const Argon2Params(),
);

SessionDevice _device(String id, [String? name]) =>
    SessionDevice(id: id, name: name ?? 'Device $id');

Future<IssuedSession> _issue(
  Storage storage,
  String username,
  String device, {
  required int now,
  int max = 32,
}) async => (await storage.createSession(
  username,
  _device(device),
  now: now,
  expiresAt: now + 10000,
  maxSessions: max,
))!;

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

void main() {
  for (final backend in <String, Storage Function()>{
    'memory': InMemoryStorage.new,
    'SQLite': () => SqliteStorage.open(':memory:'),
  }.entries) {
    group('${backend.key} sessions', () {
      late Storage storage;

      setUp(() => storage = backend.value());
      tearDown(() {
        if (storage case final SqliteStorage sqlite) sqlite.close();
      });

      test('account and first session are atomic and duplicate-safe', () async {
        final issued = await storage.createAccountAndSession(
          _account('alice'),
          _device('a'),
          now: 100,
          expiresAt: 1000,
          maxSessions: 2,
        );
        expect(issued, isNotNull);
        expect(
          (await storage.authenticateSession(
            issued!.token,
            now: 100,
            touchBefore: 0,
          ))?.username,
          'alice',
        );

        expect(
          await storage.createAccountAndSession(
            _account('alice'),
            _device('other'),
            now: 101,
            expiresAt: 1001,
            maxSessions: 2,
          ),
          isNull,
        );
        expect(await storage.listSessions('alice', now: 101), hasLength(1));

        await expectLater(
          storage.createAccountAndSession(
            _account('stranded'),
            _device('bad'),
            now: 100,
            expiresAt: 101,
            maxSessions: 0,
          ),
          throwsArgumentError,
        );
        expect(await storage.getAccount('stranded'), isNull);
      });

      test('expiry is fixed and last-used writes are hourly', () async {
        await storage.createAccount(_account('alice'));
        final issued = await storage.createSession(
          'alice',
          _device('a'),
          now: 1000,
          expiresAt: 5000,
          maxSessions: 2,
        );

        final untouched = await storage.authenticateSession(
          issued!.token,
          now: 1999,
          touchBefore: 999,
        );
        expect(untouched!.lastUsedAt, 1000);
        final touched = await storage.authenticateSession(
          issued.token,
          now: 2000,
          touchBefore: 1000,
        );
        expect(touched!.lastUsedAt, 2000);
        expect(touched.expiresAt, 5000, reason: 'use must not slide expiry');

        expect(
          await storage.authenticateSession(
            issued.token,
            now: 5000,
            touchBefore: 4000,
          ),
          isNull,
        );
        expect(await storage.listSessions('alice', now: 5000), isEmpty);
      });

      test(
        'same-device rotation and deterministic LRU enforce the cap',
        () async {
          await storage.createAccount(_account('alice'));
          final first = await _issue(storage, 'alice', 'one', now: 100);
          final second = await _issue(storage, 'alice', 'two', now: 200);
          final third = await _issue(
            storage,
            'alice',
            'three',
            now: 300,
            max: 2,
          );
          expect(
            await storage.authenticateSession(
              first.token,
              now: 300,
              touchBefore: 0,
            ),
            isNull,
          );
          expect(
            (await storage.listSessions(
              'alice',
              now: 300,
            )).map((session) => session.deviceId),
            ['three', 'two'],
          );

          await storage.authenticateSession(
            second.token,
            now: 400,
            touchBefore: 300,
          );
          await _issue(storage, 'alice', 'four', now: 500, max: 2);
          expect(
            await storage.authenticateSession(
              third.token,
              now: 500,
              touchBefore: 0,
            ),
            isNull,
            reason: 'the untouched third device is now least recently used',
          );

          final rotated = await _issue(
            storage,
            'alice',
            'two',
            now: 600,
            max: 2,
          );
          expect(
            await storage.authenticateSession(
              second.token,
              now: 600,
              touchBefore: 0,
            ),
            isNull,
          );
          expect(
            await storage.authenticateSession(
              rotated.token,
              now: 600,
              touchBefore: 0,
            ),
            isNotNull,
          );

          await _issue(storage, 'alice', 'only', now: 700, max: 1);
          expect(
            (await storage.listSessions('alice', now: 700)).single.deviceId,
            'only',
            reason: 'lowering the cap evicts repeatedly, not just once',
          );
        },
      );

      test('revocation is scoped to the authenticated account', () async {
        await storage.createAccount(_account('alice'));
        await storage.createAccount(_account('bob'));
        final alice = await _issue(storage, 'alice', 'a', now: 100);
        final bob = await _issue(storage, 'bob', 'b', now: 100);

        expect(await storage.revokeSession('alice', bob.session.id), isFalse);
        expect(
          await storage.authenticateSession(
            bob.token,
            now: 100,
            touchBefore: 0,
          ),
          isNotNull,
        );
        expect(await storage.revokeSession('alice', alice.session.id), isTrue);
        expect(await storage.revokeAllSessions('bob'), 1);
        expect(await storage.listSessions('bob', now: 100), isEmpty);
      });
    });
  }

  group('SQLite session persistence', () {
    test('stores only a token hash and survives reopen', () async {
      final directory = Directory.systemTemp.createTempSync('seance-session-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      var storage = SqliteStorage.open(path);
      await storage.createAccount(_account('alice'));
      final issued = await _issue(storage, 'alice', 'mac', now: 100);
      storage.close();

      final raw = sqlite3.open(path);
      final columns = raw.select('PRAGMA table_info(sessions)');
      expect(columns.map((row) => row['name']), isNot(contains('token')));
      final row = raw.select('SELECT token_hash FROM sessions').single;
      expect(row['token_hash'], isNot(issued.token));
      raw.dispose();

      storage = SqliteStorage.open(path);
      addTearDown(storage.close);
      expect(
        (await storage.authenticateSession(
          issued.token,
          now: 100,
          touchBefore: 0,
        ))?.deviceId,
        'mac',
      );
    });

    test(
      'migrates every plaintext token without logout and scrubs bytes',
      () async {
        final directory = Directory.systemTemp.createTempSync('seance-legacy-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final path = '${directory.path}/sync.sqlite';
        final token = base64Url.encode(List<int>.generate(32, (i) => i));
        final old = sqlite3.open(path);
        old.execute('PRAGMA journal_mode=WAL');
        old.execute('''
        CREATE TABLE accounts (username TEXT PRIMARY KEY,
          auth_verifier_hash TEXT NOT NULL, verifier_salt TEXT NOT NULL,
          argon_salt TEXT NOT NULL, argon_params TEXT NOT NULL);
        CREATE TABLE tokens (token TEXT PRIMARY KEY, username TEXT NOT NULL);
        CREATE TABLE records (username TEXT NOT NULL, id TEXT NOT NULL,
          updated_at INTEGER NOT NULL, device_id TEXT NOT NULL,
          deleted INTEGER NOT NULL, seq INTEGER NOT NULL, blob BLOB NOT NULL,
          PRIMARY KEY (username, id));
        CREATE TABLE seqs (username TEXT PRIMARY KEY, value INTEGER NOT NULL);
        INSERT INTO accounts VALUES ('alice', 'h', 's', 'a',
          '{"memoryKiB":19456,"iterations":2,"parallelism":1}');
        INSERT INTO tokens VALUES ('$token', 'alice');
        INSERT INTO seqs VALUES ('alice', 0);
      ''');
        old.dispose();

        final migratedAt = DateTime.utc(2026, 1, 1);
        var storage = SqliteStorage.open(
          path,
          legacySessionTtl: const Duration(days: 90),
          now: () => migratedAt,
        );
        final authenticated = await storage.authenticateSession(
          token,
          now: migratedAt.millisecondsSinceEpoch,
          touchBefore: 0,
        );
        expect(authenticated, isNotNull);
        expect(authenticated!.legacy, isTrue);
        expect(authenticated.deviceId, isNull);
        expect(
          authenticated.expiresAt,
          migratedAt.add(const Duration(days: 90)).millisecondsSinceEpoch,
        );
        final stableId = authenticated.id;
        storage.close();

        final check = sqlite3.open(path);
        expect(
          check.select(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tokens'",
          ),
          isEmpty,
        );
        check.dispose();
        final tokenBytes = utf8.encode(token);
        expect(
          _containsBytes(File(path).readAsBytesSync(), tokenBytes),
          isFalse,
        );
        final wal = File('$path-wal');
        if (wal.existsSync()) {
          expect(_containsBytes(wal.readAsBytesSync(), tokenBytes), isFalse);
        }

        storage = SqliteStorage.open(path, now: () => migratedAt);
        addTearDown(storage.close);
        expect(
          (await storage.authenticateSession(
            token,
            now: migratedAt.millisecondsSinceEpoch,
            touchBefore: 0,
          ))?.id,
          stableId,
          reason: 'reopening must not remigrate or rotate a legacy session',
        );
        final epoch = migratedAt.millisecondsSinceEpoch;
        await _issue(storage, 'alice', 'new', now: epoch, max: 1);
        final sessions = await storage.listSessions('alice', now: epoch);
        expect(sessions.where((session) => session.legacy), hasLength(1));
        expect(
          sessions.where((session) => !session.legacy),
          hasLength(1),
          reason: 'legacy sessions do not consume or lose a device slot',
        );
      },
    );

    test('refuses persistent legacy migration when WAL is unavailable', () {
      final directory = Directory.systemTemp.createTempSync('seance-non-wal-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      final old = sqlite3.open(path, vfs: 'unix-dotfile');
      old.execute('''
          CREATE TABLE tokens (token TEXT PRIMARY KEY, username TEXT NOT NULL);
          INSERT INTO tokens VALUES ('plaintext-canary', 'alice');
        ''');
      old.dispose();

      final connection = sqlite3.open(path, vfs: 'unix-dotfile');
      addTearDown(connection.dispose);
      expect(() => SqliteStorage(connection), throwsA(isA<StateError>()));
      expect(
        connection.select('SELECT token FROM tokens').single['token'],
        'plaintext-canary',
      );
    }, skip: Platform.isWindows ? 'requires a Unix SQLite VFS' : false);

    test('busy token cleanup fails closed and retries on reopen', () async {
      final directory = Directory.systemTemp.createTempSync('seance-retry-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      final token = base64Url.encode(List<int>.generate(32, (i) => 255 - i));
      final old = sqlite3.open(path);
      old.execute('PRAGMA journal_mode=WAL');
      old.execute('''
        CREATE TABLE accounts (username TEXT PRIMARY KEY,
          auth_verifier_hash TEXT NOT NULL, verifier_salt TEXT NOT NULL,
          argon_salt TEXT NOT NULL, argon_params TEXT NOT NULL);
        CREATE TABLE tokens (token TEXT PRIMARY KEY, username TEXT NOT NULL);
        CREATE TABLE records (username TEXT NOT NULL, id TEXT NOT NULL,
          updated_at INTEGER NOT NULL, device_id TEXT NOT NULL,
          deleted INTEGER NOT NULL, seq INTEGER NOT NULL, blob BLOB NOT NULL,
          PRIMARY KEY (username, id));
        CREATE TABLE seqs (username TEXT PRIMARY KEY, value INTEGER NOT NULL);
        INSERT INTO accounts VALUES ('alice', 'h', 's', 'a',
          '{"memoryKiB":19456,"iterations":2,"parallelism":1}');
        INSERT INTO tokens VALUES ('$token', 'alice');
        INSERT INTO seqs VALUES ('alice', 0);
      ''');
      old.dispose();

      final reader = sqlite3.open(path);
      reader.execute('BEGIN');
      expect(reader.select('SELECT token FROM tokens'), hasLength(1));

      final migratedAt = DateTime.utc(2026, 1, 1);
      expect(
        () => SqliteStorage.open(path, now: () => migratedAt),
        throwsA(isA<StateError>()),
      );
      final pending = sqlite3.open(path);
      expect(
        pending.select('''
          SELECT value FROM schema_metadata
          WHERE key = 'session_token_cleanup'
        ''').single['value'],
        'pending',
      );
      expect(
        pending.select(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tokens'",
        ),
        isEmpty,
      );
      pending.dispose();

      reader.execute('ROLLBACK');
      reader.dispose();
      final storage = SqliteStorage.open(path, now: () => migratedAt);
      addTearDown(storage.close);
      expect(
        await storage.authenticateSession(
          token,
          now: migratedAt.millisecondsSinceEpoch,
          touchBefore: 0,
        ),
        isNotNull,
      );
      final complete = sqlite3.open(path);
      expect(
        complete.select('''
          SELECT value FROM schema_metadata
          WHERE key = 'session_token_cleanup'
        ''').single['value'],
        'complete',
      );
      complete.dispose();
    });

    test('failed legacy insertion leaves the plaintext table intact', () {
      final directory = Directory.systemTemp.createTempSync('seance-migrate-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      final old = sqlite3.open(path);
      old.execute('''
        CREATE TABLE accounts (username TEXT PRIMARY KEY,
          auth_verifier_hash TEXT NOT NULL, verifier_salt TEXT NOT NULL,
          argon_salt TEXT NOT NULL, argon_params TEXT NOT NULL);
        CREATE TABLE tokens (token TEXT PRIMARY KEY, username TEXT NOT NULL);
        CREATE TABLE sessions (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
          username TEXT NOT NULL, device_id TEXT, device_name TEXT NOT NULL,
          created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
          last_used_at INTEGER NOT NULL, legacy INTEGER NOT NULL);
        CREATE TABLE records (username TEXT NOT NULL, id TEXT NOT NULL,
          updated_at INTEGER NOT NULL, device_id TEXT NOT NULL,
          deleted INTEGER NOT NULL, seq INTEGER NOT NULL, blob BLOB NOT NULL,
          PRIMARY KEY (username, id));
        CREATE TABLE seqs (username TEXT PRIMARY KEY, value INTEGER NOT NULL);
        INSERT INTO accounts VALUES ('alice', 'h', 's', 'a', '{}');
        INSERT INTO tokens VALUES ('plaintext-canary', 'alice');
        CREATE TRIGGER fail_session BEFORE INSERT ON sessions
          BEGIN SELECT RAISE(ABORT, 'migration failure'); END;
      ''');
      old.dispose();

      expect(() => SqliteStorage.open(path), throwsA(isA<SqliteException>()));
      final check = sqlite3.open(path);
      expect(
        check.select('SELECT token FROM tokens').single['token'],
        'plaintext-canary',
      );
      expect(check.select('SELECT * FROM sessions'), isEmpty);
      check.dispose();
    });

    test(
      'account creation rolls back when first session insert fails',
      () async {
        final database = sqlite3.openInMemory();
        final storage = SqliteStorage(database);
        addTearDown(storage.close);
        database.execute('''
        CREATE TRIGGER fail_session BEFORE INSERT ON sessions
          BEGIN SELECT RAISE(ABORT, 'session failure'); END;
      ''');
        await expectLater(
          storage.createAccountAndSession(
            _account('alice'),
            _device('a'),
            now: 100,
            expiresAt: 200,
            maxSessions: 2,
          ),
          throwsA(isA<SqliteException>()),
        );
        expect(await storage.getAccount('alice'), isNull);
        expect(database.select('SELECT * FROM seqs'), isEmpty);
      },
    );

    test('revocation and last-used touch report write contention', () async {
      final directory = Directory.systemTemp.createTempSync('seance-busy-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      final storage = SqliteStorage.open(path);
      addTearDown(storage.close);
      await storage.createAccount(_account('alice'));
      final issued = await _issue(storage, 'alice', 'a', now: 100);
      final writer = sqlite3.open(path);
      addTearDown(writer.dispose);
      writer.execute('BEGIN IMMEDIATE');

      await expectLater(
        storage.revokeSession('alice', issued.session.id),
        throwsA(isA<StorageBusyException>()),
      );
      await expectLater(
        storage.authenticateSession(issued.token, now: 200, touchBefore: 100),
        throwsA(isA<StorageBusyException>()),
      );
      writer.execute('ROLLBACK');
      expect(
        await storage.authenticateSession(
          issued.token,
          now: 200,
          touchBefore: 0,
        ),
        isNotNull,
      );
    });
  });
}
