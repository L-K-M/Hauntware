/// The engine's durable pin verdicts and decode tripwires (03 §4.10, D62):
/// the catalog library's `PinVerdictStore` and `SyncTripwireStore` seams
/// over files of their own under the support directory, never the record
/// store, whose corruption quarantine restarts it empty and would erase
/// the verdicts guarding against the same failure
/// (docs/design/catalog-library.md section 4).
library;

import 'dart:async';
import 'dart:io';

import 'package:seance_core/catalog.dart'
    show PinVerdictStore, SyncTripwireStore;

import '../settings/device_settings_store.dart' show writeFileAtomically;
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'sync_state_file.dart';

/// The pin verdicts file under the support directory (03 §4.10).
const String pinVerdictsFileName = 'pin_verdicts.json';

/// The decode tripwire file under the support directory (03 §4.10).
const String syncTripwiresFileName = 'sync_tripwires.json';

const String _negativePinsKey = 'negativePins';
const String _keptVerdictsKey = 'keptVerdicts';
const String _trippedIdsKey = 'trippedIds';

/// `pin_verdicts.json`: `{"version": 1, "negativePins": [locators],
/// "keptVerdicts": {locator: rejected fingerprint}}`, both sorted, a
/// locator being `host:port`.
///
/// The engine owns it (D18) and keeps one instance per file: each loads
/// once and then writes its whole state. A change applies in memory before
/// it is written and stays applied when the write fails: the call throws,
/// and the next write carries it. Changes queue, so the file holds the
/// last one. See [SyncStateFile] for damaged files and unguarded access.
final class FilePinVerdictStore implements PinVerdictStore {
  FilePinVerdictStore._(this._file, this._negative, this._kept);

  final SyncStateFile _file;
  final Set<String> _negative;
  final Map<String, String> _kept;

  /// Opens `pin_verdicts.json` in [supportDirectory]. Never throws; a file
  /// it cannot use leaves the store empty and is reported in [issue].
  /// [writer] and [now] are seams for tests.
  static Future<FilePinVerdictStore> open(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    SyncStateWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    final (file, body) = await SyncStateFile.open(
      File(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$pinVerdictsFileName',
      ),
      access: access,
      decode: _decode,
      writer: writer,
      now: now,
    );
    return FilePinVerdictStore._(file, body?.negative ?? {}, body?.kept ?? {});
  }

  /// The problem met while opening, or null when the file was fine or
  /// absent.
  SyncStateIssue? get issue => _file.issue;

  @override
  Future<Set<String>> negativePins() async => Set.of(_negative);

  @override
  Future<void> addNegativePin(String locator) {
    // Forgetting the host also drops its kept verdict (the seam's
    // contract): the verdict belonged to the forgotten trust decision.
    final added = _negative.add(locator);
    final dropped = _kept.remove(locator) != null;
    return added || dropped || _file.hasUnsavedChanges
        ? _save()
        : Future.value();
  }

  @override
  Future<void> removeNegativePin(String locator) =>
      _negative.remove(locator) || _file.hasUnsavedChanges
      ? _save()
      : Future.value();

  @override
  Future<String?> rejectedFingerprintFor(String locator) async =>
      _kept[locator];

  @override
  Future<void> recordKeptVerdict(String locator, String rejectedFingerprint) {
    if (_kept[locator] == rejectedFingerprint && !_file.hasUnsavedChanges) {
      return Future.value();
    }
    _kept[locator] = rejectedFingerprint;
    return _save();
  }

  Future<void> _save() => _file.save({
    _negativePinsKey: _negative.toList()..sort(),
    _keptVerdictsKey: <String, String>{
      for (final locator in _kept.keys.toList()..sort())
        locator: _kept[locator]!,
    },
  });

  static ({Set<String> negative, Map<String, String> kept}) _decode(
    Map<String, Object?> body,
  ) {
    final kept = <String, String>{};
    switch (body[_keptVerdictsKey]) {
      case null:
        break;
      case final Map<String, Object?> map:
        for (final MapEntry(:key, :value) in map.entries) {
          if (key.isEmpty || value is! String || value.isEmpty) {
            throw const FormatException(
              'keptVerdicts holds an entry that is not a fingerprint',
            );
          }
          kept[key] = value;
        }
      default:
        throw const FormatException('keptVerdicts is not an object');
    }
    return (
      negative: decodeStringList(body, _negativePinsKey).toSet(),
      kept: kept,
    );
  }
}

/// `sync_tripwires.json`: `{"version": 1, "trippedIds": [record ids]}`,
/// sorted. Kept like [FilePinVerdictStore]: one instance per file, changes
/// applied in memory first and written in order, and a failed write
/// thrown to the caller.
final class FileSyncTripwireStore implements SyncTripwireStore {
  FileSyncTripwireStore._(this._file, this._ids);

  final SyncStateFile _file;
  final Set<String> _ids;

  /// Opens `sync_tripwires.json` in [supportDirectory]. Never throws; a
  /// file it cannot use leaves the store empty and is reported in [issue].
  /// [writer] and [now] are seams for tests.
  static Future<FileSyncTripwireStore> open(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    SyncStateWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    final (file, ids) = await SyncStateFile.open(
      File(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$syncTripwiresFileName',
      ),
      access: access,
      decode: (body) => decodeStringList(body, _trippedIdsKey).toSet(),
      writer: writer,
      now: now,
    );
    return FileSyncTripwireStore._(file, ids ?? {});
  }

  /// The problem met while opening, or null when the file was fine or
  /// absent.
  SyncStateIssue? get issue => _file.issue;

  @override
  Future<Set<String>> trippedIds() async => Set.of(_ids);

  @override
  Future<void> trip(String id) =>
      _ids.add(id) || _file.hasUnsavedChanges ? _save() : Future.value();

  @override
  Future<void> clear(String id) =>
      _ids.remove(id) || _file.hasUnsavedChanges ? _save() : Future.value();

  Future<void> _save() => _file.save({_trippedIdsKey: _ids.toList()..sort()});
}
