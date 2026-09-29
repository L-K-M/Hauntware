import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// The server's inbox queue, shared by every device in a test, plus the
/// producer's deposit path.
class _FakeInbox implements InboxApi {
  final Map<String, String> tokens = {};
  final Map<String, InboxItem> items = {};
  int _received = 0;
  int _itemSeq = 0;

  @override
  Future<void> createApp(CreateInboxAppRequest request) async {
    if (tokens.containsKey(request.appId)) {
      throw const ApiError(code: 'app_exists', message: 'taken');
    }
    tokens[request.appId] = request.token;
  }

  @override
  Future<List<InboxAppInfo>> listApps() async => [
        for (final id in tokens.keys)
          InboxAppInfo(appId: id, name: '', created: 0, pending: 0),
      ];

  @override
  Future<bool> deleteApp(String appId) async {
    items.removeWhere((_, item) => item.appId == appId);
    return tokens.remove(appId) != null;
  }

  @override
  Future<List<InboxItem>> listItems({required int since}) async =>
      items.values.where((i) => i.received > since).toList()
        ..sort((a, b) => a.received.compareTo(b.received));

  @override
  Future<bool> deleteItem(String appId, String itemId) async {
    final item = items[itemId];
    if (item == null || item.appId != appId) return false;
    items.remove(itemId);
    return true;
  }

  /// What the producer does: seal and post.
  Future<String> deposit(InboxPairing pairing, Map<String, dynamic> proposal) =>
      depositBlob(
        pairing.appId,
        pairing.token,
        InboxCrypto.seal(
          pairing.key,
          pairing.appId,
          utf8.encode(jsonEncode(proposal)),
        ),
      );

  Future<String> depositBlob(
    String appId,
    String token,
    Future<Uint8List> blob,
  ) async {
    if (tokens[appId] != token) throw StateError('401');
    final id = 'item-${++_itemSeq}';
    items[id] = InboxItem(
      appId: appId,
      itemId: id,
      received: ++_received,
      blob: await blob,
    );
    return id;
  }
}

/// A record sync server, as small as the coordinator needs.
class _FakeRecords implements SyncApi {
  final Map<String, EncryptedRecord> _store = {};
  int _seq = 0;

  @override
  Future<PullResponse> pull({required int since}) async => PullResponse(
        records: _store.values.where((r) => (r.seq ?? 0) > since).toList()
          ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0)),
        latestSeq: _seq,
      );

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    final results = <PushResult>[];
    for (final incoming in records) {
      final existing = _store[incoming.id];
      if (existing == null ||
          identical(Lww.resolve(existing, incoming), incoming)) {
        _store[incoming.id] = incoming.withSeq(++_seq);
        results.add(PushResult(id: incoming.id, seq: _seq, accepted: true));
      } else {
        results.add(PushResult(
          id: incoming.id,
          seq: existing.seq ?? 0,
          accepted: false,
        ));
      }
    }
    return PushResponse(results: results, latestSeq: _seq);
  }

  /// Plant a record directly, as a breached server could.
  void plant(EncryptedRecord record) =>
      _store[record.id] = record.withSeq(++_seq);
}

final DateTime _t0 = DateTime.utc(2026, 9, 29, 12);
final int _t0s = _t0.millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _proposal(String id, {String host = 'prod-db-1'}) => {
      'v': 1,
      'id': id,
      'host': host,
      'title': 'Restart worker',
      'reason': 'Backlog',
      'script': 'systemctl restart worker\nsystemctl status worker',
      'created': _t0s,
    };

class _Device {
  final String id;
  final InboxAppStore apps = InMemoryInboxAppStore();
  final InboxStatusStore statuses = InMemoryInboxStatusStore();
  final InboxCacheStore cache = InMemoryInboxCacheStore();
  final ConfigStore config = InMemoryConfigStore();
  final LocalRecordStore local = InMemoryLocalRecordStore();
  late final InboxService inbox;
  late final SyncCoordinator sync;
  DateTime clock = _t0;

  _Device(this.id, _FakeInbox server, RecordCodec codec) {
    inbox = InboxService(
      api: server,
      apps: apps,
      statuses: statuses,
      cache: cache,
      now: () => clock,
    );
    sync = SyncCoordinator(
      configStore: config,
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: local,
      deviceId: id,
      inboxAppStore: apps,
      inboxStatusStore: statuses,
      now: () => clock,
    );
  }
}

ServerConfig _server(String id, String label, {String? host}) => ServerConfig(
      id: id,
      label: label,
      host: host ?? '$label.example.com',
      username: 'u',
      createdAt: 1,
      updatedAt: 1,
    );

