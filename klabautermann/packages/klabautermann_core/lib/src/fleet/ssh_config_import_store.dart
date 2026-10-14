import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart' show ImportedHost;

import '../engine/protocol.dart';
import '../settings/device_settings_store.dart'
    show unusedCorruptCopyPath, writeFileAtomically;
import 'jump_routes.dart';
import 'ssh_config_entries.dart';

/// D13's device-local store for FL-02 imports, under the app's support
/// directory (03 §4.10).
const String sshConfigImportsFileName = 'ssh_config_imports.json';

/// The schema this build writes. A file with a higher version came from
/// a newer build and is never rewritten by this one
/// ([ImportStoreIssueKind.newerVersion]). Version 2 added `identityFile`
/// and `proxyJump`; a version 1 file, written before either was kept,
/// reads as hosts with neither, and the next import rewrites it.
const int sshConfigImportsSchemaVersion = 2;

const String _versionKey = 'version';
const String _entriesKey = 'entries';
const String _aliasKey = 'alias';
const String _hostKey = 'host';
const String _portKey = 'port';
const String _userKey = 'user';
const String _identityFileKey = 'identityFile';
const String _proxyJumpKey = 'proxyJump';

/// Replaces a file's contents: [writeFileAtomically] outside tests.
typedef SshConfigImportsWriter =
    Future<void> Function(File target, List<int> bytes);

/// The imported ssh_config hosts on disk (03 §4.10, D13): one JSON file,
/// `{"version": 2, "entries": [{"alias", "host", "port", "user",
/// "identityFile", "proxyJump"}, ...]}`, in import (file) order, `host` and
/// `port` the effective ones, and the last three left out when the config
/// names none. The engine derives the fleet entry, its id and its route
/// from these (`ImportedFleet`), so the file holds only what the config
/// said. Device-local and never pushed (D14).
///
/// The engine isolate owns it (D18): it opens the store when it starts and
/// replaces the whole set on each import. Every save writes the whole file
/// atomically (a sibling temp file, flushed, renamed over the target, then
/// the directory synced), so a crash leaves the previous import or the new
/// one, never a mix. The engine handles one request at a time, so saves
/// never overlap.
final class SshConfigImportStore {
  SshConfigImportStore._(
    this._file,
    this._writer,
    this.issue, [
    this._hosts = const [],
  ]);

  final File _file;
  final SshConfigImportsWriter _writer;
  List<ImportedHost> _hosts;

  /// The problem met while opening, or null when the file was fine or
  /// absent.
  final ImportStoreIssue? issue;

  /// Opens [file]; a missing file is an empty store. Never throws: a file
  /// it cannot use leaves the store empty and is reported in [issue].
  ///
  /// The file is all or nothing: one malformed entry makes it damaged, so
  /// no entry is dropped without a trace. A damaged file is renamed to
  /// `ssh_config_imports.json.corrupt-<UTC time>`, its bytes untouched,
  /// before anything could replace it. A rename, unlike the settings
  /// store's copy, is enough here: the settings store keeps the damaged
  /// file in place to salvage the device id from it on a later launch,
  /// while imports can always be read again from `~/.ssh/config`. When the
  /// rename fails, the file cannot be read, or a newer build wrote it, the
  /// store leaves it as it is and saves nothing while it runs.
  ///
  /// [writer] and [now] are seams for tests.
  static Future<SshConfigImportStore> open(
    File file, {
    SshConfigImportsWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    final List<int> raw;
    try {
      raw = await file.readAsBytes();
    } on PathNotFoundException {
      return SshConfigImportStore._(file, writer, null);
    } on FileSystemException catch (error) {
      return SshConfigImportStore._(
        file,
        writer,
        ImportStoreIssue(ImportStoreIssueKind.leftAsIs, detail: '$error'),
      );
    }

    final List<ImportedHost> hosts;
    try {
      final document = _decodeDocument(raw);
      if (document.version > sshConfigImportsSchemaVersion) {
        return SshConfigImportStore._(
          file,
          writer,
          ImportStoreIssue(
            ImportStoreIssueKind.newerVersion,
            detail: 'schema ${document.version}',
          ),
        );
      }
      hosts = _decodeHosts(document.json);
    } on FormatException catch (error) {
      return _setAside(file, writer, error, now());
    }

    return SshConfigImportStore._(file, writer, null, hosts);
  }

  /// The stored imports in file order; unmodifiable.
  List<ImportedHost> get hosts => _hosts;

  /// Replaces every stored import with [hosts], as
  /// `importedHostsFromSshConfig` returns them, and saves the set.
  /// Completes with whether the file now holds it: false when this store
  /// leaves the file as it is ([ImportStoreIssueKind.leftAsIs],
  /// [ImportStoreIssueKind.newerVersion]) or the write failed, in which
  /// case the file keeps its previous contents. [hosts] replaces the
  /// in-memory set either way, so the running engine shows what the user
  /// imported. Never throws.
  Future<bool> replace(List<ImportedHost> hosts) async {
    _hosts = List.unmodifiable(hosts);
    switch (issue?.kind) {
      case ImportStoreIssueKind.leftAsIs || ImportStoreIssueKind.newerVersion:
        return false;
      case ImportStoreIssueKind.recovered || null:
        break;
    }

    try {
      await _writer(_file, _encode(_hosts));
      return true;
    } on Object {
      // The caller reports the import as not saved; the write's own error
      // has no reader (the app shows one localized sentence for it).
      return false;
    }
  }

  static List<int> _encode(List<ImportedHost> hosts) => utf8.encode(
    jsonEncode({
      _versionKey: sshConfigImportsSchemaVersion,
      _entriesKey: [
        for (final host in hosts)
          {
            _aliasKey: host.alias,
            _hostKey: host.effectiveHost,
            _portKey: host.port ?? kSshDefaultPort,
            _userKey: ?host.user,
            _identityFileKey: ?host.identityFile,
            _proxyJumpKey: ?host.proxyJump,
          },
      ],
    }),
  );

  /// The JSON object in [raw] and its version, or a [FormatException] when
  /// [raw] is not UTF-8 JSON, not an object, or has no usable version.
  static ({Map<String, Object?> json, int version}) _decodeDocument(
    List<int> raw,
  ) {
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('the import store is not a JSON object');
    }

    final version = decoded[_versionKey];
    if (version is! int || version < 1) {
      throw const FormatException('the import store has no usable version');
    }
    return (json: decoded, version: version);
  }

