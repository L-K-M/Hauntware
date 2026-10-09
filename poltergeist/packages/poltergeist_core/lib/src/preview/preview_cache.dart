import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../fs/local_fs_safety.dart';
import 'preview_kinds.dart';

/// 06 §5.3's preview cache: a keyed, capped LRU under the application
/// support directory holding locally-materialized copies of remote
/// files so the preview pane (and macOS Quick Look) can render them.
///
/// Keys are [previewCacheKey]'s cryptographic tuple — server, path,
/// mtime, size — so a changed remote file always re-produces instead of
/// rendering a stale hit. Entries land as `<key>.<sanitized-ext>` under
/// a temporary sibling plus an atomic rename (06 §5.3), so no reader
/// ever observes a partial file. A small JSON index beside the files
/// carries each entry's recorded size and last-used stamp, which is
/// what makes eviction true-LRU across restarts rather than file-mtime
/// order.
///
/// The directory is preview-only by construction (06 §5.3): nothing
/// watches it, reconciles it, or uploads from it — managed checkouts
/// remain the editing path.
///
/// Eviction tolerates unlink failure: a file still open by a renderer
/// (or held by a platform preview) stays indexed and counted, so the
/// cache can sit over budget until the next enforcement pass or the
/// sweep that runs when a preview surface closes.
final class PreviewCache {
  PreviewCache({
    required this.directory,
    int? capacityBytes,
    @visibleForTesting Future<bool> Function(File)? lookupFileExists,
    @visibleForTesting Future<void> Function()? beforeIndexWrite,
    @visibleForTesting Future<void> Function()? beforeMutation,
    @visibleForTesting Future<void> Function()? afterTempPrepared,
    @visibleForTesting Future<void> Function()? beforeTempCommit,
  }) : _capacityBytes = capacityBytes ?? defaultPreviewCacheCapacityBytes,
       _lookupFileExists = lookupFileExists ?? _fileExists,
       _beforeIndexWrite = beforeIndexWrite ?? _skipIndexWriteHook,
       _beforeMutation = beforeMutation ?? _skipMutationHook,
       _afterTempPrepared = afterTempPrepared ?? _skipTempHook,
       _beforeTempCommit = beforeTempCommit ?? _skipTempHook;

  /// The directory the cache owns outright.
  final Directory directory;

  int _capacityBytes;
  final Future<bool> Function(File) _lookupFileExists;
  final Future<void> Function() _beforeIndexWrite;
  final Future<void> Function() _beforeMutation;
  final Future<void> Function() _afterTempPrepared;
  final Future<void> Function() _beforeTempCommit;

  static Future<bool> _fileExists(File file) => file.exists();
  static Future<void> _skipIndexWriteHook() => Future<void>.value();
  static Future<void> _skipMutationHook() => Future<void>.value();
  static Future<void> _skipTempHook() => Future<void>.value();

