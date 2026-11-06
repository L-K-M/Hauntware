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
  int deleteAppCalls = 0;
  Object? deleteAppError;
  bool deleteAppReportsMissing = false;

  /// Answer newest first, as a server that does not sort might.
  bool reverse = false;
  Future<void> Function()? beforeList;
  Future<void> Function()? beforeDelete;

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
    deleteAppCalls++;
    if (deleteAppError != null) throw deleteAppError!;
    items.removeWhere((_, item) => item.appId == appId);
    final removed = tokens.remove(appId) != null;
    return deleteAppReportsMissing ? false : removed;
  }

  @override
  Future<List<InboxItem>> listItems({required int since}) async {
    await beforeList?.call();
    final out = items.values.where((i) => i.received > since).toList()
      ..sort((a, b) => a.received.compareTo(b.received));
    return reverse ? out.reversed.toList() : out;
  }

  @override
  Future<bool> deleteItem(String appId, String itemId) async {
    final item = items[itemId];
    if (item == null || item.appId != appId) return false;
    await beforeDelete?.call();
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

class _PagedFakeInbox extends _FakeInbox implements PagedInboxApi {
  _PagedFakeInbox({this.pageSize = 1});

  final int pageSize;
  int pageRequests = 0;
  int? failAfterPages;

  @override
  Stream<InboxPage> listItemPages({required int since}) async* {
    final through = _received;
    var cursor = since;
    while (true) {
      pageRequests++;
      if (failAfterPages != null && pageRequests > failAfterPages!) {
        throw StateError('page failed');
      }
      final pageItems =
          items.values
              .where(
                (item) => item.received > cursor && item.received <= through,
              )
              .toList()
            ..sort((a, b) => a.received.compareTo(b.received));
      final selected = pageItems.take(pageSize).toList();
      final next = selected.isEmpty ? cursor : selected.last.received;
      final hasMore = pageItems.length > selected.length;
      yield InboxPage(
        items: selected,
        throughReceived: through,
        nextReceived: next,
        hasMore: hasMore,
      );
      if (!hasMore) return;
      cursor = next;
    }
  }
}

final class _SensitiveFailure implements Exception {
  final String secret;
  int toStringCalls = 0;

  _SensitiveFailure(this.secret);

  @override
  String toString() {
    toStringCalls++;
    return secret;
  }
}

final class _FailingInboxAppStore implements InboxAppStore {
  final Object error;
  final StackTrace stackTrace;
  InboxApp? attemptedApp;

  _FailingInboxAppStore(this.error, this.stackTrace);

  @override
  Future<InboxApp?> getApp(String id) async => null;

  @override
  Future<List<InboxApp>> listApps() async => const [];

  @override
  Future<void> putApp(InboxApp app) {
    attemptedApp = app;
    return Future<void>.error(error, stackTrace);
  }
}

Future<void> _expectSameFailure(
  Future<Object?> operation,
  Object expectedError,
  StackTrace expectedStack,
) async {
  Object? caughtError;
  StackTrace? caughtStack;
  try {
    await operation;
  } catch (error, stackTrace) {
    caughtError = error;
    caughtStack = stackTrace;
  }
  expect(caughtError, same(expectedError));
  expect(caughtStack, same(expectedStack));
}

final class _FaultingStatusStore implements InboxStatusStore {
  final InboxStatusStore delegate;
  final List<String> events;
  Object? putError;

  _FaultingStatusStore(this.delegate, this.events);

  @override
  Future<void> deleteStatus(String appId, String proposalId) =>
      delegate.deleteStatus(appId, proposalId);

  @override
  Future<InboxStatus?> getStatus(String appId, String proposalId) =>
      delegate.getStatus(appId, proposalId);

  @override
  Future<List<InboxStatus>> listStatuses() => delegate.listStatuses();

  @override
  Future<void> putStatus(InboxStatus status) async {
    events.add('status');
    if (putError != null) throw putError!;
    await delegate.putStatus(status);
  }
}

final class _FaultingCacheStore implements InboxCacheStore {
  final InboxCacheStore delegate;
  final List<String> events;
  Object? saveError;

  _FaultingCacheStore(this.delegate, this.events);

  @override
  Future<InboxCache> load() => delegate.load();

  @override
  Future<void> save(InboxCache cache) async {
    events.add('cache');
    if (saveError != null) throw saveError!;
    await delegate.save(cache);
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
        results.add(
          PushResult(id: incoming.id, seq: existing.seq ?? 0, accepted: false),
        );
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

  Future<InboxPairing> connect(_Device device) =>
      device.inbox.addApp(name: 'bots', serverUrl: 'https://sync.example.com');

  InboxService serviceWith(InboxAppStore apps) => InboxService(
    api: server,
    apps: apps,
    statuses: InMemoryInboxStatusStore(),
    cache: InMemoryInboxCacheStore(),
    now: () => _t0,
  );

  for (final reportsMissing in [false, true]) {
    test('a failed local app write rolls back the server app'
        '${reportsMissing ? ' when it is already absent' : ''}', () async {
      final failure = _SensitiveFailure('local token/key secret');
      final failureStack = StackTrace.current;
      final apps = _FailingInboxAppStore(failure, failureStack);
      server.deleteAppReportsMissing = reportsMissing;

      await _expectSameFailure(
        serviceWith(
          apps,
        ).addApp(name: 'bots', serverUrl: 'https://sync.example.com'),
        failure,
        failureStack,
      );

      expect(apps.attemptedApp, isNotNull);
      expect(server.deleteAppCalls, 1);
      expect(server.tokens, isEmpty);
      expect(failure.toStringCalls, 0);
    });
  }

  test(
    'a rollback failure preserves the local write error and logs types only',
    () async {
      final failure = _SensitiveFailure('local token/key secret');
      final failureStack = StackTrace.current;
      final cleanupFailure = _SensitiveFailure('server token secret');
      final apps = _FailingInboxAppStore(failure, failureStack);
      server.deleteAppError = cleanupFailure;

      await _expectSameFailure(
        serviceWith(
          apps,
        ).addApp(name: 'bots', serverUrl: 'https://sync.example.com'),
        failure,
        failureStack,
      );

      expect(server.deleteAppCalls, 1);
      expect(server.tokens, hasLength(1));
      expect(failure.toStringCalls, 0);
      expect(cleanupFailure.toStringCalls, 0);
    },
  );

  Future<PendingProposal> pendingOnA() async {
    final pairing = await connect(a);
    await server.deposit(pairing, _proposal('p1'));
    return (await a.inbox.refresh()).single;
  }

  InboxService faultingService({
    required _FaultingStatusStore statuses,
    required _FaultingCacheStore cache,
  }) => InboxService(
    api: server,
    apps: a.apps,
    statuses: statuses,
    cache: cache,
    now: () => a.clock,
  );

  test(
    'a claimed item stays claimed when writing its ran status fails',
    () async {
      final pending = await pendingOnA();
      final events = <String>[];
      final failure = _SensitiveFailure('status secret');
      final statuses = _FaultingStatusStore(a.statuses, events)
        ..putError = failure;
      final cache = _FaultingCacheStore(a.cache, events);

      expect(
        await faultingService(statuses: statuses, cache: cache).claim(pending),
        InboxClaim.claimed,
      );
      expect(server.items, isEmpty);
      expect(events, ['status']);
      expect((await a.cache.load()).proposals, hasLength(1));
      expect(failure.toStringCalls, 0);
    },
  );

  test(
    'a claimed item keeps its ran status when cache settlement fails',
    () async {
      final pending = await pendingOnA();
      final events = <String>[];
      final failure = _SensitiveFailure('cache secret');
      final statuses = _FaultingStatusStore(a.statuses, events);
      final cache = _FaultingCacheStore(a.cache, events)..saveError = failure;

      expect(
        await faultingService(statuses: statuses, cache: cache).claim(pending),
        InboxClaim.claimed,
      );
      expect(server.items, isEmpty);
      expect(events, ['status', 'cache']);
      final status = await a.statuses.getStatus(
        pending.app.id,
        pending.proposal.id,
      );
      expect(status?.state, InboxStatusState.ran);
      expect(failure.toStringCalls, 0);
    },
  );

  test(
    'a delete-false claim still reports a cache settlement failure',
    () async {
      final pending = await pendingOnA();
      expect(
        await server.deleteItem(pending.app.id, pending.cached.itemId),
        isTrue,
      );
      final events = <String>[];
      final failure = _SensitiveFailure('cache secret');
      final statuses = _FaultingStatusStore(a.statuses, events);
      final cache = _FaultingCacheStore(a.cache, events)..saveError = failure;

      await expectLater(
        faultingService(statuses: statuses, cache: cache).claim(pending),
        throwsA(same(failure)),
      );
      expect(events, ['cache']);
    },
  );

  test('dismiss still reports a status write failure', () async {
    final pending = await pendingOnA();
    final events = <String>[];
    final failure = _SensitiveFailure('status secret');
    final statuses = _FaultingStatusStore(a.statuses, events)
      ..putError = failure;
    final cache = _FaultingCacheStore(a.cache, events);

    await expectLater(
      faultingService(statuses: statuses, cache: cache).dismiss(pending),
      throwsA(same(failure)),
    );
    expect(server.items, isEmpty);
    expect(events, ['status']);
  });

  test('claim HTTP releases the local gate and rechecks removal', () async {
    final pending = await pendingOnA();
    var active = false;
    Future<T> phase<T>(Future<T> Function() action) async {
      expect(active, isFalse);
      active = true;
      try {
        return await action();
      } finally {
        active = false;
      }
    }

    final inbox = InboxService(
      api: server,
      apps: a.apps,
      statuses: a.statuses,
      cache: a.cache,
      now: () => a.clock,
      localPhaseGate: phase,
    );
    server.beforeDelete = () async {
      expect(active, isFalse, reason: 'HTTP must not hold the mutation phase');
      await phase(
        () => a.apps.putApp(
          pending.app.asRemoved(updatedAt: a.clock.millisecondsSinceEpoch + 1),
        ),
      );
    };
    expect(await inbox.claim(pending), InboxClaim.unavailable);
    expect(
      await a.statuses.getStatus(pending.app.id, pending.proposal.id),
      isNull,
    );
  });

  test(
    'refresh HTTP releases the gate and preserves an in-flight settlement',
    () async {
      final pending = await pendingOnA();
      var active = false;
      Future<T> phase<T>(Future<T> Function() action) async {
        expect(active, isFalse);
        active = true;
        try {
          return await action();
        } finally {
          active = false;
        }
      }

      final inbox = InboxService(
        api: server,
        apps: a.apps,
        statuses: a.statuses,
        cache: a.cache,
        now: () => a.clock,
        localPhaseGate: phase,
      );
      // Re-read an already cached item after another device handled it.
      await a.cache.save(const InboxCache());
      server.beforeList = () async {
        expect(
          active,
          isFalse,
          reason: 'HTTP must not hold the mutation phase',
        );
        await phase(
          () => a.statuses.putStatus(
            InboxStatus(
              appId: pending.app.id,
              proposalId: pending.proposal.id,
              state: InboxStatusState.ran,
              updatedAt: 99,
            ),
          ),
        );
      };
      expect(await inbox.refresh(), isEmpty);
      expect((await a.cache.load()).proposals, isEmpty);
      expect(server.items, isEmpty);
    },
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

  test(
    'refused items are deleted and counted; the key and app are bound',
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
    },
  );

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

  test('an unsorted listing never skips an item waiting for its app', () async {
    final known = await connect(b);
    final unknown = await connect(a);
    await server.deposit(known, _proposal('k1'));
    await server.deposit(unknown, _proposal('u1'));
    await server.deposit(known, _proposal('k2'));
    server.reverse = true;

    expect([for (final p in await b.inbox.refresh()) p.proposal.id]..sort(), [
      'k1',
      'k2',
    ]);
    await a.sync.run(records);
    await b.sync.run(records);
    final ids = [for (final p in await b.inbox.refresh()) p.proposal.id];
    expect(ids, contains('u1'));
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

  test('paged refresh checkpoints each completed page', () async {
    final paged = _PagedFakeInbox(pageSize: 1);
    final device = _Device('paged', paged, codec);
    final pairing = await connect(device);
    await paged.deposit(pairing, _proposal('p1'));
    await paged.deposit(pairing, _proposal('p2'));
    paged.failAfterPages = 1;

    await expectLater(device.inbox.refresh(), throwsStateError);

    final saved = await device.cache.load();
    expect(saved.cursor, 1);
    expect(saved.proposals.single.proposal.id, 'p1');
  });

  test('paged refresh stops after a page blocked by an unknown app', () async {
    final paged = _PagedFakeInbox(pageSize: 1);
    final source = _Device('source', paged, codec);
    final reader = _Device('reader', paged, codec);
    final unknown = await connect(source);
    final known = await connect(reader);
    await paged.deposit(unknown, _proposal('unknown'));
    await paged.deposit(known, _proposal('known'));

    expect(await reader.inbox.refresh(), isEmpty);

    expect(paged.pageRequests, 1);
    expect((await reader.cache.load()).cursor, 0);
    expect((await reader.inbox.refresh()).single.proposal.id, 'known');
    expect((await reader.cache.load()).cursor, 0);
    await source.sync.run(records);
    await reader.sync.run(records);
    final restored = await reader.inbox.refresh();
    expect(restored.map((p) => p.proposal.id).toSet(), {'unknown', 'known'});
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
    records.plant(
      await codec.encrypt(
        DecryptedRecord(
          id: live.recordId,
          kind: RecordKind.inboxApp,
          updatedAt: live.updatedAt + 1000000,
          deviceId: 'B',
          data: live.copyWith(updatedAt: live.updatedAt + 1000000).toJson(),
        ),
      ),
    );
    await a.sync.run(records);
    expect((await a.apps.getApp(pairing.appId))?.removed, isTrue);
  });

  test('a removal is re-dated past an outranking envelope', () async {
    final pairing = await connect(a);
    final live = (await a.apps.getApp(pairing.appId))!;
    a.clock = a.clock.add(const Duration(minutes: 5));
    await a.inbox.removeApp(pairing.appId);
    final removedAt = (await a.apps.getApp(pairing.appId))!.updatedAt;
    // The envelope outranks the removal so the record is applied; the app
    // it carries is older than the removal.
    records.plant(
      await codec.encrypt(
        DecryptedRecord(
          id: live.recordId,
          kind: RecordKind.inboxApp,
          updatedAt: removedAt + 1000000,
          deviceId: 'B',
          data: live.toJson(),
        ),
      ),
    );
    await a.sync.run(records);
    final after = (await a.apps.getApp(pairing.appId))!;
    expect(after.removed, isTrue);
    expect(after.updatedAt, greaterThan(removedAt + 1000000));
  });

  test('a removal outranked by a later edit elsewhere still wins', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);

    // B renames the app under a clock ahead of A's removal, and pushes first.
    b.clock = _t0.add(const Duration(hours: 1));
    await b.inbox.updateApp(pairing.appId, name: 'renamed');
    await b.sync.run(records);
    await a.inbox.removeApp(pairing.appId);
    await a.sync.run(records);
    await b.sync.run(records);

    expect((await a.apps.getApp(pairing.appId))?.removed, isTrue);
    final onB = await b.apps.getApp(pairing.appId);
    expect(onB?.removed, isTrue);
    expect(onB?.key, isNull);
  });

  test('an unsealed tombstone does not delete an app', () async {
    final pairing = await connect(a);
    await a.sync.run(records);
    await b.sync.run(records);
    records.plant(
      EncryptedRecord.tombstone(
        id: 'inboxapp:${pairing.appId}',
        // Far past anything the devices' clock has stamped.
        updatedAt: _t0.millisecondsSinceEpoch + 365 * 86400000,
        deviceId: 'server',
      ),
    );
    await expectLater(b.sync.run(records), throwsA(isA<FormatException>()));
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
