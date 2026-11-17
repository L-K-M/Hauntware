import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:seance_core/catalog.dart'
    show ConflictAwareHostKeyStore, HostKeyInstallResult;
import 'package:seance_core/seance_core.dart';

import 'atomic_file.dart';
import 'serialized_operations.dart';

/// Simple JSON-file [ConfigStore]. For a single-user personal tool this is
/// plenty; the proposal's SQLite/drift backend is a drop-in future swap behind
/// the same interface. Secret material never lands here — only references.
class FileConfigStore
    with SerializedOperations
    implements ConfigStore, SyncCollectionHealth {
  final File file;
  final Map<String, ServerConfig> _cache = {};
  bool _loaded = false;
  bool _syncCollectionFailed = false;

  FileConfigStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    _syncCollectionFailed = await hasSyncCollectionRecovery(file);
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final cfg = ServerConfig.fromJson((j as Map).cast<String, dynamic>());
          _cache[cfg.id] = cfg;
        }
      } catch (_) {
        // A corrupt file must not wedge startup: move it aside and start empty.
        _cache.clear();
        await markSyncCollectionRecovery(file);
        _syncCollectionFailed = true;
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush(Map<String, ServerConfig> snapshot) async {
    await writeStringAtomically(
      file,
      jsonEncode(snapshot.values.map((c) => c.toJson()).toList()),
    );
  }

  Future<T> _serialize<T>(Future<T> Function() operation) =>
      serialize(_load, operation);

  Future<void> _mutate(void Function(Map<String, ServerConfig>) update) =>
      _serialize(() async {
        // A failed config write must not publish a new credential reference
        // or let the rejected change ride a later, unrelated successful save.
        // Serialize reads too: callers observe only completed disk commits.
        final candidate = Map<String, ServerConfig>.of(_cache);
        update(candidate);
        await _flush(candidate);
        _cache
          ..clear()
          ..addAll(candidate);
      });

  @override
  bool get syncCollectionFailed => _syncCollectionFailed;

  @override
  Future<void> markSyncCollectionRecovered() => _serialize(() async {
    await _flush(_cache);
    await clearSyncCollectionRecovery(file);
    _syncCollectionFailed = false;
  });

  @override
  Future<List<ServerConfig>> listServers() => _serialize(() async {
    final list = _cache.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  });

  @override
  Future<ServerConfig?> getServer(String id) =>
      _serialize(() async => _cache[id]);

  @override
  Future<void> putServer(ServerConfig config) =>
      _mutate((candidate) => candidate[config.id] = config);

  @override
  Future<void> deleteServer(String id) =>
      _mutate((candidate) => candidate.remove(id));
}

/// Simple JSON-file [SnippetStore]. Non-secret; synced like server configs.
class FileSnippetStore
    with SerializedOperations
    implements SnippetStore, SyncCollectionHealth {
  final File file;
  final Map<String, Snippet> _cache = {};
  bool _loaded = false;
  bool _syncCollectionFailed = false;

  FileSnippetStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    _syncCollectionFailed = await hasSyncCollectionRecovery(file);
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final s = Snippet.fromJson((j as Map).cast<String, dynamic>());
          _cache[s.id] = s;
        }
      } catch (_) {
        _cache.clear();
        await markSyncCollectionRecovery(file);
        _syncCollectionFailed = true;
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush(Map<String, Snippet> snapshot) async {
    await writeStringAtomically(
      file,
      jsonEncode(snapshot.values.map((s) => s.toJson()).toList()),
    );
  }

  // FileConfigStore's rule (#661): operations run one at a time, and a
  // change reaches memory only once its write succeeded, so a rejected
  // change cannot ride a later, unrelated save.
  Future<T> _serialize<T>(Future<T> Function() operation) =>
      serialize(_load, operation);

  Future<void> _mutate(void Function(Map<String, Snippet>) update) =>
      _serialize(() async {
        final candidate = Map<String, Snippet>.of(_cache);
        update(candidate);
        await _flush(candidate);
        _cache
          ..clear()
          ..addAll(candidate);
      });

  @override
  bool get syncCollectionFailed => _syncCollectionFailed;

  @override
  Future<void> markSyncCollectionRecovered() => _serialize(() async {
    await _flush(_cache);
    await clearSyncCollectionRecovery(file);
    _syncCollectionFailed = false;
  });

  @override
  Future<List<Snippet>> listSnippets() => _serialize(() async {
    final list = _cache.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return list;
  });

  @override
  Future<Snippet?> getSnippet(String id) => _serialize(() async => _cache[id]);

  @override
  Future<void> putSnippet(Snippet snippet) =>
      _mutate((candidate) => candidate[snippet.id] = snippet);

  @override
  Future<void> deleteSnippet(String id) =>
      _mutate((candidate) => candidate.remove(id));
}

/// JSON-file [TombstoneStore]: the deletions this device still owes the sync
/// server. Each entry is an [EncryptedRecord] tombstone (empty blob, no vault
/// key needed to mint), persisted so a delete survives an app restart before
/// the next sync pushes it. `SyncCoordinator` prunes an entry once the server
/// has taken it, so the file stays small.
///
/// Unlike the sealed record blobs, entries here are plaintext (record id,
/// deletion timestamp, deviceId) — the same class of metadata `servers.json`
/// already stores in the clear, and it also travels to the sync server as the
/// tombstone record. Server and snippet ids are random `uuidV4`s, so an id
/// reveals only that *something* was deleted and when, not what.
class FileTombstoneStore with SerializedOperations implements TombstoneStore {
  final File file;
  final Map<String, EncryptedRecord> _cache = {};
  bool _loaded = false;

  FileTombstoneStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final r = EncryptedRecord.fromJson(
            (j as Map).cast<String, dynamic>(),
          );
          _cache[r.id] = r;
        }
      } catch (error, stackTrace) {
        // Unlike a corrupt config/snippet file (re-fetched on the next pull),
        // losing pending deletions silently means deleted items reappear with
        // nothing in the logs to say why — so this one failure gets a warning
        // before it is quarantined and the pending deletes are dropped.
        developer.log(
          'Could not read ${file.path}; pending deletion tombstones were '
          'dropped and deleted items may reappear on the next sync',
          name: 'seance.app',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
        _cache.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush(Map<String, EncryptedRecord> snapshot) async {
    await writeStringAtomically(
      file,
      jsonEncode(snapshot.values.map((r) => r.toJson()).toList()),
    );
  }

  // FileConfigStore's rule (#661): one operation at a time, and memory
  // takes a change only once its write succeeded. A failed add must not
  // ride a later one, and a failed removal keeps the deletion pending.
  Future<T> _serialize<T>(Future<T> Function() operation) =>
      serialize(_load, operation);

  /// Writes the candidate [update] makes when it reports a change, then
  /// commits it to memory.
  Future<void> _mutate(bool Function(Map<String, EncryptedRecord>) update) =>
      _serialize(() async {
        final candidate = Map<String, EncryptedRecord>.of(_cache);
        if (!update(candidate)) return;
        await _flush(candidate);
        _cache
          ..clear()
          ..addAll(candidate);
      });

  @override
  Future<List<EncryptedRecord>> all() =>
      _serialize(() async => _cache.values.toList());

  @override
  Future<void> add(EncryptedRecord tombstone) => _mutate((candidate) {
    final existing = candidate[tombstone.id];
    // Monotonic (see [TombstoneStore]): a retry or double-delete after the
    // row is gone recomputes a bare-"now" stamp that can trail a pending
    // skew-beating tombstone; keeping the higher stamp stops a regression
    // that would lose last-write-wins and resurrect the row.
    if (existing != null && existing.updatedAt > tombstone.updatedAt) {
      return false;
    }
    candidate[tombstone.id] = tombstone;
    return true;
  });

  @override
  Future<void> remove(String id) => _mutate(
    // Skip the rewrite when nothing was pending: saveServer/saveSnippet
    // call remove() on every save, so without this a delete-free install
    // would create and rewrite the file on each save.
    (candidate) => candidate.remove(id) != null,
  );
}

/// JSON-file [HostKeyStore] for pinned TOFU keys. Conflict-aware, so sync
/// writes a pulled pin only when it agrees with the local one (Séance #56).
///
/// Use one instance per [file]. Separate instances do not coordinate writes.
class FileHostKeyStore
    implements ConflictAwareHostKeyStore, SyncCollectionHealth {
  final File file;
  final Map<String, HostKey> _keys = {};
  bool _loaded = false;
  bool _syncCollectionFailed = false;
  Future<void> _pending = Future<void>.value();

  FileHostKeyStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    _syncCollectionFailed = await hasSyncCollectionRecovery(file);
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final k = HostKey.fromJson((j as Map).cast<String, dynamic>());
          _keys[k.locator] = k;
        }
      } catch (_) {
        _keys.clear();
        await markSyncCollectionRecovery(file);
        _syncCollectionFailed = true;
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush(Map<String, HostKey> keys) async {
    await writeStringAtomically(
      file,
      jsonEncode(keys.values.map((k) => k.toJson()).toList()),
    );
  }

  /// Keep the cache and each atomic snapshot in one operation order.
  ///
  /// Bodies must not call another method on this store or the queue deadlocks.
  Future<T> _serialize<T>(Future<T> Function() body) {
    final operation = _pending.then((_) async {
      await _load();
      return body();
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  Future<List<HostKey>> all() => _serialize(() async => _keys.values.toList());

  @override
  Future<HostKey?> get(String host, int port) =>
      _serialize(() async => _keys[hostKeyLocator(host, port)]);

  @override
  Future<void> put(HostKey key) => _serialize(() => _write(key));

  @override
  Future<HostKeyInstallResult> putIfNoConflict(HostKey key) =>
      _serialize(() async {
        final current = _keys[key.locator];
        if (current != null && current.conflictsWith(key)) {
          return HostKeyInstallResult.conflict;
        }

        await _write(key);
        return HostKeyInstallResult.installed;
      });

  @override
  Future<HostKeyInstallResult> replaceIfCurrent(
    HostKey expected,
    HostKey replacement,
  ) async {
    // Async, so a mismatch fails the returned future like every other
    // error of this store.
    if (expected.locator != replacement.locator) {
      throw ArgumentError.value(
        replacement.locator,
        'replacement',
        'must use the expected host-key locator',
      );
    }

    return _serialize(() async {
      final current = _keys[expected.locator];
      if (current == null ||
          current.fingerprintSha256 != expected.fingerprintSha256) {
        return HostKeyInstallResult.conflict;
      }

      await _write(replacement);
      return HostKeyInstallResult.installed;
    });
  }

  /// Only inside [_serialize]: the cache follows the file once it is written.
  Future<void> _write(HostKey key) async {
    final next = Map<String, HostKey>.of(_keys)..[key.locator] = key;
    await _flush(next);

    _keys
      ..clear()
      ..addAll(next);
  }

  @override
  bool get syncCollectionFailed => _syncCollectionFailed;

  @override
  Future<void> markSyncCollectionRecovered() => _serialize(() async {
    await _flush(_keys);
    await clearSyncCollectionRecovery(file);
    _syncCollectionFailed = false;
  });
}
