import 'dart:convert';
import 'dart:io';

import '../catalog/atomic_file_writer.dart';
import '../catalog/endpoint_pin_store.dart';
import 'corrupt_file_quarantine.dart';

/// The device-local file of confirmed endpoints, under the app's support
/// directory (03-ARCHITECTURE.md 4.10).
const String endpointPinsFileName = 'endpoint_pins.json';

/// A [FileEndpointPinStore] refused a change because `endpoint_pins.json`
/// was written by a newer build, whose data this build must not
/// overwrite. The file is left as it is.
final class EndpointPinsNewerVersionException implements Exception {
  const EndpointPinsNewerVersionException(this.version);

  /// The version the file declares.
  final int version;

  @override
  String toString() =>
      'EndpointPinsNewerVersionException: endpoint_pins.json is version '
      '$version, newer than this build reads; update the app to change '
      'endpoint pins';
}

/// JSON-file [EndpointPinStore] for `endpoint_pins.json`:
/// `{"version": 1, "pins": [EndpointPin.toJson(), ...]}`, the pins sorted
/// by server id, rewritten whole on every change through the
/// `atomicWriter` seam, which defaults to [AtomicFileWriter] at the
/// process default mode.
///
/// Loads and mutations run one at a time in call order, and the cache
/// changes only after the write lands, so a failed write leaves both as
/// they were. Keep one instance per file: each instance loads once and
/// then writes its whole cache, so two over one path would undo each
/// other's pins.
///
/// What a load does with the file:
///
/// - Missing: the store is empty.
/// - Unreadable (a file-system error): the error propagates and nothing
///   is cached, so the next call reads again.
/// - Corrupt (not JSON, the wrong shape, a version this format never had,
///   or any malformed or duplicate entry): the file is quarantined and
///   the store starts empty. One bad entry condemns the whole file, so no
///   pin is dropped without a trace; the quarantined copy keeps the
///   bytes. Starting empty is the safe direction, since a server without
///   a pin gets no background connection until the user confirms again.
/// - Newer version: the file is left as it is. [pinFor] finds no pins,
///   with the same safe effect, and [confirm] and [drop] throw
///   [EndpointPinsNewerVersionException].
final class FileEndpointPinStore implements EndpointPinStore {
  FileEndpointPinStore(
    this.file, {
    Future<void> Function(File target, String contents)? atomicWriter,
  }) : _atomicWriter = atomicWriter ?? const AtomicFileWriter().write;

  static const _storeVersion = 1;
  static const _versionKey = 'version';
  static const _pinsKey = 'pins';

  final File file;
  final Future<void> Function(File target, String contents) _atomicWriter;
  final Map<String, EndpointPin> _pins = {};
  bool _loaded = false;

  /// The version of a newer file this store must not overwrite, or null
  /// while the store may write.
  int? _newerVersion;

  Future<void> _pending = Future<void>.value();

  @override
  Future<EndpointPin?> pinFor(String serverId) =>
      _serialize(() async => _pins[serverId]);

  @override
  Future<void> confirm(EndpointPin pin) => _serialize(() async {
    _refuseNewerFile();

    final next = Map<String, EndpointPin>.of(_pins)..[pin.serverId] = pin;
    await _flush(next);

    _replaceCache(next);
  });

  @override
  Future<void> drop(String serverId) => _serialize(() async {
    _refuseNewerFile();
    if (!_pins.containsKey(serverId)) return;

    final next = Map<String, EndpointPin>.of(_pins)..remove(serverId);
    await _flush(next);

    _replaceCache(next);
  });

  void _refuseNewerFile() {
    final version = _newerVersion;
    if (version != null) throw EndpointPinsNewerVersionException(version);
  }

  void _replaceCache(Map<String, EndpointPin> next) {
    _pins
      ..clear()
      ..addAll(next);
  }

  Future<void> _load() async {
    if (_loaded) return;

    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on PathNotFoundException {
      _loaded = true;
      return;
    }

    try {
      _decode(bytes);
    } on FormatException {
      _pins.clear();
      _newerVersion = null;
      await quarantineCorruptFile(file);
    }
    _loaded = true;
  }

  /// Fills the cache from [bytes], or throws [FormatException] for a
  /// corrupt document. A newer version sets [_newerVersion] and leaves
  /// the cache empty.
  void _decode(List<int> bytes) {
    // Malformed UTF-8 and malformed JSON both throw FormatException.
    final document = jsonDecode(utf8.decode(bytes));
    if (document is! Map) throw const FormatException('endpoint pins root');

    final version = document[_versionKey];
    if (version is! int || version < _storeVersion) {
      throw FormatException('endpoint pins version $version');
    }
    if (version > _storeVersion) {
      _newerVersion = version;
      return;
    }

    final entries = document[_pinsKey];
    if (entries is! List) throw const FormatException('endpoint pins list');

    for (final entry in entries) {
      final pin = EndpointPin.fromJson(entry);
      if (_pins.containsKey(pin.serverId)) {
        throw FormatException('duplicate endpoint pin for ${pin.serverId}');
      }
      _pins[pin.serverId] = pin;
    }
  }

  Future<void> _flush(Map<String, EndpointPin> pins) {
    final sorted = pins.values.toList()
      ..sort((a, b) => a.serverId.compareTo(b.serverId));
    return _atomicWriter(
      file,
      jsonEncode({
        _versionKey: _storeVersion,
        _pinsKey: [for (final pin in sorted) pin.toJson()],
      }),
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
}