  /// The hosts of a version 1 or 2 document, or a [FormatException] naming
  /// the first entry the import could not have produced: it needs a
  /// non-empty alias and host, a TCP port, a non-empty user, identity file
  /// and `ProxyJump` or none, an alias no earlier entry took, and a route
  /// [jumpRoutes] can follow. Keys this build does not know are ignored.
  static List<ImportedHost> _decodeHosts(Map<String, Object?> json) {
    final list = json[_entriesKey];
    if (list is! List<Object?>) {
      throw const FormatException('the import store has no entries list');
    }

    final aliases = <String>{};
    final hosts = <ImportedHost>[];
    for (final (index, item) in list.indexed) {
      if (item is! Map<String, Object?>) {
        throw FormatException('entry $index is not a JSON object');
      }

      final alias = item[_aliasKey];
      final host = item[_hostKey];
      final port = item[_portKey];
      if (alias is! String || alias.isEmpty || !aliases.add(alias)) {
        throw FormatException('entry $index has no unique alias');
      }
      if (host is! String || host.isEmpty) {
        throw FormatException('entry $index has no host');
      }
      if (port is! int || !isTcpPort(port)) {
        throw FormatException('entry $index has no usable port');
      }
      String? optional(String key) => switch (item[key]) {
        null => null,
        final String value when value.isNotEmpty => value,
        _ => throw FormatException('entry $index has an unusable $key'),
      };

      hosts.add(
        ImportedHost(
          alias: alias,
          hostName: host,
          port: port,
          user: optional(_userKey),
          identityFile: optional(_identityFileKey),
          proxyJump: optional(_proxyJumpKey),
        ),
      );
    }

    final routes = jumpRoutes(hosts);
    for (final (index, host) in hosts.indexed) {
      if (routes[host.alias] == null) {
        throw FormatException(
          'entry $index has a ProxyJump the engine cannot follow',
        );
      }
    }
    return List.unmodifiable(hosts);
  }

  /// Renames a damaged [file] aside and opens an empty store over the
  /// freed path, or leaves the file in place, and the store read-only,
  /// when the rename fails.
  static Future<SshConfigImportStore> _setAside(
    File file,
    SshConfigImportsWriter writer,
    FormatException error,
    DateTime time,
  ) async {
    final String preservedAs;
    try {
      preservedAs = await unusedCorruptCopyPath(file, time);
      await file.rename(preservedAs);
    } on FileSystemException catch (renameError) {
      return SshConfigImportStore._(
        file,
        writer,
        ImportStoreIssue(
          ImportStoreIssueKind.leftAsIs,
          detail: '${error.message}; not renamed aside: $renameError',
        ),
      );
    }

    return SshConfigImportStore._(
      file,
      writer,
      ImportStoreIssue(
        ImportStoreIssueKind.recovered,
        preservedAs: preservedAs,
        detail: error.message,
      ),
    );
  }
}
