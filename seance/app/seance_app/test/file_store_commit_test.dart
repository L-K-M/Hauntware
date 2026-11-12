import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_app/services/inbox_stores.dart';
import 'package:seance_core/catalog.dart' show SyncAccountScope;
import 'package:seance_core/seance_core.dart';

import 'support/atomic_write_blocker.dart';

// The stores beside FileConfigStore commit a change to memory only once its
// atomic write succeeds (#661's rule), so a rejected change cannot ride a
// later, unrelated save. A blocked replacement fails independently of the
// writer's temp filename or the test process's permissions.
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-store-commit-');
  });

  tearDown(() => directory.delete(recursive: true));

  Future<AtomicWriteBlocker> blockWrites(File file) =>
      AtomicWriteBlocker(file).create();

  group('FileSnippetStore', () {
    const original = Snippet(
      id: 's1',
      title: 'list',
      body: 'ls -la',
      createdAt: 1,
      updatedAt: 1,
    );
    const unrelated = Snippet(
      id: 's2',
      title: 'disk',
      body: 'df -h',
      createdAt: 1,
      updatedAt: 1,
    );

    test(
      'a failed save keeps the old snippet and cannot ride a later one',
      () async {
        final file = File('${directory.path}/snippets.json');
        final store = FileSnippetStore(file);
        await store.putSnippet(original);
        final blocker = await blockWrites(file);

        await expectLater(
          store.putSnippet(
            const Snippet(
              id: 's1',
              title: 'list',
              body: 'rm -rf /',
              createdAt: 1,
              updatedAt: 2,
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect((await store.getSnippet('s1'))!.body, 'ls -la');
        await blocker.delete();

        await store.putSnippet(unrelated);
        expect((await FileSnippetStore(file).getSnippet('s1'))!.body, 'ls -la');
      },
    );

    test('a failed deletion cannot ride a later save', () async {
      final file = File('${directory.path}/snippets.json');
      final store = FileSnippetStore(file);
      await store.putSnippet(original);
      final blocker = await blockWrites(file);

      await expectLater(
        store.deleteSnippet('s1'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.getSnippet('s1'), isNotNull);
      await blocker.delete();

      await store.putSnippet(unrelated);
      expect(await FileSnippetStore(file).getSnippet('s1'), isNotNull);
    });

    test('cold concurrent saves keep every snippet', () async {
      final file = File('${directory.path}/cold-snippets.json');
      final store = FileSnippetStore(file);
      await Future.wait([
        store.putSnippet(original),
        store.putSnippet(unrelated),
      ]);

      expect(
        (await FileSnippetStore(file).listSnippets()).map((s) => s.id),
        unorderedEquals(['s1', 's2']),
      );
    });
  });

  group('FileTombstoneStore', () {
    test('a failed add cannot ride a later one', () async {
      final file = File('${directory.path}/deleted_records.json');
      final store = FileTombstoneStore(file);
      await store.add(
        EncryptedRecord.tombstone(id: 'kept', updatedAt: 1, deviceId: 'D'),
      );
      final blocker = await blockWrites(file);

      await expectLater(
        store.add(
          EncryptedRecord.tombstone(id: 'failed', updatedAt: 2, deviceId: 'D'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.all()).map((r) => r.id), ['kept']);
      await blocker.delete();

      await store.add(
        EncryptedRecord.tombstone(id: 'later', updatedAt: 3, deviceId: 'D'),
      );
      expect(
        (await FileTombstoneStore(file).all()).map((r) => r.id),
        unorderedEquals(['kept', 'later']),
      );
    });

    test('a failed removal keeps the pending deletion', () async {
      final file = File('${directory.path}/deleted_records.json');
      final store = FileTombstoneStore(file);
      await store.add(
        EncryptedRecord.tombstone(id: 'x', updatedAt: 1, deviceId: 'D'),
      );
      final blocker = await blockWrites(file);

      await expectLater(store.remove('x'), throwsA(isA<FileSystemException>()));
      expect((await store.all()).map((r) => r.id), ['x']);
      await blocker.delete();

      await store.add(
        EncryptedRecord.tombstone(id: 'y', updatedAt: 2, deviceId: 'D'),
      );
      expect(
        (await FileTombstoneStore(file).all()).map((r) => r.id),
        unorderedEquals(['x', 'y']),
      );
    });
  });

  group('FileInboxStatusStore', () {
    test('a failed status cannot ride a later one', () async {
      final file = File('${directory.path}/inbox_statuses.json');
      final store = FileInboxStatusStore(file);
      final blocker = await blockWrites(file);

      await expectLater(
        store.putStatus(
          const InboxStatus(
            appId: 'app',
            proposalId: 'failed',
            state: InboxStatusState.ran,
            updatedAt: 1,
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.getStatus('app', 'failed'), isNull);
      await blocker.delete();

      await store.putStatus(
        const InboxStatus(
          appId: 'app',
          proposalId: 'later',
          state: InboxStatusState.dismissed,
          updatedAt: 2,
        ),
      );
      expect(
        await FileInboxStatusStore(file).getStatus('app', 'failed'),
        isNull,
      );
    });
  });

  group('FileInboxAppStore', () {
    test('a failed app save cannot ride a later one', () async {
      final file = File('${directory.path}/inbox_apps.json');
      final vault = SecretVault(InMemoryVaultStore(), secureRandomBytes(32));
      final store = FileInboxAppStore(file, () => vault);
      InboxApp app(String name) => InboxApp(
        id: newInboxAppId(),
        name: name,
        key: newInboxKey(),
        allowedServerIds: const [],
        createdAt: 1,
        updatedAt: 1,
      );
      final blocker = await blockWrites(file);

      final failed = app('failed');
      await expectLater(
        store.putApp(failed),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.getApp(failed.id), isNull);
      await blocker.delete();

      await store.putApp(app('later'));
      expect(
        await FileInboxAppStore(file, () => vault).getApp(failed.id),
        isNull,
      );
    });

    test('overlapping app saves keep both apps, on disk and in memory', () async {
      final file = File('${directory.path}/inbox_apps.json');
      final vault = SecretVault(InMemoryVaultStore(), secureRandomBytes(32));
      final store = FileInboxAppStore(file, () => vault);
      InboxApp app(String name) => InboxApp(
        id: newInboxAppId(),
        name: name,
        key: newInboxKey(),
        allowedServerIds: const [],
        createdAt: 1,
        updatedAt: 1,
      );
      final first = app('first');
      final second = app('second');

      await Future.wait([store.putApp(first), store.putApp(second)]);

      expect((await store.listApps()).map((a) => a.id), unorderedEquals([first.id, second.id]));
      final reopened = FileInboxAppStore(file, () => vault);
      expect((await reopened.listApps()).map((a) => a.id), unorderedEquals([first.id, second.id]));
    });
  });

  group('FileInboxCacheStore', () {
    test('a failed save keeps the cache it had', () async {
      final file = File('${directory.path}/inbox_cache.json');
      final scope = SyncAccountScope(
        baseUrl: 'https://sync.example',
        username: 'me',
      );
      final store = FileInboxCacheStore(file, scope: scope);
      await store.save(const InboxCache(cursor: 3));
      final blocker = await blockWrites(file);

      await expectLater(
        store.save(const InboxCache(cursor: 9)),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.load()).cursor, 3);
      await blocker.delete();
    });

    test('overlapping saves leave the file and memory on the last one', () async {
      final file = File('${directory.path}/inbox_cache.json');
      final scope = SyncAccountScope(
        baseUrl: 'https://sync.example',
        username: 'me',
      );
      final store = FileInboxCacheStore(file, scope: scope);

      await Future.wait([
        for (var cursor = 1; cursor <= 5; cursor++)
          store.save(InboxCache(cursor: cursor)),
      ]);

      expect((await store.load()).cursor, 5);
      expect((await FileInboxCacheStore(file, scope: scope).load()).cursor, 5);
    });
  });
}
