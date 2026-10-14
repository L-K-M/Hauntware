import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:seance_core/catalog.dart' show syncLocalDirectory;
import 'package:seance_core/seance_core.dart' show uuidV4;

/// The device settings file under the app's support directory (03 §4.10).
const String deviceSettingsFileName = 'settings.json';

/// The schema this build reads and writes. A file with a higher version
/// came from a newer build and is never rewritten by this one
/// ([DeviceSettingsIssueKind.newerVersion]); the monitor set and the
/// per-server device preferences join the schema under new keys.
const int deviceSettingsSchemaVersion = 1;

// The keys sit under the `klabautermann.` prefix like every settings key
// (04 §12.3); the device id's name is fixed there and never changes.
const String _versionKey = 'klabautermann.settings.version';
const String _deviceIdKey = 'klabautermann.sync.deviceId';
const String _appearanceKey = 'klabautermann.appearance';

/// Replaces a file's contents. [DeviceSettingsStore] writes the settings
/// document and the copy of a damaged file through it.
typedef DeviceSettingsWriter =
    Future<void> Function(File target, List<int> bytes);

/// What went wrong with `settings.json` when the store opened.
enum DeviceSettingsIssueKind {
  /// The file was not a settings document this build can read. Its bytes
  /// were copied to [DeviceSettingsIssue.preservedAs] before anything was
  /// written, and the store started from the defaults, keeping the device
  /// id when the damaged text still showed one.
  recovered,

  /// As [recovered], but the defaults could not be written over the
  /// damaged file, which stays in place for the next launch to recover
  /// again (with another copy). Later changes try the write again.
  recoveredNotSaved,

  /// The file exists but could not be read. It is left as it is, and
  /// nothing is saved this session.
  unreadable,

  /// The file was not a settings document, and its copy could not be
  /// written. It is left as it is, and nothing is saved this session.
  unpreserved,

  /// A newer build wrote the file. What this build knows is read from it;
  /// it is left as it is, and nothing is saved this session.
  newerVersion,

  /// The settings could not be written while the store opened (the first
  /// device id). Later changes try again.
  notSaved;

  /// Whether the store refuses every write for the rest of the session.
  bool get readOnly => switch (this) {
    unreadable || unpreserved || newerVersion => true,
    recovered || recoveredNotSaved || notSaved => false,
  };
}

/// The one problem [DeviceSettingsStore.open] met, for the app to report.
@immutable
final class DeviceSettingsIssue {
  const DeviceSettingsIssue(this.kind, {this.preservedAs, this.error});

  final DeviceSettingsIssueKind kind;

  /// Where the damaged file's bytes were kept; set for
  /// [DeviceSettingsIssueKind.recovered] and
  /// [DeviceSettingsIssueKind.recoveredNotSaved] only.
  final String? preservedAs;

  /// The failure behind [kind], for diagnostics: for
  /// [DeviceSettingsIssueKind.recoveredNotSaved], the failed write rather
  /// than the parse error.
  final Object? error;
}

/// A change the store applied in memory but did not save, because this
/// session leaves `settings.json` as it is ([DeviceSettingsIssueKind.readOnly]).
final class DeviceSettingsReadOnlyException implements Exception {
  const DeviceSettingsReadOnlyException(this.kind);

  final DeviceSettingsIssueKind kind;

  @override
  String toString() =>
      'DeviceSettingsReadOnlyException: settings.json is left as it is '
      'this session (${kind.name}), so the change was not saved';
}

/// This device's `settings.json` (03 §4.10): the device id, the appearance
/// and, later, the monitor set and per-server device preferences.
///
/// The app's isolate owns it: the composition root opens it once and the
/// controllers write through it. The desktop settings window runs no store
/// of its own; its changes reach the app's controllers over the settings
/// link (D32) and are saved here.
///
/// Every write replaces the whole document atomically (a sibling temp file,
/// flushed, renamed over the target, then the directory synced) and writes
/// queue, so the file holds the last change this process made; between two
/// app instances the last writer wins (see [open]). A change is applied in
/// memory before it is written and stays applied when the write fails: the
/// call throws, and the next successful write carries it.
///
/// Keys this build does not know are kept and written back, so a newer
/// build's settings survive a write by this one within the same schema
/// version.
final class DeviceSettingsStore {
  DeviceSettingsStore._(this._file, this._writer, this._values, [this._issue]);

  final File _file;
  final DeviceSettingsWriter _writer;

  /// Every key of the document but the version, unknown keys included.
  final Map<String, Object?> _values;
  DeviceSettingsIssue? _issue;
  Future<void> _writeTail = Future<void>.value();