void main() {
  late _FakeInbox server;
  late _FakeRecords records;
  late RecordCodec codec;
  late _Device a;
  late _Device b;

  setUp(() {
    server = _FakeInbox();
    records = _FakeRecords();
    codec = RecordCodec(secureRandomBytes(32));
    a = _Device('A', server, codec);
    b = _Device('B', server, codec);
  });

  Future<InboxPairing> connect(_Device device, {List<String>? only}) =>
      device.inbox.addApp(
        name: 'bots',
        serverUrl: 'https://sync.example.com',
        allowedServerIds: only ?? const [],
      );

  test('a proposal reaches every device and a run settles it on all', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);
    expect((await b.apps.getApp(pairing.appId))?.key, pairing.key);

    await server.deposit(pairing, _proposal('p1'));
    final onA = await a.inbox.refresh();
    final onB = await b.inbox.refresh();
    expect(onA.single.proposal.id, 'p1');
    expect(onB.single.proposal.script, contains('\n'));

    expect(await a.inbox.claim(onA.single), InboxClaim.claimed);
    expect(server.items, isEmpty);
    expect(await a.inbox.pending(), isEmpty);

    // B still shows it until the status arrives, then stops announcing it.
    expect(await b.inbox.pending(), hasLength(1));
    await a.sync.run(records);
    await b.sync.run(records);
    expect(await b.inbox.pending(), isEmpty);
    final status = await b.statuses.getStatus(pairing.appId, 'p1');
    expect(status?.state, InboxStatusState.ran);
  });

  test('two devices claiming before they sync: only the first runs', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);
    await server.deposit(pairing, _proposal('p1'));
    final onA = (await a.inbox.refresh()).single;
    final onB = (await b.inbox.refresh()).single;

    expect(await a.inbox.claim(onA), InboxClaim.claimed);
    expect(await b.inbox.claim(onB), InboxClaim.handledElsewhere);
    expect(await b.inbox.pending(), isEmpty);
    expect(await b.statuses.getStatus(pairing.appId, 'p1'), isNull);
  });

  test('claim refuses a proposal whose status already synced in', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);
    await server.deposit(pairing, _proposal('p1'));
    final onB = (await b.inbox.refresh()).single;
    await a.inbox.dismiss((await a.inbox.refresh()).single);
    await a.sync.run(records);
    await b.sync.run(records);

    expect(await b.inbox.claim(onB), InboxClaim.handledElsewhere);
  });

  test('dismissing what another device ran records nothing', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);
    await server.deposit(pairing, _proposal('p1'));
    final onA = (await a.inbox.refresh()).single;
    final onB = (await b.inbox.refresh()).single;

    expect(await a.inbox.claim(onA), InboxClaim.claimed);
    expect(await b.inbox.dismiss(onB), InboxClaim.handledElsewhere);
    expect(await b.statuses.getStatus(pairing.appId, 'p1'), isNull);
    expect(await b.inbox.pending(), isEmpty);

    await a.sync.run(records);
    await b.sync.run(records);
    final status = await b.statuses.getStatus(pairing.appId, 'p1');
    expect(status?.state, InboxStatusState.ran);
  });

  test('dismiss writes the status and removes the item', () async {
    final pairing = await connect(a);
    await server.deposit(pairing, _proposal('p1'));
    await a.inbox.dismiss((await a.inbox.refresh()).single);
    expect(server.items, isEmpty);
    final status = await a.statuses.getStatus(pairing.appId, 'p1');
    expect(status?.state, InboxStatusState.dismissed);
  });

  test('refused items are deleted and counted; the key and app are bound',
      () async {
    final pairing = await connect(a);
    final other = await connect(a);
    // Sealed for another app: a server moving blobs between apps.
    await server.depositBlob(
      pairing.appId,
      pairing.token,
      InboxCrypto.seal(
        other.key,
        other.appId,
        utf8.encode(jsonEncode(_proposal('p1'))),
      ),
    );
    // Right key, invalid content.
    await server.deposit(pairing, {..._proposal('p2'), 'title': ''});
    // Forged by someone with only the token.
    await server.depositBlob(
      pairing.appId,
      pairing.token,
      InboxCrypto.seal(
        newInboxKey(),
        pairing.appId,
        utf8.encode(jsonEncode(_proposal('p3'))),
      ),
    );

    expect(await a.inbox.refresh(), isEmpty);
    expect(server.items, isEmpty);
    expect((await a.inbox.failures())[pairing.appId], 3);
  });

  test('a replayed proposal id is not announced again', () async {
    final pairing = await connect(a);
    await server.deposit(pairing, _proposal('p1'));
    await a.inbox.dismiss((await a.inbox.refresh()).single);
    await server.deposit(pairing, _proposal('p1'));
    await server.deposit(pairing, _proposal('p2'));
    await server.deposit(pairing, _proposal('p2'));

    final pending = await a.inbox.refresh();
    expect([for (final p in pending) p.proposal.id], ['p2']);
    expect(server.items, hasLength(1));
  });

  test('an item for an app not synced here yet waits for it', () async {
    final pairing = await connect(a);
    await server.deposit(pairing, _proposal('p1'));
    expect(await b.inbox.refresh(), isEmpty);
    expect(server.items, hasLength(1));

    await a.sync.run(records);
    await b.sync.run(records);
    expect((await b.inbox.refresh()).single.proposal.id, 'p1');
  });

  test('expired proposals drop out and cannot be claimed', () async {
    final pairing = await connect(a);
    await server.deposit(pairing, {..._proposal('p1'), 'expires': _t0s + 60});
    final pending = (await a.inbox.refresh()).single;
    a.clock = _t0.add(const Duration(minutes: 2));
    expect(await a.inbox.pending(), isEmpty);
    expect(await a.inbox.claim(pending), InboxClaim.unavailable);
    expect(server.items, hasLength(1));
  });

  test('removing an app revokes the token and the key everywhere', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);
    await server.deposit(pairing, _proposal('p1'));
    expect(await b.inbox.refresh(), hasLength(1));

    a.clock = a.clock.add(const Duration(seconds: 1));
    await a.inbox.removeApp(pairing.appId);
    expect(server.tokens, isEmpty);
    expect(server.items, isEmpty);
    await a.sync.run(records);
    await b.sync.run(records);

    final onB = await b.apps.getApp(pairing.appId);
    expect(onB?.removed, isTrue);
    expect(onB?.key, isNull);
    expect(await b.inbox.pending(), isEmpty);
  });

  test('a stale live copy never revives a removed app', () async {
    final pairing = await connect(a);
    final live = (await a.apps.getApp(pairing.appId))!;
    await a.inbox.removeApp(pairing.appId);
    // A copy dated after the removal, as a peer with a fast clock could send.
    records.plant(await codec.encrypt(DecryptedRecord(
      id: live.recordId,
      kind: RecordKind.inboxApp,
      updatedAt: live.updatedAt + 1000000,
      deviceId: 'B',
      data: live.copyWith(updatedAt: live.updatedAt + 1000000).toJson(),
    )));
    await a.sync.run(records);
    expect((await a.apps.getApp(pairing.appId))?.removed, isTrue);
  });

  test('an unsealed tombstone does not delete an app', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);
    records.plant(EncryptedRecord.tombstone(
      id: 'inboxapp:${pairing.appId}',
      updatedAt: DateTime.now().millisecondsSinceEpoch * 2,
      deviceId: 'server',
    ));
    await b.sync.run(records);
    expect((await b.apps.getApp(pairing.appId))?.key, pairing.key);
  });

  test('statuses past retention are neither published nor applied', () async {
    final pairing = await connect(a);
    final old = InboxStatus(
      appId: pairing.appId,
      proposalId: 'old',
      state: InboxStatusState.ran,
      updatedAt: _t0.millisecondsSinceEpoch - 31 * 86400000,
    );
    await a.statuses.putStatus(old);
    await a.sync.run(records);
    await b.sync.run(records);
    expect(await b.statuses.getStatus(pairing.appId, 'old'), isNull);

    await a.inbox.pruneStatuses();
    expect(await a.statuses.listStatuses(), isEmpty);
  });

  group('resolveInboxTarget', () {
    final app = InboxApp(
      id: newInboxAppId(),
      name: 'bots',
      key: newInboxKey(),
      createdAt: 1,
      updatedAt: 1,
    );
    final servers = [
      _server('1', 'prod-db-1', host: '10.0.0.5'),
      _server('2', 'web', host: 'web.internal'),
      _server('3', 'dup'),
      _server('4', 'DUP'),
    ];

    test('matches the label, then the host, case-insensitively', () {
      expect(resolveInboxTarget('PROD-DB-1', app, servers).server?.id, '1');
      expect(resolveInboxTarget('web.internal', app, servers).server?.id, '2');
    });

    test('never guesses', () {
      expect(
        resolveInboxTarget('nope', app, servers).problem,
        InboxTargetProblem.noMatch,
      );
      expect(
        resolveInboxTarget('dup', app, servers).problem,
        InboxTargetProblem.ambiguous,
      );
    });

    test('honours the app server list', () {
      final limited = app.copyWith(allowedServerIds: const ['2']);
      expect(
        resolveInboxTarget('prod-db-1', limited, servers).problem,
        InboxTargetProblem.notAllowed,
      );
      expect(resolveInboxTarget('web', limited, servers).isAssigned, isTrue);
    });
  });
}