  /// The live cap. Lowering it evicts on the next [enforce] — the
  /// settings surface calls [enforce] immediately after writing so the
  /// cap applies now, not lazily (06 §5.3).
  int get capacityBytes => _capacityBytes;
  set capacityBytes(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'capacityBytes', 'must be >= 0');
    }
    _capacityBytes = value;
  }

  /// Live entries in LRU order: oldest (evict-first) at the front.
  final LinkedHashMap<String, _PreviewCacheEntry> _entries =
      LinkedHashMap<String, _PreviewCacheEntry>();

  /// Temp files owned by outstanding [PreviewCacheSlot]s — the sweep
  /// skips them; everything else matching the temp pattern is a stale
  /// sibling from a dead run.
  final Set<String> _liveTemps = <String>{};

  /// A cache key has one lookup-to-commit owner across every preview surface.
  final Map<String, _PreviewProductionQueue> _productionQueues = {};

  /// Index snapshots and atomic replacements must keep mutation order.
  Future<void> _indexWriteTail = Future<void>.value();

  /// File, entry, and index mutations form one ordered transaction.
  Future<void> _mutationTail = Future<void>.value();

  bool _opened = false;

  static const String _indexFileName = 'index.json';
  static const int _indexVersion = 1;
  static final RegExp _tempPattern = RegExp(r'^tmp-[A-Za-z0-9-]+\.part$');

  /// Bytes currently committed to the cache.
  int get totalBytes =>
      _entries.values.fold(0, (sum, entry) => sum + entry.bytes);

  /// Snapshot of live keys, oldest first — diagnostics and tests.
  List<String> get keys => List.unmodifiable(_entries.keys);

  /// Creates the directory, sweeps stale temps (no slot outlives a
  /// process restart, so every leftover temp is dead), loads the index
  /// tolerantly, drops entries whose file vanished, and unlinks files
  /// the index doesn't know. A corrupt or newer index is rebuilt empty
  /// rather than failing startup — the contents are disposable by
  /// design.
  Future<void> open() async {
    if (_opened) return;
    await ensureSafeLocalDirectory(directory.path);
    await _sweepTemps(allTempsStale: true);
    await _loadIndex();
    await _reconcile();
    _opened = true;
  }

  /// The committed file for [key], or null on a miss. A hit moves the
  /// entry to the LRU tail and re-stamps its index record (06 §5.3's
  /// recency update). A hit whose file vanished since indexing is a
  /// miss that drops the entry.
  Future<File?> lookup(String key) async {
    final entry = _entries[key];
    if (entry == null) return null;
    final file = File(entry.path);
    final fileExists = await _lookupFileExists(file);

    return _serializeMutation(() async {
      if (!identical(_entries[key], entry)) return null;
      if (!fileExists) {
        _entries.remove(key);
        return null;
      }
      entry.lastUsedMs = DateTime.now().millisecondsSinceEpoch;
      _entries.remove(key);
      _entries[key] = entry;
      await _persistIndex();
      if (!identical(_entries[key], entry)) return null;
      return file;
    });
  }

  /// Reserves [key] across lookup, production and commit.
  ///
  /// A cancelled waiter leaves the queue immediately and never cancels the
  /// current owner. Callers must release the returned reservation in `finally`.
  Future<PreviewProductionReservation?> reserveProduction(
    String key, {
    Future<void>? cancellation,
  }) {
    final queue = _productionQueues.putIfAbsent(
      key,
      _PreviewProductionQueue.new,
    );
    final waiter = _PreviewProductionWaiter();
    if (!queue.held) {
      queue.held = true;
      waiter.completer.complete(
        PreviewProductionReservation._(this, key, queue),
      );
    } else {
      queue.waiters.add(waiter);
    }

    if (cancellation != null) {
      unawaited(
        cancellation.then<void>(
          (_) => _cancelProductionWaiter(key, queue, waiter),
          onError: (Object _, StackTrace __) =>
              _cancelProductionWaiter(key, queue, waiter),
        ),
      );
    }
    return waiter.completer.future;
  }

  void _cancelProductionWaiter(
    String key,
    _PreviewProductionQueue queue,
    _PreviewProductionWaiter waiter,
  ) {
    if (waiter.completer.isCompleted || !queue.waiters.remove(waiter)) return;
    waiter.completer.complete(null);
    if (!queue.held && queue.waiters.isEmpty) {
      _productionQueues.remove(key);
    }
  }

  void _releaseProduction(String key, _PreviewProductionQueue queue) {
    if (!identical(_productionQueues[key], queue) || !queue.held) return;

    while (queue.waiters.isNotEmpty) {
      final next = queue.waiters.removeFirst();
      if (next.completer.isCompleted) continue;
      next.completer.complete(PreviewProductionReservation._(this, key, queue));
      return;
    }

    queue.held = false;
    _productionQueues.remove(key);
  }

  /// Whether a remote file of [sizeBytes] could ever fit — the §5.3
  /// "known to exceed the cache's cap" refusal the pane checks before
  /// queueing anything.
  bool canAccommodate(int sizeBytes) => sizeBytes <= _capacityBytes;

  /// Opens a write slot for [key]: creates the temp sibling and returns
  /// the handle whose [PreviewCacheSlot.commit] renames it into place.
  /// [extension] is sanitized ([sanitizePreviewExtension]) — an unsafe
  /// one is dropped and the committed name carries none at all (06
  /// §5.3). Executable-looking extensions are deliberately KEPT: the
  /// hash-named cache is never executed, and the launch-boundary
  /// blocklist lives in seance_core's `windowsExecutableExtensions` for the
  /// disclosed-location download path instead.
  ///
  /// Throws [StateError] when the key is already committed — callers
  /// dedupe through [lookup] and the produce coordinator; a second
  /// production of the same key is a logic error, not a race to absorb.
  Future<PreviewCacheSlot> prepare(
    String key, {
    String? extension,
    int? expectedBytes,
  }) async {
    if (_entries.containsKey(key)) {
      throw StateError('preview cache key $key is already committed');
    }
    final ext = sanitizePreviewExtension(extension);
    final tempName = 'tmp-${_nextTempId()}.part';
    final temp = File(p.join(directory.path, tempName));
    _liveTemps.add(temp.path);
    try {
      // Protect the name across every await where a sweep could observe it.
      await temp.create(recursive: true, exclusive: true);
      await restrictLocalPathPermissions(temp.path, '600');
      await _afterTempPrepared();
    } on Object {
      _liveTemps.remove(temp.path);
      rethrow;
    }
    return PreviewCacheSlot._(
      cache: this,
      key: key,
      extension: ext,
      temp: temp,
      expectedBytes: expectedBytes,
    );
  }

  /// LRU eviction until [totalBytes] fits [capacityBytes]. Files that
  /// refuse to unlink (still open by a preview surface or the OS)
  /// stay indexed and still count toward the total — the cache may sit
  /// over budget until the next pass (06 §5.3).
  Future<void> enforce() => _serializeMutation(_enforce);

  Future<void> _enforce() async {
    if (totalBytes <= _capacityBytes) return;
    final evicted = <String>[];
    // Evictions land in [_entries] only after the pass, so the loop
    // tracks its own running total — reading the live map mid-pass
    // would keep counting already-deleted bytes and evict everything.
    var remaining = totalBytes;
    for (final entry in _entries.entries.toList()) {
      if (remaining <= _capacityBytes) break;
      try {
        await File(entry.value.path).delete();
        evicted.add(entry.key);
        remaining -= entry.value.bytes;
      } on FileSystemException {
        // Open handle or transient unlink failure: the entry keeps
        // counting and the next enforcement pass (or the surface-close
        // sweep) retries it — never drop the index record while the
        // bytes remain.
        continue;
      }
    }
    for (final key in evicted) {
      _entries.remove(key);
    }
    if (evicted.isNotEmpty) await _persistIndex();
  }

  /// Deletes every committed entry and live temp; returns the bytes
  /// reclaimed — the "Clear Preview Cache" action's report (06 §5.3).
  /// Unlink failures are tolerated and simply not counted.
  Future<int> clear() => _serializeMutation(_clear);

  Future<int> _clear() async {
    var reclaimed = 0;
    for (final entry in _entries.values) {
      try {
        await File(entry.path).delete();
        reclaimed += entry.bytes;
      } on FileSystemException {
        continue;
      }
    }
    _entries.clear();
    await _persistIndex();
    await sweepTemps();
    return reclaimed;
  }

  /// Drops temp siblings that no live slot owns — the startup sweep and
  /// the after-close sweep share this. Live temps are skipped.
  Future<void> sweepTemps() => _sweepTemps(allTempsStale: false);

  Future<void> _sweepTemps({required bool allTempsStale}) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!_tempPattern.hasMatch(name)) continue;
      if (!allTempsStale && _liveTemps.contains(entity.path)) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        continue;
      }
    }
  }

  Future<String> _commit(
    String key,
    String? extension,
    File temp,
    int? expectedBytes,
  ) => _serializeMutation(
    () => _commitEntry(key, extension, temp, expectedBytes),
  );

  Future<String> _commitEntry(
    String key,
    String? extension,
    File temp,
    int? expectedBytes,
  ) async {
    final targetPath = extension == null
        ? p.join(directory.path, key)
        : p.join(directory.path, '$key.$extension');
    final target = File(targetPath);
    try {
      await _beforeTempCommit();
      try {
        await temp.rename(targetPath);
      } on FileSystemException {
        // Cross-device or an existing file at the target (should not
        // happen — the key is fresh): fall back to copy + delete so the
        // commit still lands one whole file.
        await temp.copy(targetPath);
        await temp.delete();
      }
    } finally {
      _liveTemps.remove(temp.path);
    }
    await restrictLocalPathPermissions(targetPath, '600');
    final bytes = await target.length();
    _entries[key] = _PreviewCacheEntry(
      path: targetPath,
      bytes: bytes,
      expectedBytes: expectedBytes,
      lastUsedMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistIndex();
    // A completion that cannot fit even after eviction is dropped —
    // the §5.3 over-cap rule applied to the produced bytes.
    await _enforce();
    if (!_entries.containsKey(key)) {
      // Evicted in the same pass (over-cap completion): remove the file
      // so no orphan survives.
      try {
        await target.delete();
      } on FileSystemException {
        // Still open by a reader racing the drop — the next sweep or
        // enforce pass retries it.
      }
    }
    return targetPath;
  }

  Future<void> _abort(File temp) async {
    _liveTemps.remove(temp.path);
    try {
      await temp.delete();
    } on FileSystemException {
      // A still-open temp: the next sweep retries.
    }
  }

  int _tempCounter = 0;
  String _nextTempId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_tempCounter++}';

  Future<void> _loadIndex() async {
    final indexFile = File(p.join(directory.path, _indexFileName));
    if (!await indexFile.exists()) return;
    Map<String, Object?> decoded;
    try {
      final raw = jsonDecode(await indexFile.readAsString());
      if (raw is! Map<String, Object?> ||
          raw['version'] != _indexVersion ||
          raw['entries'] is! Map<String, Object?>) {
        return; // unreadable or newer schema: rebuild empty
      }
      decoded = raw['entries'] as Map<String, Object?>;
    } on Object {
      return; // corrupt index: rebuild empty, files reconcile below
    }
    // Entries replay oldest-first by recorded last-used so the in-memory
    // order is the persisted LRU order.
    final parsed = <MapEntry<String, _PreviewCacheEntry>>[];
    for (final item in decoded.entries) {
      final value = item.value;
      if (value is! Map<String, Object?>) continue;
      final fileName = value['file'];
      final bytes = value['bytes'];
      final lastUsed = value['lastUsed'];
      if (fileName is! String || bytes is! int || lastUsed is! int) {
        continue;
      }
      parsed.add(
        MapEntry(
          item.key,
          _PreviewCacheEntry(
            path: p.join(directory.path, fileName),
            bytes: bytes,
            expectedBytes: value['expectedBytes'] is int
                ? value['expectedBytes'] as int
                : null,
            lastUsedMs: lastUsed,
          ),
        ),
      );
    }
    parsed.sort((a, b) => a.value.lastUsedMs.compareTo(b.value.lastUsedMs));
    for (final item in parsed) {
      _entries[item.key] = item.value;
    }
  }

  /// Index-vs-disk reconciliation at open: drop index entries whose
  /// file vanished, unlink files the index doesn't know (crash between
  /// rename and persist, or an index rebuilt empty).
  Future<void> _reconcile() async {
    final known = <String>{
      for (final entry in _entries.values) p.basename(entry.path),
      _indexFileName,
    };
    final missing = <String>[];
    for (final item in _entries.entries) {
      if (!await File(item.value.path).exists()) missing.add(item.key);
    }
    for (final key in missing) {
      _entries.remove(key);
    }
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (known.contains(name) || _tempPattern.hasMatch(name)) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        continue;
      }
    }
    await _persistIndex();
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final mutation = _mutationTail.then<T>((_) async {
      await _beforeMutation();
      return operation();
    });
    _mutationTail = mutation.then<void>(
      (_) {},
      // A failed caller must not prevent later mutations from running.
      onError: (Object _, StackTrace __) {},
    );
    return mutation;
  }

  /// Temp-file plus rename — the index is small, so it writes eagerly
  /// on every mutation rather than batching recency updates.
  Future<void> _persistIndex() {
    final write = _indexWriteTail.then((_) => _writeIndex());
    _indexWriteTail = write.then<void>(
      (_) {},
      // A failed caller must not prevent later mutations from persisting.
      onError: (Object _, StackTrace __) {},
    );
    return write;
  }

  Future<void> _writeIndex() async {
    await _beforeIndexWrite();
    final indexPath = p.join(directory.path, _indexFileName);
    final tempPath = p.join(directory.path, 'tmp-index-${_nextTempId()}.json');
    final payload = jsonEncode({
      'version': _indexVersion,
      'entries': {
        for (final item in _entries.entries)
          item.key: {
            'file': p.basename(item.value.path),
            'bytes': item.value.bytes,
            if (item.value.expectedBytes != null)
              'expectedBytes': item.value.expectedBytes,
            'lastUsed': item.value.lastUsedMs,
          },
      },
    });
    final temp = File(tempPath);
    await temp.writeAsString(payload);
    try {
      await temp.rename(indexPath);
    } on FileSystemException {
      try {
        await File(indexPath).delete();
      } on FileSystemException {
        // Absent target — rename was the first write.
      }
      await temp.rename(indexPath);
    }
  }
}

