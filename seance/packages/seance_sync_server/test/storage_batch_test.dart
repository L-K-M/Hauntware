import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

EncryptedRecord _record(
  String id,
  int revision, {
  String deviceId = 'device',
  int blobBytes = 1,
}) => EncryptedRecord(
  id: id,
  updatedAt: revision,
  deviceId: deviceId,
  deleted: false,
  seq: null,
  blob: Uint8List(blobBytes)..[0] = revision,
);

Account _account(String username) => Account(
  username: username,
  generation: 'generation-$username',
  authVerifierHash: 'unused',
  verifierSalt: 'unused',
  argonSalt: 'unused',
  argonParams: const Argon2Params(),
);

enum _CleanupFault { rollback, stateRead }

class _FaultingDatabase implements Database {
  final Database _inner;
  final _CleanupFault _fault;
  bool disposed = false;

  _FaultingDatabase(this._inner, this._fault);

  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    if (sql.trim().toUpperCase().startsWith('ROLLBACK') &&
        _fault == _CleanupFault.rollback) {
      throw StateError('injected cleanup failure');
    }
    _inner.execute(sql, parameters);
  }

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      _inner.select(sql, parameters);

  @override
  bool get autocommit {
    if (_fault == _CleanupFault.stateRead) {
      throw StateError('injected state-read failure');
    }
    return _inner.autocommit;
  }

  @override
  int get updatedRows => _inner.updatedRows;

  @override
  void dispose() {
    disposed = true;
    _inner.dispose();
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '_FaultingDatabase does not implement ${invocation.memberName}',
  );
}

