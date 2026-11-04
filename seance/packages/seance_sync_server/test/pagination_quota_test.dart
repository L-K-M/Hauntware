import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Account _account(String username) => Account(
      username: username,
      authVerifierHash: 'unused',
      verifierSalt: 'unused',
      argonSalt: 'unused',
      argonParams: const Argon2Params(),
    );

EncryptedRecord _record(
  String id,
  int revision, {
  int blobBytes = 1,
  bool deleted = false,
}) =>
    EncryptedRecord(
      id: id,
      updatedAt: revision,
      deviceId: 'device',
      deleted: deleted,
      seq: null,
      blob: deleted
          ? Uint8List(0)
          : Uint8List.fromList(List.filled(blobBytes, revision & 0xff)),
    );

PullPageOptions _options({
  int maxRecords = 1000,
  int maxBodyBytes = 8 * 1024 * 1024,
}) =>
    PullPageOptions(
      maxRecords: maxRecords,
      maxBodyBytes: maxBodyBytes,
      pushLimits: const PushLimits(),
      recordEnvelopeVersion: kRecordEnvelopeVersion,
    );

Future<(int, Map<String, dynamic>, int)> _send(
  Handler handler,
  String token,
  String method,
  String path, {
  Object? body,
}) async {
  final response = await handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );
  final bytes = await response.read().expand((chunk) => chunk).toList();
  return (
    response.statusCode,
    (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>(),
    bytes.length,
  );
}