/// Exclusive ownership of one preview cache key's production transaction.
final class PreviewProductionReservation {
  PreviewProductionReservation._(this._cache, this._key, this._queue);

  final PreviewCache _cache;
  final String _key;
  final _PreviewProductionQueue _queue;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _cache._releaseProduction(_key, _queue);
  }
}

final class _PreviewProductionQueue {
  bool held = false;
  final ListQueue<_PreviewProductionWaiter> waiters = ListQueue();
}

final class _PreviewProductionWaiter {
  final completer = Completer<PreviewProductionReservation?>();
}

/// One committed entry's index record — the "actual size recorded as
/// metadata beside it" (06 §5.3) plus the LRU stamp.
final class _PreviewCacheEntry {
  _PreviewCacheEntry({
    required this.path,
    required this.bytes,
    required this.expectedBytes,
    required this.lastUsedMs,
  });

  final String path;
  final int bytes;
  final int? expectedBytes;
  int lastUsedMs;
}

/// The write handle [PreviewCache.prepare] hands a producer: stream the
/// bytes into [tempFile], then [commit] lands them under the cache key
/// atomically — or [abort] discards the partial download so a cancelled
/// or failed production never surfaces a half file (06 §5.3).
final class PreviewCacheSlot {
  PreviewCacheSlot._({
    required this.cache,
    required this.key,
    required this.extension,
    required this.temp,
    required this.expectedBytes,
  });

  final PreviewCache cache;
  final String key;
  final String? extension;
  final File temp;
  final int? expectedBytes;
  bool _settled = false;

  /// The temporary sibling producers write into.
  File get tempFile => temp;

  /// Renames the temp into `<key>[.<ext>]`, records the committed size
  /// in the index, restricts permissions, and runs eviction — the
  /// caller's download must be complete and verified before this runs.
  /// Returns the committed file. An over-cap completion that eviction
  /// cannot fit is dropped (06 §5.3) and this still returns the path —
  /// the caller should check existence when it matters, but normally
  /// the render step that follows immediately re-stats anyway.
  Future<File> commit() async {
    if (_settled) throw StateError('preview cache slot already settled');
    _settled = true;
    final committedPath = await cache._commit(
      key,
      extension,
      temp,
      expectedBytes,
    );
    return File(committedPath);
  }

  /// Discards the temp — cancellation, failure, or a superseded
  /// production. Repeated calls remove bytes a cancelled destination
  /// wrote after the first abort.
  Future<void> abort() async {
    _settled = true;
    await cache._abort(temp);
  }
}