void main() {
  for (final fault in _CleanupFault.values) {
    test(
      'failed ${fault.name} preserves the cause and closes storage',
      () async {
        final database = sqlite3.openInMemory();
        final adapter = _FaultingDatabase(database, fault);
        final storage = SqliteStorage(adapter);
        addTearDown(storage.close);
        await storage.createAccount(_account('user'));
        database.execute('''
        CREATE TRIGGER fail_record BEFORE INSERT ON records
        BEGIN SELECT RAISE(ABORT, 'original write failure'); END;
      ''');

        await expectLater(
          storage.pushRecords('user', [_record('record', 10)]),
          throwsA(
            isA<StorageUnavailableException>().having(
              (e) => e.cause,
              'cause',
              isA<SqliteException>().having(
                (e) => e.message,
                'original message',
                contains('original write failure'),
              ),
            ),
          ),
        );
        expect(adapter.disposed, isTrue);
        final handler = SyncServer(
          storage: storage,
          settings: const ServerSettings(),
        ).handler;
        for (final (method, path) in [
          ('GET', '/readyz'),
          ('GET', '/v1/sync'),
          ('PUT', '/v1/records'),
        ]) {
          final response = await handler(
            Request(
              method,
              Uri.parse('http://localhost$path'),
              // A malformed token is rejected before reaching the disabled
              // backend; use the normal bearer shape to test its failure.
              headers: {
                'authorization': 'Bearer ${base64Url.encode(List<int>.filled(32, 0))}',
              },
            ),
          );
          expect(response.statusCode, HttpStatus.serviceUnavailable);
          expect(
            jsonDecode(await response.readAsString())['error'],
            'storage_unavailable',
          );
        }
        expect(storage.close, returnsNormally);
      },
    );
  }

  test('the request that disables storage also returns unavailable', () async {
    final database = sqlite3.openInMemory();
    final storage = SqliteStorage(
      _FaultingDatabase(database, _CleanupFault.rollback),
    );
    addTearDown(storage.close);
    await storage.createAccount(_account('user'));
    final token = await storage.createToken('user');
    final handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(),
    ).handler;
    database.execute('''
      CREATE TRIGGER fail_record BEFORE INSERT ON records
      BEGIN SELECT RAISE(ABORT, 'private-test-detail'); END;
    ''');

    final response = await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/v1/records'),
        headers: {'authorization': 'Bearer $token'},
        body: jsonEncode(
          PushRequest(records: [_record('record', 10)]).toJson(),
        ),
      ),
    );
    expect(response.statusCode, HttpStatus.serviceUnavailable);
    final body = await response.readAsString();
    expect(jsonDecode(body)['error'], 'storage_unavailable');
    expect(body, isNot(contains('private-test-detail')));
  });

  final factories = <String, Storage Function()>{
    'memory': InMemoryStorage.new,
    'sqlite': () {
      final storage = SqliteStorage.open(':memory:');
      addTearDown(storage.close);
      return storage;
    },
  };

  for (final entry in factories.entries) {
    group(entry.key, () {
      late Storage storage;
      setUp(() async {
        storage = entry.value();
        for (final username in ['alice', 'bob']) {
          await storage.createAccount(_account(username));
        }
      });

      test('mixed batches allocate only accepted writes, in order', () async {
        await storage.pushRecords('alice', [_record('old', 20)]);
        final result = await storage.pushRecords('alice', [
          _record('old', 10),
          _record('new', 30),
          _record('another', 40),
        ]);
        expect(result.results.map((r) => r.accepted), [false, true, true]);
        expect(result.results.map((r) => r.seq), [1, 2, 3]);
        expect(result.latestSeq, 3);
        final delta = await storage.pullSnapshot('alice', 1);
        expect(delta.records.map((r) => r.id), ['new', 'another']);
        expect(delta.latestSeq, 3);
        expect((await storage.pullSnapshot('alice', 3)).records, isEmpty);
      });

      test('repeated ids resolve against earlier staged writes', () async {
        final result = await storage.pushRecords('alice', [
          _record('same', 10),
          _record('same', 20),
          _record('same', 15),
        ]);
        expect(result.results.map((r) => r.accepted), [true, true, false]);
        expect(result.results.map((r) => r.seq), [1, 2, 2]);
        expect(result.latestSeq, 2);
        expect(
          (await storage.pullSnapshot('alice', 0)).records.single.updatedAt,
          20,
        );
      });

      test('timestamp ties use device id then server sequence', () async {
        await storage.pushRecords('alice', [
          _record('same', 10, deviceId: 'a'),
        ]);
        final result = await storage.pushRecords('alice', [
          _record('same', 10, deviceId: 'z'),
          _record('same', 10, deviceId: 'b'),
          _record('same', 10, deviceId: 'z'),
        ]);
        expect(result.results.map((r) => r.accepted), [true, false, false]);
        expect(result.results.map((r) => r.seq), [2, 2, 2]);
        expect(
          (await storage.pullSnapshot('alice', 0)).records.single.deviceId,
          'z',
        );
      });

      test(
        'accounts, empty batches and captured snapshots stay isolated',
        () async {
          expect((await storage.pushRecords('alice', [])).latestSeq, 0);
          await storage.pushRecords('alice', [_record('same-id', 10)]);
          final snapshot = await storage.pullSnapshot('alice', 0);
          await storage.pushRecords('alice', [_record('same-id', 20)]);
          await storage.pushRecords('bob', [_record('same-id', 30)]);

          expect(snapshot.latestSeq, 1);
          expect(snapshot.records.single.updatedAt, 10);
          final bob = await storage.pullSnapshot('bob', 0);
          expect(bob.latestSeq, 1);
          expect(bob.records.single.updatedAt, 30);
          expect((await storage.pushRecords('alice', [])).latestSeq, 2);
        },
      );

      test(
        'a failed batch leaves both records and sequence unchanged',
        () async {
          await storage.pushRecords('alice', [_record('existing', 10)]);
          final before = await storage.pullSnapshot('alice', 0);
          // A lazy list failure exercises rollback after the first staged write.
          final invalid = <Object>[
            _record('existing', 20),
            'not a record',
          ].cast<EncryptedRecord>();
          await expectLater(
            storage.pushRecords('alice', invalid),
            throwsA(isA<TypeError>()),
          );
          expect(
            (await storage.pullSnapshot('alice', 0)).toJson(),
            before.toJson(),
          );
          final retry = await storage.pushRecords('alice', [
            _record('existing', 20),
          ]);
          expect(retry.results.single.seq, before.latestSeq + 1);
        },
      );

      test('stable pages exclude writes after their watermark', () async {
        await storage.pushRecords('alice', [_record('a', 1), _record('b', 2)]);
        const limits = PullPageLimits(maxRecords: 1, maxBodyBytes: 4096);
        final first = await storage.pullPage('alice', 0, limits: limits);
        expect(first.records.map((record) => record.id), ['a']);
        expect(first.throughSeq, 2);
        expect(first.hasMore, isTrue);

        await storage.pushRecords('alice', [_record('c', 3)]);
        final second = await storage.pullPage(
          'alice',
          first.records.single.seq!,
          throughSeq: first.throughSeq,
          limits: limits,
        );
        expect(second.records.map((record) => record.id), ['b']);
        expect(second.throughSeq, 2);
        expect(second.hasMore, isFalse);

        final nextWindow = await storage.pullPage(
          'alice',
          second.records.single.seq!,
          limits: limits,
        );
        expect(nextWindow.records.map((record) => record.id), ['c']);
        expect(nextWindow.throughSeq, 3);
      });

      test('a page body cap is exact', () async {
        await storage.pushRecords('alice', [_record('a', 1, blobBytes: 32)]);
        final record = (await storage.pullSnapshot('alice', 0)).records.single;
        final exact = PullResponse(
          records: [record],
          latestSeq: 1,
          throughSeq: 1,
          hasMore: false,
        ).encodedSizeBytes();
        final page = await storage.pullPage(
          'alice',
          0,
          limits: PullPageLimits(maxRecords: 1, maxBodyBytes: exact),
        );
        expect(page.encodedSizeBytes(), exact);
        await expectLater(
          storage.pullPage(
            'alice',
            0,
            limits: PullPageLimits(maxRecords: 1, maxBodyBytes: exact - 1),
          ),
          throwsA(isA<StoragePageTooSmallException>()),
        );
      });

      test('account quota refusal rolls back records and sequence', () async {
        await storage.pushRecords('alice', [_record('a', 1)]);
        await expectLater(
          storage.pushRecords('alice', [
            _record('b', 2),
          ], quota: const AccountQuota(maxRecords: 1, maxBytes: 4096)),
          throwsA(isA<AccountQuotaExceededException>()),
        );
        final after = await storage.pullSnapshot('alice', 0);
        expect(after.records.map((record) => record.id), ['a']);
        expect(after.latestSeq, 1);
        final retry = await storage.pushRecords('alice', [
          _record('b', 2),
        ], quota: const AccountQuota(maxRecords: 2, maxBytes: 4096));
        expect(retry.results.single.seq, 2);
      });

      test('a legacy over-byte account may shrink in place', () async {
        await storage.pushRecords('alice', [_record('a', 1, blobBytes: 256)]);
        final smaller = _record('a', 2, blobBytes: 8);
        final projected = smaller.withSeq(2).encodedJsonBytes();
        await storage.pushRecords('alice', [
          smaller,
        ], quota: AccountQuota(maxRecords: 1, maxBytes: projected - 1));
        expect(
          (await storage.pullSnapshot('alice', 0)).records.single.blob,
          hasLength(8),
        );
      });
    });
  }

  test(
    'SQLite preserves the cause when a trigger rolls back the transaction',
    () async {
      final database = sqlite3.openInMemory();
      final storage = SqliteStorage(database);
      addTearDown(storage.close);
      await storage.createAccount(_account('user'));
      database.execute('''
      CREATE TRIGGER fail_record BEFORE INSERT ON records
      WHEN NEW.id = 'poison'
      BEGIN SELECT RAISE(ROLLBACK, 'injected rollback'); END;
    ''');
      await expectLater(
        storage.pushRecords('user', [_record('ok', 10), _record('poison', 20)]),
        throwsA(
          isA<SqliteException>().having(
            (e) => e.message,
            'cause',
            contains('injected rollback'),
          ),
        ),
      );
      expect(database.autocommit, isTrue);
      final snapshot = await storage.pullSnapshot('user', 0);
      expect(snapshot.records, isEmpty);
      expect(snapshot.latestSeq, 0);
      expect(
        (await storage.pushRecords('user', [_record('ok', 10)])).latestSeq,
        1,
      );
    },
  );
}
