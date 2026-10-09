// Contract tests for the keyed LRU preview cache (06 §5.3): temp-plus-
// rename commits, recency-true eviction, startup sweep, cap enforcement,
// launch-boundary executable list, and clear-cache accounting.

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late PreviewCache cache;

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-pc-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    cache = PreviewCache(directory: Directory('${tempDir.path}/cache'));
    await cache.open();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> commitEntry(
    String key,
    List<int> bytes, {
    String extension = 'txt',
  }) async {
    final slot = await cache.prepare(key, extension: extension);
    await slot.tempFile.writeAsBytes(bytes);
    return slot.commit();
  }

  test('prepare/commit lands a keyed file atomically', () async {
    final key = previewCacheKey('srv', '/a.txt', null, 3);
    final file = await commitEntry(key, [1, 2, 3]);
    expect(file.existsSync(), isTrue);
    expect(file.path, endsWith('$key.txt'));
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(cache.totalBytes, 3);
    expect(cache.keys, [key]);
  });

  test('lookup hits and refreshes LRU order', () async {
    final a = previewCacheKey('s', '/a', null, 1);
    final b = previewCacheKey('s', '/b', null, 1);
    final c = previewCacheKey('s', '/c', null, 1);
    await commitEntry(a, [1]);
    await commitEntry(b, [2]);
    await commitEntry(c, [3]);
    expect(cache.keys, [a, b, c]);
    // A hit moves the entry to the tail.
    expect(await cache.lookup(a), isNotNull);
    expect(cache.keys, [b, c, a]);
    // A miss is null and does not disturb the order.
    expect(await cache.lookup('nope'), isNull);
    expect(cache.keys, [b, c, a]);
  });

  test('concurrent lookups see the same committed entry', () async {
    final key = previewCacheKey('s', '/shared', null, 1);
    await commitEntry(key, [1]);

    final results = await Future.wait([cache.lookup(key), cache.lookup(key)]);

    expect(results, everyElement(isNotNull));
  });

  test('lookup does not restore an entry cleared while awaiting I/O', () async {
    final key = previewCacheKey('s', '/clear-race', null, 1);
    await commitEntry(key, [1]);

    final lookupStarted = Completer<void>();
    final existenceResult = Completer<bool>();
    cache = PreviewCache(
      directory: cache.directory,
      lookupFileExists: (_) {
        lookupStarted.complete();
        return existenceResult.future;
      },
    );
    await cache.open();

    final lookup = cache.lookup(key);
    await lookupStarted.future;
    await cache.clear();
    existenceResult.complete(true);

    expect(await lookup, isNull);
    expect(cache.keys, isEmpty);
  });

  test(
    'production reservations serialize and drop cancelled waiters',
    () async {
      final owner = await cache.reserveProduction('shared');
      final cancellation = Completer<void>();
      final cancelled = cache.reserveProduction(
        'shared',
        cancellation: cancellation.future,
      );
      final next = cache.reserveProduction('shared');

      cancellation.complete();
      expect(await cancelled, isNull);
      var nextReady = false;
      unawaited(next.then((_) => nextReady = true));
      await Future<void>.delayed(Duration.zero);
      expect(nextReady, isFalse);

      owner!.release();
      final acquired = await next;
      expect(acquired, isNotNull);
      acquired!.release();
    },
  );

  test('lookup drops an index entry whose file vanished', () async {
    final key = previewCacheKey('s', '/gone', null, 1);
    final file = await commitEntry(key, [1]);
    await file.delete();
    expect(await cache.lookup(key), isNull);
    expect(cache.keys, isEmpty);
  });

  test('prepare refuses an already-committed key', () async {
    final key = previewCacheKey('s', '/dup', null, 1);
    await commitEntry(key, [1]);
    expect(() => cache.prepare(key, extension: 'txt'), throwsStateError);
  });

  test('abort discards the temp without touching the index', () async {
    final key = previewCacheKey('s', '/aborted', null, 1);
    final slot = await cache.prepare(key, extension: 'txt');
    await slot.tempFile.writeAsBytes([9]);
    await slot.abort();
    expect(slot.tempFile.existsSync(), isFalse);
    expect(cache.totalBytes, 0);
    expect(await cache.lookup(key), isNull);
  });

  test('abort removes a temp recreated by a late writer', () async {
    final key = previewCacheKey('s', '/late-write', null, 1);
    final slot = await cache.prepare(key, extension: 'txt');
    await slot.abort();

    await slot.tempFile.writeAsBytes([9]);
    await slot.abort();

    expect(slot.tempFile.existsSync(), isFalse);
    expect(cache.totalBytes, 0);
  });

  test('sweep preserves a temp while prepare registers it', () async {
    late PreviewCache racedCache;
    racedCache = PreviewCache(
      directory: cache.directory,
      afterTempPrepared: () => racedCache.sweepTemps(),
    );
    await racedCache.open();

    final key = previewCacheKey('s', '/prepare-sweep', null, 1);
    final slot = await racedCache.prepare(key, extension: 'txt');

    expect(slot.tempFile.existsSync(), isTrue);
    await slot.abort();
  });

  test('sweep preserves a live temp through commit rename', () async {
    late PreviewCache racedCache;
    racedCache = PreviewCache(
      directory: cache.directory,
      beforeTempCommit: () => racedCache.sweepTemps(),
    );
    await racedCache.open();

    final key = previewCacheKey('s', '/commit-sweep', null, 1);
    final slot = await racedCache.prepare(key, extension: 'txt');
    await slot.tempFile.writeAsBytes([1]);

    final committed = await slot.commit();

    expect(committed.existsSync(), isTrue);
    expect(await committed.readAsBytes(), [1]);
  });

  test('evicts LRU-first when a commit crosses the cap', () async {
    cache.capacityBytes = 3;
    final a = previewCacheKey('s', '/a', null, 2);
    final b = previewCacheKey('s', '/b', null, 2);
    await commitEntry(a, [1, 1]);
    await commitEntry(b, [2, 2]);
    // b's commit pushed totalBytes to 4 > 3: a (the LRU head) evicts.
    expect(await cache.lookup(a), isNull);
    expect(File('${cache.directory.path}/$a.txt').existsSync(), isFalse);
    expect(await cache.lookup(b), isNotNull);
    expect(cache.totalBytes, 2);
  });

  test('an over-cap completion is dropped after eviction', () async {
    cache.capacityBytes = 2;
    final big = previewCacheKey('s', '/big', null, null);
    final file = await commitEntry(big, [1, 2, 3]);
    // Cannot ever fit — the commit drops it.
    expect(file.existsSync(), isFalse);
    expect(cache.keys, isEmpty);
    expect(cache.totalBytes, 0);
  });

  test('canAccommodate gates the pre-queue refusal', () {
    cache.capacityBytes = 10;
    expect(cache.canAccommodate(10), isTrue);
    expect(cache.canAccommodate(11), isFalse);
  });

  test('lowering the cap evicts on the next enforce', () async {
    final a = previewCacheKey('s', '/a', null, 3);
    final b = previewCacheKey('s', '/b', null, 3);
    await commitEntry(a, [1, 1, 1]);
    await commitEntry(b, [2, 2, 2]);
    cache.capacityBytes = 3;
    await cache.enforce();
    expect(await cache.lookup(a), isNull);
    expect(await cache.lookup(b), isNotNull);
  });

  test('an unlink failure leaves the entry indexed and over budget', () async {
    final key = previewCacheKey('s', '/held', null, 5);
    final file = await commitEntry(key, [1, 2, 3, 4, 5]);
    // Simulate a still-open file the OS refuses to unlink: rename the
    // file out from under the index so delete() fails with notFound —
    // the entry must stay indexed (the bytes are still counted).
    final hidden = File('${tempDir.path}/held-aside');
    await file.rename(hidden.path);
    cache.capacityBytes = 0;
    await cache.enforce();
    expect(cache.keys, [key], reason: 'failed unlink keeps the entry');
    expect(cache.totalBytes, 5);
    // Restore and retry: the next pass succeeds.
    await hidden.rename(file.path);
    await cache.enforce();
    expect(cache.keys, isEmpty);
    expect(cache.totalBytes, 0);
  });

  test('index survives a reopen with LRU order intact', () async {
    final a = previewCacheKey('s', '/a', null, 1);
    final b = previewCacheKey('s', '/b', null, 1);
    await commitEntry(a, [1]);
    await commitEntry(b, [2]);
    await cache.lookup(a); // refresh a to the tail

    final reopened = PreviewCache(directory: cache.directory);
    await reopened.open();
    expect(reopened.keys, [b, a]);
    expect(await reopened.lookup(a), isNotNull);
  });

  test('concurrent distinct commits persist one complete index', () async {
    var trackWrites = false;
    var activeWrites = 0;
    var maximumActiveWrites = 0;
    final releaseWrites = Completer<void>();
    cache = PreviewCache(
      directory: cache.directory,
      beforeIndexWrite: () async {
        if (!trackWrites) return;

        activeWrites++;
        maximumActiveWrites = activeWrites > maximumActiveWrites
            ? activeWrites
            : maximumActiveWrites;
        if (activeWrites == 2 && !releaseWrites.isCompleted) {
          releaseWrites.complete();
        }
        try {
          await releaseWrites.future.timeout(
            const Duration(milliseconds: 100),
            onTimeout: () {
              if (!releaseWrites.isCompleted) releaseWrites.complete();
            },
          );
        } finally {
          activeWrites--;
        }
      },
    );
    await cache.open();

    final a = previewCacheKey('s', '/concurrent-a', null, 1);
    final b = previewCacheKey('s', '/concurrent-b', null, 1);
    final aSlot = await cache.prepare(a, extension: 'txt');
    final bSlot = await cache.prepare(b, extension: 'txt');
    await aSlot.tempFile.writeAsBytes([1]);
    await bSlot.tempFile.writeAsBytes([2]);

    trackWrites = true;
    await Future.wait([aSlot.commit(), bSlot.commit()]);

    final reopened = PreviewCache(directory: cache.directory);
    await reopened.open();
    expect(maximumActiveWrites, 1);
    expect(reopened.keys, unorderedEquals(<String>[a, b]));
  });

  test('clear and commit serialize cache mutation transactions', () async {
    final oldA = previewCacheKey('s', '/old-a', null, 1);
    final oldB = previewCacheKey('s', '/old-b', null, 1);
    await commitEntry(oldA, [1]);
    await commitEntry(oldB, [2]);

    var trackMutations = false;
    var activeMutations = 0;
    var maximumActiveMutations = 0;
    cache = PreviewCache(
      directory: cache.directory,
      beforeMutation: () async {
        if (!trackMutations) return;

        activeMutations++;
        maximumActiveMutations = activeMutations > maximumActiveMutations
            ? activeMutations
            : maximumActiveMutations;
        try {
          await Future<void>.delayed(Duration.zero);
        } finally {
          activeMutations--;
        }
      },
    );
    await cache.open();

    final fresh = previewCacheKey('s', '/fresh', null, 1);
    final slot = await cache.prepare(fresh, extension: 'txt');
    await slot.tempFile.writeAsBytes([3]);

    trackMutations = true;
    final clear = cache.clear();
    final commit = slot.commit();
    expect(await clear, 2);
    final committed = await commit;

    final reopened = PreviewCache(directory: cache.directory);
    await reopened.open();
    expect(maximumActiveMutations, 1);
    expect(committed.existsSync(), isTrue);
    expect(reopened.keys, [fresh]);
  });

  test('open sweeps stale temps and unindexed files', () async {
    final dir = cache.directory;
    await File('${dir.path}/tmp-deadbeef.part').writeAsBytes([1]);
    await File('${dir.path}/orphan.txt').writeAsBytes([2]);
    final live = previewCacheKey('s', '/live', null, 1);
    await commitEntry(live, [3]);

    final reopened = PreviewCache(directory: dir);
    await reopened.open();
    expect(File('${dir.path}/tmp-deadbeef.part').existsSync(), isFalse);
    expect(File('${dir.path}/orphan.txt').existsSync(), isFalse);
    expect(await reopened.lookup(live), isNotNull);
  });

  test('a corrupt index rebuilds empty and sweeps the orphans', () async {
    final key = previewCacheKey('s', '/x', null, 1);
    await commitEntry(key, [1]);
    await File('${cache.directory.path}/index.json').writeAsString('not json{');

    final reopened = PreviewCache(directory: cache.directory);
    await reopened.open();
    expect(reopened.keys, isEmpty);
    // The orphaned data file is swept too — the rebuilt index is truth.
    expect(File('${cache.directory.path}/$key.txt').existsSync(), isFalse);
  });

  test('clear deletes everything and reports reclaimed bytes', () async {
    await commitEntry(previewCacheKey('s', '/a', null, 2), [1, 1]);
    await commitEntry(previewCacheKey('s', '/b', null, 3), [2, 2, 2]);
    expect(await cache.clear(), 5);
    expect(cache.totalBytes, 0);
    expect(cache.keys, isEmpty);
    final leftovers = await cache.directory
        .list()
        .where((e) => e is File)
        .toList();
    expect(
      leftovers.map((e) => e.uri.pathSegments.last),
      everyElement('index.json'),
    );
  });

  test(
    'executable extensions are kept — the cache is never executed',
    () async {
      // 06 §5.3: `.bat`/`.exe` pass the charset rule and stay on the cache
      // name (Quick Look keys type off it); the launch-boundary blocklist
      // lives in windowsExecutableExtensions, not the write path.
      final key = previewCacheKey('s', '/setup.exe', null, 1);
      final file = await commitEntry(key, [1], extension: 'exe');
      expect(file.path, endsWith('$key.exe'));
    },
  );

  test('unsafe extensions drop from the committed name', () async {
    // An "extension" carrying characters illegal in local filenames
    // (or overlong) never reaches disk — the name falls back to the
    // bare hash, which content sniffing serves.
    final key = previewCacheKey('s', '/x', null, 1);
    final file = await commitEntry(key, [1], extension: 'a b');
    expect(file.path, endsWith('${Platform.pathSeparator}$key'));
    final overlong = await commitEntry(previewCacheKey('s', '/y', null, 1), [
      1,
    ], extension: 'a' * 17);
    expect(overlong.path, isNot(contains('.')));
  });
}
