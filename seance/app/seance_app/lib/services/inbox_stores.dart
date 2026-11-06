import 'dart:convert';
import 'dart:io';

import 'package:seance_core/catalog.dart' show SyncAccountScope;
import 'package:seance_core/seance_core.dart';

import 'atomic_file.dart';

const String _keySecretPrefix = 'inbox-key:';

/// JSON-file [InboxAppStore] with each app's key in the vault.
///
/// The file holds only what `servers.json` would: ids, names and the server
/// list. The key is sealed like every other credential, under
/// `inbox-key:<appId>`, which is also what keeps it readable across a vault
/// re-key (the re-key journal covers the vault, not this file). No server
/// names that ref, so the `secret:` sync path never publishes it; it
/// travels only inside the sealed `inboxapp:` record.
///
/// [vault] is a getter because `AppServices.vault` is swapped when the vault
/// unlocks or is re-keyed.
///
/// Single writer by construction: every write comes from `AppState` inside
/// its mutation queue, the sync round included, so flushes never interleave
/// and the file needs no lock of its own.
class FileInboxAppStore implements InboxAppStore {
  final File file;
  final SecretVault Function() vault;
  final Map<String, Map<String, dynamic>> _meta = {};
  bool _loaded = false;

  FileInboxAppStore(this.file, this.vault);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        for (final j in jsonDecode(await file.readAsString()) as List) {
          final map = (j as Map).cast<String, dynamic>();
          _meta[map['id'] as String] = map;
        }
      } catch (_) {
        _meta.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() =>
      writeStringAtomically(file, jsonEncode(_meta.values.toList()));

  /// Null for an app whose key is missing from the vault: it cannot open
  /// anything, and the next sync round brings the key back.
  Future<InboxApp?> _hydrate(Map<String, dynamic> meta) async {
    if (meta['removed'] == true) return InboxApp.fromJson(meta);
    final secret = await vault().getSecret('$_keySecretPrefix${meta['id']}');
    if (secret == null) return null;
    return InboxApp.fromJson({...meta, 'key': secret.value});
  }

  @override
  Future<List<InboxApp>> listApps() async {
    await _load();
    final out = <InboxApp>[];
    for (final meta in _meta.values) {
      final app = await _hydrate(meta);
      if (app != null) out.add(app);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  @override
  Future<InboxApp?> getApp(String id) async {
    await _load();
    final meta = _meta[id];
    return meta == null ? null : _hydrate(meta);
  }

  /// The key first, the metadata second: metadata without its key reads as
  /// absent and is repaired by the next sync, while a key without metadata is
  /// an inert vault entry.
  @override
  Future<void> putApp(InboxApp app) async {
    await _load();
    final json = app.toJson();
    final key = json.remove('key') as String?;
    final secretId = '$_keySecretPrefix${app.id}';
    if (key != null) {
      await vault().putSecret(
        Secret(id: secretId, kind: SecretKind.password, value: key),
      );
    }
    _meta[app.id] = json;
    await _flush();
    if (app.removed) await vault().deleteSecret(secretId);
  }
}

/// JSON-file [InboxStatusStore].
class FileInboxStatusStore implements InboxStatusStore, SyncCollectionHealth {
  final File file;
  final Map<String, InboxStatus> _cache = {};
  bool _loaded = false;
  bool _syncCollectionFailed = false;

  FileInboxStatusStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    _syncCollectionFailed = await hasSyncCollectionRecovery(file);
    if (await file.exists()) {
      try {
        for (final j in jsonDecode(await file.readAsString()) as List) {
          final status = InboxStatus.fromJson((j as Map).cast());
          _cache[status.recordId] = status;
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

  /// Owner-only like the cache: which proposals were run or dismissed, and
  /// when, is a record of activity on the user's servers.
  Future<void> _flush() => writeStringAtomically(
        file,
        jsonEncode([for (final s in _cache.values) s.toJson()]),
        privacy: AtomicFilePrivacy.ownerOnly,
      );

  @override
  bool get syncCollectionFailed => _syncCollectionFailed;

  @override
  Future<void> markSyncCollectionRecovered() async {
    await _load();
    await _flush();
    await clearSyncCollectionRecovery(file);
    _syncCollectionFailed = false;
  }

  @override
  Future<List<InboxStatus>> listStatuses() async {
    await _load();
    return _cache.values.toList();
  }

  @override
  Future<InboxStatus?> getStatus(String appId, String proposalId) async {
    await _load();
    return _cache[InboxStatus.recordIdFor(appId, proposalId)];
  }

  @override
  Future<void> putStatus(InboxStatus status) async {
    await _load();
    _cache[status.recordId] = status;
    await _flush();
  }

  @override
  Future<void> deleteStatus(String appId, String proposalId) async {
    await _load();
    if (_cache.remove(InboxStatus.recordIdFor(appId, proposalId)) != null) {
      await _flush();
    }
  }
}

/// JSON-file [InboxCacheStore], owner-only: the scripts are commands for the
/// user's servers, the same class of content as their shell history.
class FileInboxCacheStore implements InboxCacheStore {
  final File file;
  final SyncAccountScope scope;
  final bool resetExisting;

  InboxCache? _cache;
  bool _loaded = false;

  FileInboxCacheStore(
    this.file, {
    required this.scope,
    this.resetExisting = false,
  });

  static const _version = 1;

  /// Bind the file to [scope] before the account becomes active.
  Future<void> initialize() => _load();

  Future<void> _load() async {
    if (_loaded) return;
    final account = scope;
    if (!await file.exists()) {
      _cache = const InboxCache();
      await _flush();
      _loaded = true;
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (_) {
      await _recoverCorrupt();
      return;
    }
    if (decoded is! Map) {
      await _recoverCorrupt();
      return;
    }

    final document = decoded.cast<String, dynamic>();
    final version = document['version'];
    if (version is int && version != _version) {
      throw FormatException('inbox cache version $version');
    }
    if (version == null) {
      // The legacy cache had no account owner and the old app did not clear
      // it on account switches. It is disposable server data, so claiming it
      // could expose another account's scripts and carry a cursor that skips
      // this account's queue. Bind an empty cache and refetch instead.
      _cache = const InboxCache();
      await _flush();
      _loaded = true;
      return;
    }
    if (version is! int) {
      await _recoverCorrupt();
      return;
    }

    late final SyncAccountScope storedScope;
    late final InboxCache storedCache;
    try {
      storedScope = SyncAccountScope.fromJson(
        (document['account'] as Map).cast<String, dynamic>(),
      );
      storedCache = InboxCache.fromJson(
        (document['cache'] as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      await _recoverCorrupt();
      return;
    }
    if (resetExisting || storedScope != account) {
      _cache = const InboxCache();
      await _flush();
    } else {
      _cache = storedCache;
    }
    _loaded = true;
  }

  Future<void> _recoverCorrupt() async {
    await quarantineCorruptFile(file);
    _cache = const InboxCache();
    await _flush();
    _loaded = true;
  }

  @override
  Future<InboxCache> load() async {
    await _load();
    return _cache!;
  }

  @override
  Future<void> save(InboxCache cache) async {
    await _load();
    _cache = cache;
    await _flush();
  }

  Future<void> _flush() {
    return writeStringAtomically(
      file,
      jsonEncode({
        'version': _version,
        'account': scope.toJson(),
        'cache': (_cache ?? const InboxCache()).toJson(),
      }),
      privacy: AtomicFilePrivacy.ownerOnly,
    );
  }
}
