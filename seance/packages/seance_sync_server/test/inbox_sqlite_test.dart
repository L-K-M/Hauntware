import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// The inbox tables in the SQLite backend: an existing database gains them,
/// they survive a reopen, and the schema itself cascades app removal.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('seance-inbox-sqlite-');
    path = '${dir.path}/sync.sqlite';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  StoredInboxApp app(String appId, {String username = 'alice'}) =>
      StoredInboxApp(
        username: username,
        appId: appId,
        name: 'agent',
        tokenHash: 'hash',
        tokenSalt: 'salt',
        created: 1,
      );

  Future<InboxAddResult> add(SqliteStorage s, String appId, String itemId) =>
      s.addInboxItem(
        appId,
        itemId,
        Uint8List.fromList([1, 2, 3]),
        storedAt: 10,
        maxPending: 100,
      );

  test('a database from before the inbox upgrades in place', () async {
    // The schema as it stood before the inbox, with one account in it.
    final old = sqlite3.open(path);
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
        '{"memory":19456,"iterations":2,"parallelism":1,"hashLength":32}');
      INSERT INTO tokens VALUES ('t', 'alice');
      INSERT INTO records VALUES ('alice', 'r', 5, 'd', 0, 1, x'010203');
      INSERT INTO seqs VALUES ('alice', 1);
    ''');
    old.dispose();

    final s = SqliteStorage.open(path);
    addTearDown(s.close);
    expect(
      await s.usernameForToken('t'),
      isNull,
      reason: 'legacy plaintext bearer tokens are invalidated',
    );
    expect((await s.recordsSince('alice', 0)).single.id, 'r');
    expect((await s.getAccount('alice'))!.generation, isNotEmpty);
    expect(
      (await s.getAccount('alice'))!.vaultKeyCheck,
      isNull,
      reason: 'legacy accounts migrate without inventing a key check',
    );

    final appId = newInboxAppId();
    expect(await s.createInboxApp(app(appId)), isTrue);
    final added = await add(s, appId, 'i1');
    expect(added.status, InboxAddStatus.added);
    expect(added.received, 1);
    // The inbox counter is its own: the record cursor did not move.
    expect(await s.latestSeq('alice'), 1);
  });

  test('apps and items survive a reopen', () async {
    final appId = newInboxAppId();
    final s1 = SqliteStorage.open(path);
    await s1.createInboxApp(app(appId));
    await add(s1, appId, 'i1');
    s1.close();

    final s2 = SqliteStorage.open(path);
    addTearDown(s2.close);
    expect((await s2.getInboxApp(appId))!.tokenHash, 'hash');
    final items = await s2.inboxItemsSince('alice', 0);
    expect(items.single.itemId, 'i1');
    expect(items.single.blob, [1, 2, 3]);
    expect((await add(s2, appId, 'i2')).received, 2);
    expect((await s2.listInboxApps('alice')).single.pending, 2);
  });

  test('reopen backfills exact sizes for pre-size rows', () async {
    final s1 = SqliteStorage.open(path);
    final pushed = await s1.pushRecords('alice', [
      EncryptedRecord(
        id: 'r1',
        updatedAt: 1,
        deviceId: 'device',
        deleted: false,
        seq: null,
        blob: Uint8List.fromList([1, 2, 3]),
      ),
    ]);
    expect(pushed.latestSeq, 1);
    final storedRecord = (await s1.getRecord('alice', 'r1'))!;
    final appId = newInboxAppId();
    await s1.createInboxApp(app(appId));
    await add(s1, appId, 'i1');
    final storedItem = (await s1.inboxItemsSince('alice', 0)).single;
    s1.close();

    final old = sqlite3.open(path);
    old.execute('ALTER TABLE records DROP COLUMN encoded_size');
    old.execute('ALTER TABLE inbox_items DROP COLUMN encoded_size');
    old.dispose();

    final s2 = SqliteStorage.open(path);
    addTearDown(s2.close);
    final inspection = sqlite3.open(path);
    addTearDown(inspection.dispose);
    expect(
      inspection
          .select('SELECT encoded_size FROM records')
          .single['encoded_size'],
      storedRecord.encodedJsonBytes(),
    );
    expect(
      inspection
          .select('SELECT encoded_size FROM inbox_items')
          .single['encoded_size'],
      storedItem.encodedJsonBytes(),
    );

    await expectLater(
      s2.pushRecords(
        'alice',
        [
          EncryptedRecord(
            id: 'r2',
            updatedAt: 2,
            deviceId: 'device',
            deleted: false,
            seq: null,
            blob: Uint8List.fromList([4]),
          ),
        ],
        quota: AccountQuota(
          maxRecords: 10,
          maxBytes: storedRecord.encodedJsonBytes(),
        ),
      ),
      throwsA(isA<AccountQuotaExceededException>()),
    );
    final refused = await s2.addInboxItem(
      appId,
      'i2',
      Uint8List.fromList([4]),
      storedAt: 11,
      maxPending: 100,
      quota: AccountQuota(
        maxRecords: 10,
        maxBytes: storedItem.encodedJsonBytes(),
      ),
    );
    expect(refused.status, InboxAddStatus.accountFull);
  });

  test(
    'size backfill is atomic and restartable after a bad legacy row',
    () async {
      final s1 = SqliteStorage.open(path);
      await s1.pushRecords('alice', [
        EncryptedRecord(
          id: 'good',
          updatedAt: 1,
          deviceId: 'device',
          deleted: false,
          seq: null,
          blob: Uint8List.fromList([1]),
        ),
        EncryptedRecord(
          id: 'repair-me',
          updatedAt: 2,
          deviceId: 'device',
          deleted: false,
          seq: null,
          blob: Uint8List.fromList([2]),
        ),
      ]);
      final appId = newInboxAppId();
      await s1.createInboxApp(app(appId));
      await add(s1, appId, 'i1');
      await add(s1, appId, 'i2');
      s1.close();

      final legacy = sqlite3.open(path);
      legacy.execute('ALTER TABLE records DROP COLUMN encoded_size');
      legacy.execute('ALTER TABLE inbox_items DROP COLUMN encoded_size');
      legacy.execute(
        "UPDATE records SET blob = 'not-a-blob' WHERE id = 'repair-me'",
      );
      legacy.dispose();

      final broken = sqlite3.open(path);
      expect(() => SqliteStorage(broken), throwsA(anything));
      broken.dispose();

      final afterFailure = sqlite3.open(path);
      expect(
        afterFailure
            .select('PRAGMA table_info(records)')
            .map((row) => row['name']),
        isNot(contains('encoded_size')),
      );
      expect(
        afterFailure
            .select('PRAGMA table_info(inbox_items)')
            .map((row) => row['name']),
        isNot(contains('encoded_size')),
      );
      afterFailure.execute(
        "UPDATE records SET blob = x'02' WHERE id = 'repair-me'",
      );
      afterFailure.dispose();

      final repaired = SqliteStorage.open(path);
      addTearDown(repaired.close);
      final inspection = sqlite3.open(path);
      addTearDown(inspection.dispose);
      expect(
        inspection
            .select('SELECT encoded_size FROM records ORDER BY id')
            .map((row) => row['encoded_size']),
        everyElement(isA<int>()),
      );
      expect(
        inspection
            .select('SELECT encoded_size FROM inbox_items ORDER BY item_id')
            .map((row) => row['encoded_size']),
        everyElement(isA<int>()),
      );
      expect(await repaired.recordsSince('alice', 0), hasLength(2));
      expect(await repaired.inboxItemsSince('alice', 0), hasLength(2));
    },
  );

  test('the schema cascades an app removal to its items', () async {
    final db = sqlite3.open(path);
    final s = SqliteStorage(db);
    addTearDown(s.close);
    final appId = newInboxAppId();
    await s.createInboxApp(app(appId));
    await add(s, appId, 'i1');

    // Straight at the table, bypassing the storage's own item delete.
    db.execute('DELETE FROM inbox_apps WHERE app_id = ?', [appId]);
    expect(await s.inboxItemsSince('alice', 0), isEmpty);
  });

  test('a pending cap and a vanished app are reported, not stored', () async {
    final s = SqliteStorage.open(path);
    addTearDown(s.close);
    final appId = newInboxAppId();
    await s.createInboxApp(app(appId));
    final full = await s.addInboxItem(
      appId,
      'i1',
      Uint8List(40),
      storedAt: 1,
      maxPending: 0,
    );
    expect(full.status, InboxAddStatus.full);
    expect(
      (await add(s, newInboxAppId(), 'i1')).status,
      InboxAddStatus.unknownApp,
    );
    expect(await s.inboxItemsSince('alice', 0), isEmpty);
  });

  test('stable pages exclude later deposits', () async {
    final s = SqliteStorage.open(path);
    addTearDown(s.close);
    final appId = newInboxAppId();
    await s.createInboxApp(app(appId));
    await add(s, appId, 'i1');
    await add(s, appId, 'i2');
    const limits = PullPageLimits(maxRecords: 1, maxBodyBytes: 4096);
    final first = await s.inboxPage('alice', 0, limits: limits);
    expect(first.items.map((item) => item.itemId), ['i1']);
    expect(first.throughReceived, 2);
    expect(first.hasMore, isTrue);

    await add(s, appId, 'i3');
    final second = await s.inboxPage(
      'alice',
      first.nextReceived!,
      throughReceived: first.throughReceived!,
      limits: limits,
    );
    expect(second.items.map((item) => item.itemId), ['i2']);
    expect(second.hasMore, isFalse);
    final next = await s.inboxPage(
      'alice',
      second.nextReceived!,
      limits: limits,
    );
    expect(next.items.map((item) => item.itemId), ['i3']);
  });

  test('inbox quota refusal does not consume a sequence', () async {
    final s = SqliteStorage.open(path);
    addTearDown(s.close);
    final appId = newInboxAppId();
    await s.createInboxApp(app(appId));
    await add(s, appId, 'i1');
    final refused = await s.addInboxItem(
      appId,
      'i2',
      Uint8List.fromList([1, 2, 3]),
      storedAt: 10,
      maxPending: 100,
      quota: const AccountQuota(maxRecords: 1, maxBytes: 4096),
    );
    expect(refused.status, InboxAddStatus.accountFull);
    final accepted = await add(s, appId, 'i3');
    expect(accepted.received, 2);
    expect((await s.inboxItemsSince('alice', 0)).map((item) => item.itemId), [
      'i1',
      'i3',
    ]);
  });
}
