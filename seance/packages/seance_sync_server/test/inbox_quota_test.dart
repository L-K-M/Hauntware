import 'dart:typed_data';

import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

/// Account-wide inbox quotas and the bounded listing, at the storage level
/// for both backends. The caps are arguments here, so the tests stay bytes
/// small instead of allocating the production 32 MiB.
void main() {
  for (final backend in <String, Storage Function()>{
    'in-memory': InMemoryStorage.new,
    'SQLite': () => SqliteStorage.open(':memory:'),
  }.entries) {
    group('${backend.key} storage', () => _quotaTests(backend.value));
  }
}

/// An item body of any size; storage, unlike the handler, checks no
/// sealed-box minimum.
Uint8List _blob(int bytes) => Uint8List.fromList(List.filled(bytes, 7));

Future<void> _addApp(Storage s, String username, String appId) =>
    s.createInboxApp(StoredInboxApp(
      username: username,
      appId: appId,
      name: 'agent',
      tokenHash: 'hash',
      tokenSalt: 'salt',
      created: 1,
    ));

void _quotaTests(Storage Function() newStorage) {
  late Storage s;

  setUp(() => s = newStorage());
  tearDown(() {
    if (s case final SqliteStorage sqlite) sqlite.close();
  });

  Future<InboxAddResult> deposit(
    String appId,
    String itemId,
    int blobBytes, {
    int maxPending = 100,
    int maxAccountPendingItems = 5000,
    int maxAccountPendingBytes = 32 * 1024 * 1024,
  }) =>
      s.addInboxItem(
        appId,
        itemId,
        _blob(blobBytes),
        storedAt: 1,
        maxPending: maxPending,
        maxAccountPendingItems: maxAccountPendingItems,
        maxAccountPendingBytes: maxAccountPendingBytes,
      );

  test('listing caps ascending results at a positive limit', () async {
    await _addApp(s, 'alice', 'app-a');
    for (var i = 1; i <= 33; i++) {
      expect((await deposit('app-a', 'i$i', 48)).status,
          InboxAddStatus.added);
    }

    // What the handler asks for: one page of 32 plus the lookahead row.
    final fetched = await s.inboxItemsSince('alice', 0, limit: 33);
    expect(fetched, hasLength(33));
    expect(fetched.map((i) => i.received),
        [for (var i = 1; i <= 33; i++) i]);

    final page = await s.inboxItemsSince('alice', 0, limit: 32);
    expect(page, hasLength(32));
    expect(page.last.received, 32);
    final rest = await s.inboxItemsSince('alice', 32, limit: 33);
    expect(rest.map((i) => i.received), [33]);

    expect(() => s.inboxItemsSince('alice', 0, limit: 0),
        throwsArgumentError);
    expect(() => s.inboxItemsSince('alice', 0, limit: -1),
        throwsArgumentError);
  });

  test('the account byte cap admits the exact boundary, refuses one more',
      () async {
    await _addApp(s, 'alice', 'app-a');
    expect((await deposit('app-a', 'i1', 40, maxAccountPendingBytes: 100))
        .status, InboxAddStatus.added);
    // 40 + 60 fills the cap exactly.
    expect((await deposit('app-a', 'i2', 60, maxAccountPendingBytes: 100))
        .status, InboxAddStatus.added);
    expect(
      (await deposit('app-a', 'i3', 1, maxAccountPendingBytes: 100)).status,
      InboxAddStatus.accountFull,
    );
  });

  test('the account item cap aggregates across apps', () async {
    await _addApp(s, 'alice', 'a');
    await _addApp(s, 'alice', 'b');
    await _addApp(s, 'alice', 'c');
    expect((await deposit('a', 'i1', 48, maxAccountPendingItems: 2)).status,
        InboxAddStatus.added);
    expect((await deposit('b', 'i2', 48, maxAccountPendingItems: 2)).status,
        InboxAddStatus.added);
    // Every app is far under its own 100; the account is not.
    expect(
      (await deposit('c', 'i3', 48, maxAccountPendingItems: 2)).status,
      InboxAddStatus.accountFull,
    );
    // Another account's quota is its own.
    await _addApp(s, 'bob', 'x');
    expect((await deposit('x', 'i4', 48, maxAccountPendingItems: 2)).status,
        InboxAddStatus.added);
  });

  test('deleting an item restores quota capacity', () async {
    await _addApp(s, 'alice', 'a');
    expect((await deposit('a', 'i1', 60, maxAccountPendingBytes: 100))
        .status, InboxAddStatus.added);
    expect((await deposit('a', 'i2', 41, maxAccountPendingBytes: 100))
        .status, InboxAddStatus.accountFull);

    expect(await s.deleteInboxItem('alice', 'a', 'i1'), isTrue);
    expect((await deposit('a', 'i2', 41, maxAccountPendingBytes: 100))
        .status, InboxAddStatus.added);

    expect(
      (await deposit('a', 'i3', 1, maxAccountPendingItems: 1)).status,
      InboxAddStatus.accountFull,
    );
    expect(await s.deleteInboxItem('alice', 'a', 'i2'), isTrue);
    expect(
      (await deposit('a', 'i3', 1, maxAccountPendingItems: 1)).status,
      InboxAddStatus.added,
    );
  });

  test('a rejected deposit consumes no received number', () async {
    await _addApp(s, 'alice', 'a');
    final first = await deposit('a', 'i1', 40, maxAccountPendingBytes: 100);
    expect(first.status, InboxAddStatus.added);
    expect(first.received, 1);

    expect(
      (await deposit('a', 'i2', 61, maxAccountPendingBytes: 100)).status,
      InboxAddStatus.accountFull,
    );
    expect(
      (await deposit('a', 'i2', 48, maxPending: 1)).status,
      InboxAddStatus.full,
    );

    // Neither refusal moved the counter.
    final next = await deposit('a', 'i3', 60, maxAccountPendingBytes: 100);
    expect(next.status, InboxAddStatus.added);
    expect(next.received, 2);
  });
}