  /// Opens [file], creating it on first launch. Never throws: a file it
  /// cannot use leaves the defaults in place and is reported in [issue].
  ///
  /// A damaged file is copied aside to `settings.json.corrupt-<UTC time>`
  /// (a later damage never overwrites an earlier copy) before anything
  /// replaces it, and its device id is kept when the text still shows one.
  /// When the copy fails, or the file cannot be read at all, the store
  /// leaves the file untouched and refuses writes for the session.
  ///
  /// The device id is minted here, on the first launch, rather than when a
  /// consumer first asks: once persisted it exists before any reader does,
  /// so the catalog library's enrollment and every later reader only ever
  /// read it, and no two readers in this process can race to mint
  /// different ids. An id is only handed out once it is on disk. Nothing
  /// guards against a second process: two instances that open a missing
  /// file at once (the Linux runner allows several) each mint and hand out
  /// an id, and the last rename wins on disk. An inter-process lock or a
  /// single desktop instance must land before enrollment reads the id.
  ///
  /// [writer] and [now] are seams for tests.
  static Future<DeviceSettingsStore> open(
    File file, {
    DeviceSettingsWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    final List<int> raw;
    try {
      raw = await file.readAsBytes();
    } on PathNotFoundException {
      return _openUsable(file, writer, {});
    } on FileSystemException catch (error) {
      return DeviceSettingsStore._(
        file,
        writer,
        {},
        DeviceSettingsIssue(DeviceSettingsIssueKind.unreadable, error: error),
      );
    }

    final Map<String, Object?> document;
    try {
      document = _decode(raw);
    } on FormatException catch (error) {
      return _recover(file, writer, raw, error, now());
    }

    final version = document.remove(_versionKey)! as int;
    if (version > deviceSettingsSchemaVersion) {
      return DeviceSettingsStore._(
        file,
        writer,
        document,
        const DeviceSettingsIssue(DeviceSettingsIssueKind.newerVersion),
      );
    }

    return _openUsable(file, writer, document);
  }

  /// A store over [values] read from a usable file, or none: mints the
  /// device id when there is none and reports a failed save as
  /// [DeviceSettingsIssueKind.notSaved].
  static Future<DeviceSettingsStore> _openUsable(
    File file,
    DeviceSettingsWriter writer,
    Map<String, Object?> values,
  ) async {
    final store = DeviceSettingsStore._(file, writer, values);
    if (await store._persistAtOpen(rewrite: false) case final Object error) {
      store._issue = DeviceSettingsIssue(
        DeviceSettingsIssueKind.notSaved,
        error: error,
      );
    }
    return store;
  }

  /// The problem met while opening, or null when the file was fine.
  DeviceSettingsIssue? get issue => _issue;

  /// This install's sync authorship id, `klabautermann.sync.deviceId`: a
  /// UUID v4 minted once and never regenerated while the file can be read
  /// (03 §4.10; the catalog library's `SyncEnrollmentState.deviceId`
  /// contract). A damaged file whose text shows no id gets a new one; its
  /// old bytes stay in the corrupt copy. Null only when it could not be
  /// read or saved this session; no id is invented then.
  String? get deviceId => _values[_deviceIdKey] as String?;

  /// The appearance as the app stored it: an opaque JSON object the app
  /// encodes and decodes, or null when there is none (or the stored value
  /// is not an object, which reads as none rather than failing the file).
  Map<String, Object?>? get appearance => switch (_values[_appearanceKey]) {
    final Map<String, Object?> json => Map.unmodifiable(json),
    _ => null,
  };

  /// Stores [appearance] and writes the document. Throws when the write
  /// fails or this session is read-only; the value stays in memory either
  /// way.
  Future<void> setAppearance(Map<String, Object?> appearance) async {
    _values[_appearanceKey] = appearance;
    await _save();
  }

  /// Mints the device id when there is none and writes the document when
  /// it changed or [rewrite] asks for it. Returns the write's failure, or
  /// null when it saved or had nothing to save; the caller reports it. A
  /// failure keeps the store usable: a minted id is dropped again, since it
  /// never reached the disk.
  Future<Object?> _persistAtOpen({required bool rewrite}) async {
    final mint = deviceId == null;
    if (!mint && !rewrite) return null;

    if (mint) _values[_deviceIdKey] = uuidV4();
    try {
      await _save();
      return null;
    } on Object catch (error) {
      if (mint) _values.remove(_deviceIdKey);
      return error;
    }
  }

  /// Queues a write of the whole document as it is when the write starts,
  /// so overlapping saves land in order and the last one wins.
  Future<void> _save() {
    if (_issue case DeviceSettingsIssue(:final kind) when kind.readOnly) {
      return Future.error(DeviceSettingsReadOnlyException(kind));
    }

    final write = _writeTail.then(
      (_) => _writer(
        _file,
        utf8.encode(
          jsonEncode({_versionKey: deviceSettingsSchemaVersion, ..._values}),
        ),
      ),
    );
    // Each caller gets its own write's failure; the queue itself moves on.
    _writeTail = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  /// The settings document in [raw], or a [FormatException] when it is not
  /// one: not UTF-8 JSON, not an object, no usable version, or a device id
  /// that is not a non-empty string. The device id and version are checked
  /// strictly because a wrong guess at either costs the install its
  /// identity; the appearance is read leniently by its getter instead.
  static Map<String, Object?> _decode(List<int> raw) {
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('settings.json is not a JSON object');
    }

    final version = decoded[_versionKey];
    if (version is! int || version < 1) {
      throw const FormatException('settings.json has no usable version');
    }

    final deviceId = decoded[_deviceIdKey];
    if (deviceId != null && (deviceId is! String || deviceId.isEmpty)) {
      throw const FormatException('settings.json has an unusable device id');
    }

    return decoded;
  }

  /// Séance's settings recovery (keep the device id the damaged text still
  /// shows, write the defaults back at once so the next launch does not
  /// mint a new one), with Poltergeist's time-stamped copy name, and one
  /// change of order: the damaged bytes are copied aside before anything
  /// is written, and the original is never moved. A failed write-back
  /// therefore leaves the damaged file in place for the next launch to
  /// recover again, device id included, instead of an empty directory.
  static Future<DeviceSettingsStore> _recover(
    File file,
    DeviceSettingsWriter writer,
    List<int> raw,
    FormatException error,
    DateTime time,
  ) async {
    final salvaged = _salvageDeviceId(raw);
    final values = <String, Object?>{_deviceIdKey: ?salvaged};

    final String preservedAs;
    try {
      preservedAs = await _unusedCopyPath(file, time);
      await writer(File(preservedAs), raw);
    } on Object catch (copyError) {
      return DeviceSettingsStore._(
        file,
        writer,
        values,
        DeviceSettingsIssue(
          DeviceSettingsIssueKind.unpreserved,
          error: copyError,
        ),
      );
    }

    final store = DeviceSettingsStore._(file, writer, values);
    final writeError = await store._persistAtOpen(rewrite: true);
    store._issue = writeError == null
        ? DeviceSettingsIssue(
            DeviceSettingsIssueKind.recovered,
            preservedAs: preservedAs,
            error: error,
          )
        : DeviceSettingsIssue(
            DeviceSettingsIssueKind.recoveredNotSaved,
            preservedAs: preservedAs,
            error: writeError,
          );
    return store;
  }

  /// The device id from text that did not parse, when it still shows one
  /// where a key can sit (Séance's `salvageSettings` rule). The value goes
  /// through JSON string decoding so escapes survive.
  static String? _salvageDeviceId(List<int> raw) {
    final text = utf8.decode(raw, allowMalformed: true);
    final match = RegExp(
      '(?:^|[,{])\\s*"${RegExp.escape(_deviceIdKey)}"\\s*:\\s*'
      '"((?:[^"\\\\]|\\\\.)*)"',
    ).firstMatch(text);
    final escaped = match?.group(1);
    if (escaped == null) return null;

    try {
      final value = jsonDecode('"$escaped"') as String;
      return value.isEmpty ? null : value;
    } on FormatException {
      return null;
    }
  }

  /// `settings.json.corrupt-<UTC time>`, with a counter when that name is
  /// taken, so a copy never replaces an earlier one.
  static Future<String> _unusedCopyPath(File file, DateTime time) async {
    final stamp = time
        .toUtc()
        .toIso8601String()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll('.', '');
    final base = '${file.path}.corrupt-$stamp';
    var candidate = base;
    for (var counter = 2; ; counter++) {
      final type = await FileSystemEntity.type(candidate, followLinks: false);
      if (type == FileSystemEntityType.notFound) return candidate;
      candidate = '$base-$counter';
    }
  }
}

/// The store's default [DeviceSettingsWriter], and the app's writer for its
/// other device-local files (`window_state.json`): the catalog stores'
/// write order (`AtomicFileWriter` in `seance_core`, which its barrel does
/// not export). A sibling temp file with a random name is written and
/// flushed, renamed over [target], and the directory synced through
/// `seance_core`'s [syncLocalDirectory] so the rename survives power loss.
/// A reader, or a crash, sees the old file or the new one, never a partial
/// one. A failure deletes the temp file and rethrows. Concurrent writes to
/// one target are the caller's to order: each lands whole, and the last
/// rename wins.
Future<void> writeFileAtomically(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final temporary = File('${target.path}.tmp-${uuidV4()}');
  try {
    final handle = await temporary.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temporary.rename(target.path);
    await syncLocalDirectory(target.parent);
  } on Object {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // The write's own failure is the one to report.
    }
    rethrow;
  }
}
