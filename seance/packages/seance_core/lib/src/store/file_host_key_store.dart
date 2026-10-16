import 'dart:convert';
import 'dart:io';

import 'package:seance_protocol/seance_protocol.dart';

import '../catalog/atomic_file_writer.dart';
import '../catalog/host_key_mutations.dart';
import 'corrupt_file_quarantine.dart';

/// JSON-file [ConflictAwareHostKeyStore] for pinned TOFU keys: one array of
/// [HostKey.toJson] maps, rewritten whole on every mutation through the
/// `atomicWriter` seam, which defaults to [AtomicFileWriter] at the process
/// default mode.
///
/// Loads and mutations run one at a time in call order, and the cache
/// changes only after the write lands, so a failed write leaves both as
/// they were. A corrupt file is quarantined and the store starts empty.
/// Keep one instance per file: each instance loads once and then writes
/// its whole cache, so two over one path would undo each other's pins.
///
/// Moved from Poltergeist's app `file_stores.dart`
/// (docs/design/catalog-library.md section 8).
class FileHostKeyStore implements ConflictAwareHostKeyStore {
  final File file;
  final Future<void> Function(File target, String contents) _atomicWriter;
  final Map<String, HostKey> _keys = {};
  bool _loaded = false;
  Future<void> _pending = Future<void>.value();

  FileHostKeyStore(
    this.file, {
    Future<void> Function(File target, String contents)? atomicWriter,
  }) : _atomicWriter = atomicWriter ?? const AtomicFileWriter().write;

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final k = HostKey.fromJson((j as Map).cast<String, dynamic>());
          _keys[k.locator] = k;
        }
      } catch (_) {
        _keys.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush(Map<String, HostKey> keys) async {
    await _atomicWriter(
      file,
      jsonEncode(keys.values.map((key) => key.toJson()).toList()),
    );
  }

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
      _serialize(() async => _keys['$host:$port']);

  @override
  Future<void> put(HostKey key) => _serialize(() async {
    final next = Map<String, HostKey>.of(_keys)..[key.locator] = key;
    await _flush(next);

    _keys
      ..clear()
      ..addAll(next);
  });

  @override
  Future<HostKeyInstallResult> putIfNoConflict(HostKey key) =>
      _serialize(() async {
        final current = _keys[key.locator];
        if (current != null && current.conflictsWith(key)) {
          return HostKeyInstallResult.conflict;
        }

        final next = Map<String, HostKey>.of(_keys)..[key.locator] = key;
        await _flush(next);

        _keys
          ..clear()
          ..addAll(next);
        return HostKeyInstallResult.installed;
      });

  @override
  Future<HostKeyInstallResult> replaceIfCurrent(
    HostKey expected,
    HostKey replacement,
  ) {
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

      final next = Map<String, HostKey>.of(_keys)
        ..[replacement.locator] = replacement;
      await _flush(next);

      _keys
        ..clear()
        ..addAll(next);
      return HostKeyInstallResult.installed;
    });
  }
}
