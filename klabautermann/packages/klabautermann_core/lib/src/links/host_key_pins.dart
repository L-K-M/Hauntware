import 'dart:convert';
import 'dart:io';

import 'package:seance_core/catalog.dart'
    show
        ConflictAwareHostKeyStore,
        FileHostKeyStore,
        HostKeyInstallResult,
        InMemoryConflictAwareHostKeyStore;
import 'package:seance_core/seance_core.dart' show HostKey, HostKeyStore;

import '../settings/instance_lock.dart' show SupportDirectoryAccess;

/// The pin file under the app's support directory (03 §4.10), named as
/// Poltergeist names its own.
const String hostKeysFileName = 'host_keys.json';

/// Opens the engine's host-key pins in [supportDirectory] (03 §4.6,
/// §4.10, D61). With [SupportDirectoryAccess.exclusive] access they are
/// `seance_core`'s [FileHostKeyStore] over [hostKeysFileName], so a pin
/// outlives the engine. Without it another instance may write that file,
/// so the pins it holds are read once and then kept in memory: a pin or
/// re-pin of this run lasts only as long as the engine, and nothing in
/// the directory is written, renamed or created, a damaged file included.
///
/// The engine opens one store and keeps it (P14): each [FileHostKeyStore]
/// loads its file once and then writes its whole cache, so a second
/// instance over the same file would undo the first one's pins. Catalog
/// sync (K49) installs pulled pins through the same instance.
ConflictAwareHostKeyStore openHostKeyPins(
  String supportDirectory, {
  required SupportDirectoryAccess access,
}) {
  final file = File(
    '$supportDirectory${Platform.pathSeparator}$hostKeysFileName',
  );
  return switch (access) {
    SupportDirectoryAccess.exclusive => FileHostKeyStore(file),
    SupportDirectoryAccess.unguarded => _ReadOnlyFilePins(file),
  };
}

/// [_pins] for the links, with each pin the user confirms handed to
/// [_onPinned] once it is stored: `TofuVerifier.pin` puts a first-seen
/// key the user accepted and a changed key they trusted, and nothing
/// else puts. Pulled pins arrive through the catalog's own install path
/// on the same store, never here, so a pin is never published back.
final class PublishingHostKeyStore implements HostKeyStore {
  PublishingHostKeyStore(this._pins, this._onPinned);

  final HostKeyStore _pins;
  final void Function(HostKey pin) _onPinned;

  @override
  Future<List<HostKey>> all() => _pins.all();

  @override
  Future<HostKey?> get(String host, int port) => _pins.get(host, port);

  @override
  Future<void> put(HostKey key) async {
    await _pins.put(key);
    _onPinned(key);
  }
}

/// Pins seeded once from [_file] and then held in memory only.
final class _ReadOnlyFilePins implements ConflictAwareHostKeyStore {
  _ReadOnlyFilePins(this._file);

  final File _file;
  final InMemoryConflictAwareHostKeyStore _pins =
      InMemoryConflictAwareHostKeyStore();

  /// Read on first use, as [FileHostKeyStore] loads its file.
  late final Future<void> _seeded = _seed();

  Future<void> _seed() async {
    final List<HostKey> keys;
    try {
      keys = [
        for (final json in jsonDecode(await _file.readAsString()) as List)
          HostKey.fromJson((json as Map).cast<String, dynamic>()),
      ];
    } on Object {
      // Missing, unreadable or damaged: start empty. Quarantining a
      // damaged file is the writing instance's job, as is every write.
      return;
    }
    for (final key in keys) {
      await _pins.put(key);
    }
  }

  @override
  Future<List<HostKey>> all() => _seeded.then((_) => _pins.all());

  @override
  Future<HostKey?> get(String host, int port) =>
      _seeded.then((_) => _pins.get(host, port));

  @override
  Future<void> put(HostKey key) => _seeded.then((_) => _pins.put(key));

  @override
  Future<HostKeyInstallResult> putIfNoConflict(HostKey key) =>
      _seeded.then((_) => _pins.putIfNoConflict(key));

  @override
  Future<HostKeyInstallResult> replaceIfCurrent(
    HostKey expected,
    HostKey replacement,
  ) => _seeded.then((_) => _pins.replaceIfCurrent(expected, replacement));
}