void main() {
  final factories = <String, Storage Function()>{
    'memory': InMemoryStorage.new,
    'sqlite': () {
      final storage = SqliteStorage.open(':memory:');
      addTearDown(storage.close);
      return storage;
    },
  };

  for (final entry in factories.entries) {
    group('${entry.key} pagination', () {
      late Storage storage;

      setUp(() async {
        storage = entry.value();
        await storage.createAccount(_account('user'));
      });

      test('uses a stable fence when an unseen row is overwritten', () async {
        await storage.pushRecords('user', [
          _record('a', 1),
          _record('b', 2),
          _record('c', 3),
        ]);
        final options = _options(maxRecords: 2);

        final first = await storage.pullPage(
          'user',
          0,
          options: options,
        );
        expect(first.records.map((record) => record.id), ['a', 'b']);
        expect(first.through, 3);
        expect(first.nextSince, 2);
        expect(first.latestSeq, 2);

        await storage.pushRecords('user', [_record('c', 4)]);
        final second = await storage.pullPage(
          'user',
          first.nextSince!,
          through: first.through,
          options: options,
        );
        expect(second.records, isEmpty);
        expect(second.latestSeq, 3);
        expect(second.through, 3);
        expect(second.nextSince, isNull);

        final nextWalk = await storage.pullPage(
          'user',
          second.latestSeq,
          options: options,
        );
        expect(nextWalk.records.single.id, 'c');
        expect(nextWalk.records.single.seq, 4);
        expect(nextWalk.latestSeq, 4);
      });

      test('honors the exact response byte boundary', () async {
        await storage.pushRecords('user', [_record('sized', 1, blobBytes: 40)]);
        final broad = await storage.pullPage(
          'user',
          0,
          options: _options(),
        );
        final exactBytes = broad.encodedSizeBytes();

        final exact = await storage.pullPage(
          'user',
          0,
          options: _options(maxBodyBytes: exactBytes),
        );
        expect(exact.encodedSizeBytes(), exactBytes);
        await expectLater(
          storage.pullPage(
            'user',
            0,
            options: _options(maxBodyBytes: exactBytes - 1),
          ),
          throwsA(isA<StoredPullRecordTooLargeException>()),
        );
      });

      test('rejects a cursor or fence ahead of the watermark', () async {
        await expectLater(
          storage.pullPage('user', 1, options: _options()),
          throwsA(isA<PullCursorRejectedException>()),
        );
        await expectLater(
          storage.pullPage('user', 0, through: 1, options: _options()),
          throwsA(isA<PullCursorRejectedException>()),
        );
        await expectLater(
          storage.pullPage('user', -1, options: _options()),
          throwsArgumentError,
        );
      });
    });

    group('${entry.key} quotas', () {
      late Storage storage;

      setUp(() async {
        storage = entry.value();
        await storage.createAccount(_account('user'));
      });

      test('accepts the exact byte cap and rejects one byte less', () async {
        final incoming = _record('a', 1, blobBytes: 20);
        final exactBytes = incoming.withSeq(1).encodedJsonBytes();
        await storage.pushRecords(
          'user',
          [incoming],
          quota: AccountQuota(maxRecords: 1, maxBytes: exactBytes),
        );
        expect((await storage.pullSnapshot('user', 0)).records, hasLength(1));

        await storage.createAccount(_account('other'));
        await expectLater(
          storage.pushRecords(
            'other',
            [incoming],
            quota: AccountQuota(maxRecords: 1, maxBytes: exactBytes - 1),
          ),
          throwsA(isA<AccountQuotaExceededException>()),
        );
        final rejected = await storage.pullSnapshot('other', 0);
        expect(rejected.records, isEmpty);
        expect(rejected.latestSeq, 0);
      });

      test('rolls back repeated ids, results, counters, and sequence', () async {
        await expectLater(
          storage.pushRecords(
            'user',
            [
              _record('same', 1),
              _record('same', 2),
              _record('other', 3),
            ],
            quota: const AccountQuota(maxRecords: 1),
          ),
          throwsA(isA<AccountQuotaExceededException>()),
        );
        final empty = await storage.pullSnapshot('user', 0);
        expect(empty.records, isEmpty);
        expect(empty.latestSeq, 0);

        final retry = await storage.pushRecords(
          'user',
          [_record('retry', 4)],
          quota: const AccountQuota(maxRecords: 1),
        );
        expect(retry.results.single.seq, 1);
      });

      test('allows rejected LWW rows and shrinking tombstones while over cap',
          () async {
        await storage.pushRecords(
          'user',
          [_record('same', 10, blobBytes: 100)],
        );
        final stale = await storage.pushRecords(
          'user',
          [_record('same', 1, blobBytes: 200)],
          quota: const AccountQuota(maxRecords: 0, maxBytes: 1),
        );
        expect(stale.results.single.accepted, isFalse);
        expect(stale.latestSeq, 1);

        final tombstone = _record('same', 20, deleted: true);
        final storedTombstoneBytes = tombstone.withSeq(2).encodedJsonBytes();
        final shrunk = await storage.pushRecords(
          'user',
          [tombstone],
          quota: AccountQuota(
            maxRecords: 0,
            maxBytes: storedTombstoneBytes - 1,
          ),
        );
        expect(shrunk.results.single.accepted, isTrue);
        expect(
          (await storage.pullSnapshot('user', 0)).records.single.deleted,
          isTrue,
        );

        await expectLater(
          storage.pushRecords(
            'user',
            [_record('new', 30)],
            quota: AccountQuota(
              maxRecords: 1,
              maxBytes: storedTombstoneBytes - 1,
            ),
          ),
          throwsA(isA<AccountQuotaExceededException>()),
          reason: 'a tombstone remains one stored record',
        );
      });
    });
  }

  test('metadata-only pages have an exact minimum body cap', () {
    final broad = _options();
    final empty = buildPullPage(
      const [],
      since: 0,
      through: 9223372036854775807,
      options: broad,
    );
    final exact = _options(maxBodyBytes: empty.encodedSizeBytes());

    expect(
      buildPullPage(
        const [],
        since: 0,
        through: 9223372036854775807,
        options: exact,
      ).encodedSizeBytes(),
      exact.maxBodyBytes,
    );
    expect(
      () => buildPullPage(
        const [],
        since: 0,
        through: 9223372036854775807,
        options: _options(maxBodyBytes: exact.maxBodyBytes - 1),
      ),
      throwsArgumentError,
    );
  });

  test('SQLite backfills usage once and preserves it across reopen', () async {
    final directory = await Directory.systemTemp.createTemp('usage-backfill-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/sync.sqlite';
    final first = SqliteStorage.open(path);
    await first.createAccount(_account('user'));
    await first.nextSeq('user');
    final stored = _record('legacy', 1, blobBytes: 10).withSeq(1);
    await first.putRecord('user', stored);
    first.close();

    final legacy = sqlite3.open(path);
    legacy.execute('DROP TABLE record_usage');
    legacy.dispose();

    final migrated = SqliteStorage.open(path);
    migrated.close();
    final checked = sqlite3.open(path);
    final usage = checked.select(
      'SELECT record_count, record_bytes FROM record_usage WHERE username = ?',
      ['user'],
    ).single;
    expect(usage['record_count'], 1);
    expect(usage['record_bytes'], stored.encodedJsonBytes());
    checked.execute('''
      CREATE TRIGGER forbid_usage_rewrite BEFORE DELETE ON record_usage
      BEGIN SELECT RAISE(ABORT, 'usage rewritten'); END;
    ''');
    checked.dispose();

    final reopened = SqliteStorage.open(path);
    expect((await reopened.pullSnapshot('user', 0)).records, hasLength(1));
    reopened.close();
  });

  test('HTTP exposes pagination, cursor, quota, and pullability errors',
      () async {
    final storage = InMemoryStorage();
    await storage.createAccount(_account('user'));
    final token = await storage.createToken('user');
    const settings = ServerSettings(
      maxRecordsPerPull: 1,
      maxPullBodyBytes: 512,
      maxAccountRecords: 1,
      maxBlobBytes: 1024,
    );
    final handler = SyncServer(storage: storage, settings: settings).handler;

    final firstPush = await _send(
      handler,
      token,
      'PUT',
      '/v1/records',
      body: PushRequest(records: [_record('small', 10)]).toJson(),
    );
    expect(firstPush.$1, 200);

    final staleOversized = await _send(
      handler,
      token,
      'PUT',
      '/v1/records',
      body: PushRequest(
        records: [_record('small', 1, blobBytes: 512)],
      ).toJson(),
    );
    expect(staleOversized.$1, 200);
    expect((staleOversized.$2['results'] as List).single['accepted'], isFalse);

    final winningOversized = await _send(
      handler,
      token,
      'PUT',
      '/v1/records',
      body: PushRequest(
        records: [_record('small', 20, blobBytes: 512)],
      ).toJson(),
    );
    expect(winningOversized.$1, 413);
    expect(winningOversized.$2['error'], 'payload_too_large');

    final quota = await _send(
      handler,
      token,
      'PUT',
      '/v1/records',
      body: PushRequest(records: [_record('second', 20)]).toJson(),
    );
    expect(quota.$1, 413);
    expect(quota.$2['error'], 'account_quota_exceeded');

    final pull = await _send(handler, token, 'GET', '/v1/sync?since=0');
    expect(pull.$1, 200);
    expect(pull.$3, lessThanOrEqualTo(settings.maxPullBodyBytes));
    expect(pull.$2['through'], 1);

    final ahead = await _send(handler, token, 'GET', '/v1/sync?since=2');
    expect(ahead.$1, HttpStatus.conflict);
    expect(ahead.$2['error'], 'sync_cursor_rejected');

    final malformed = await _send(
      handler,
      token,
      'GET',
      '/v1/sync?since=1.5',
    );
    expect(malformed.$1, HttpStatus.badRequest);
    expect(malformed.$2['error'], 'bad_request');
  });
}
