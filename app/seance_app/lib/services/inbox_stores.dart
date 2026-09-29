import 'dart:convert';
import 'dart:io';

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
class FileInboxStatusStore implements InboxStatusStore {
  final File file;
  final Map<String, InboxStatus> _cache = {};
  bool _loaded = false;

  FileInboxStatusStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        for (final j in jsonDecode(await file.readAsString()) as List) {
          final status = InboxStatus.fromJson((j as Map).cast());
          _cache[status.recordId] = status;
        }
      } catch (_) {
        _cache.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() => writeStringAtomically(
        file,
        jsonEncode([for (final s in _cache.values) s.toJson()]),
      );

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
  InboxCache? _cache;

  FileInboxCacheStore(this.file);

  @override
  Future<InboxCache> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    var loaded = const InboxCache();
    if (await file.exists()) {
      try {
        loaded = InboxCache.fromJson(
          (jsonDecode(await file.readAsString()) as Map).cast(),
        );
      } catch (_) {
        await quarantineCorruptFile(file);
      }
    }
    return _cache = loaded;
  }

  @override
  Future<void> save(InboxCache cache) async {
    _cache = cache;
    await writeStringAtomically(
      file,
      jsonEncode(cache.toJson()),
      privacy: AtomicFilePrivacy.ownerOnly,
    );
  }
}
