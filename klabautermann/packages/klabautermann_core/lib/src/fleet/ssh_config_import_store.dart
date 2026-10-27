import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart' show ImportedHost;

import '../engine/protocol.dart';
import '../settings/device_settings_store.dart'
    show unusedCorruptCopyPath, writeFileAtomically;
import 'imported_fleet.dart' show ImportedHostDetail;
import 'jump_routes.dart';
import 'ssh_config_settings.dart';

/// D13's device-local store for FL-02 imports, under the app's support
/// directory (03 §4.10).
const String sshConfigImportsFileName = 'ssh_config_imports.json';

/// The schema this build writes. A file with a higher version came from
/// a newer build and is never rewritten by this one
/// ([ImportStoreIssueKind.newerVersion]). Version 3 holds the values ssh
/// would use, read from every block that applies, and the hop records;
/// an older file reads as hosts with addresses only
/// ([SshConfigImportStore.detail]), and the next import rewrites it.
const int sshConfigImportsSchemaVersion = 3;

/// The first schema whose hosts the engine can dial: version 1 kept no
/// `identityFile` or `proxyJump`, and version 2 read each host's values
/// from its first block alone, so neither says how ssh would connect.
const int _effectiveSettingsSchemaVersion = 3;

const String _versionKey = 'version';
const String _entriesKey = 'entries';
const String _hopsKey = 'hops';
const String _aliasKey = 'alias';
const String _hostKey = 'host';
const String _portKey = 'port';
const String _userKey = 'user';
const String _identityFileKey = 'identityFile';
const String _proxyJumpKey = 'proxyJump';

/// Replaces a file's contents: [writeFileAtomically] outside tests.
typedef SshConfigImportsWriter = Future<void> Function(
  File target,
  List<int> bytes,
);

/// The imported ssh_config hosts on disk (03 §4.10, D13): one JSON file,
/// `{"version": 3, "entries": [{"alias", "host", "port", "user",
/// "identityFile", "proxyJump"}, ...], "hops": [...]}`, the hosts in
/// import (file) order with the values ssh would use, the last three
/// left out when the config names none. `hops` holds, in the same shape,
/// the settings of each other name the hosts' routes give, keyed by that
/// name as the alias, and is left out when there are none. The engine
/// derives the fleet entry, its id and its route from these
/// (`ImportedFleet`), so the file holds only what the config said.
/// Device-local and never pushed (D14).
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
    this._hops = const [],
    this._detail = ImportedHostDetail.full,
  ]);

  final File _file;
  final SshConfigImportsWriter _writer;
  List<ImportedHost> _hosts;
  List<ImportedHost> _hops;
  ImportedHostDetail _detail;

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

    final ({List<ImportedHost> hosts, List<ImportedHost> hops}) stored;
    final ImportedHostDetail detail;
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
      detail = document.version < _effectiveSettingsSchemaVersion
          ? ImportedHostDetail.addressOnly
          : ImportedHostDetail.full;
      stored = _decodeHosts(document.json, detail);
    } on FormatException catch (error) {
      return _setAside(file, writer, error, now());
    }

    return SshConfigImportStore._(
      file,
      writer,
      null,
      stored.hosts,
      stored.hops,
      detail,
    );
  }

  /// The stored imports in file order; unmodifiable.
  List<ImportedHost> get hosts => _hosts;

  /// The stored hop records, which `ImportedFleet` hands `jumpRoutes`;
  /// unmodifiable, and empty for a file of an older schema.
  List<ImportedHost> get hops => _hops;

  /// How much of each host's config [hosts] holds: addresses only from a
  /// file of an older schema until [replace], else all of it.
  ImportedHostDetail get detail => _detail;

  /// Replaces every stored import with [hosts] and [hops], as
  /// `importedHostsFromSshConfig` returns them, and saves the set.
  /// Completes with whether the file now holds it: false when this store
  /// leaves the file as it is ([ImportStoreIssueKind.leftAsIs],
  /// [ImportStoreIssueKind.newerVersion]) or the write failed, in which
  /// case the file keeps its previous contents. [hosts] replaces the
  /// in-memory set either way, so the running engine shows what the user
  /// imported. Never throws.
  Future<bool> replace(
    List<ImportedHost> hosts, {
    List<ImportedHost> hops = const [],
  }) async {
    _hosts = List.unmodifiable(hosts);
    _hops = List.unmodifiable(hops);
    _detail = ImportedHostDetail.full;
    switch (issue?.kind) {
      case ImportStoreIssueKind.leftAsIs || ImportStoreIssueKind.newerVersion:
        return false;
      case ImportStoreIssueKind.recovered || null:
        break;
    }

    try {
      await _writer(_file, _encode(_hosts, _hops));
      return true;
    } on Object {
      // The caller reports the import as not saved; the write's own error
      // has no reader (the app shows one localized sentence for it).
      return false;
    }
  }

  static List<int> _encode(List<ImportedHost> hosts, List<ImportedHost> hops) =>
      utf8.encode(
        jsonEncode({
          _versionKey: sshConfigImportsSchemaVersion,
          _entriesKey: _encodeHosts(hosts),
          if (hops.isNotEmpty) _hopsKey: _encodeHosts(hops),
        }),
      );

  static List<Map<String, Object>> _encodeHosts(List<ImportedHost> hosts) => [
    for (final host in hosts)
      {
        _aliasKey: host.alias,
        _hostKey: host.effectiveHost,
        _portKey: host.port ?? kSshDefaultPort,
        _userKey: ?host.user,
        _identityFileKey: ?host.identityFile,
        _proxyJumpKey: ?host.proxyJump,
      },
  ];

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

  /// The hosts and hop records of a document, or a [FormatException]
  /// naming the first entry the import could not have produced: each
  /// needs a non-empty alias no earlier entry or hop record took, a
  /// non-empty host, a TCP port and a non-empty user or none. With
  /// [detail] full it also needs a non-empty `ProxyJump` or none and an
  /// identity file [isImportedIdentityFile] keeps or none, and each host a
  /// route [jumpRoutes] can follow. A file of an older schema is read for
  /// its addresses alone, so its other keys, like keys this build does not
  /// know, are ignored.
  static ({List<ImportedHost> hosts, List<ImportedHost> hops}) _decodeHosts(
    Map<String, Object?> json,
    ImportedHostDetail detail,
  ) {
    final full = detail == ImportedHostDetail.full;
    final aliases = <String>{};

    List<ImportedHost> decode(String key, String label) {
      final list = json[key];
      if (list == null && key == _hopsKey) return const [];
      if (list is! List<Object?>) {
        throw FormatException('the import store has no $key list');
      }
      return [
        for (final (index, item) in list.indexed)
          _decodeHost(item, '$label $index', aliases, full: full),
      ];
    }

    final hosts = decode(_entriesKey, 'entry');
    if (!full) return (hosts: List.unmodifiable(hosts), hops: const []);

    final hops = decode(_hopsKey, 'hop record');
    final routes = jumpRoutes(hosts, hops: hops);
    for (final (index, host) in hosts.indexed) {
      if (routes[host.alias] == null) {
        throw FormatException(
          'entry $index has a ProxyJump the engine cannot follow',
        );
      }
    }
    return (hosts: List.unmodifiable(hosts), hops: List.unmodifiable(hops));
  }

  /// One entry of the file, [label] naming it in a [FormatException];
  /// [aliases] holds those earlier entries took.
  static ImportedHost _decodeHost(
    Object? item,
    String label,
    Set<String> aliases, {
    required bool full,
  }) {
    if (item is! Map<String, Object?>) {
      throw FormatException('$label is not a JSON object');
    }

    final alias = item[_aliasKey];
    final host = item[_hostKey];
    final port = item[_portKey];
    if (alias is! String || alias.isEmpty || !aliases.add(alias)) {
      throw FormatException('$label has no unique alias');
    }
    if (host is! String || host.isEmpty) {
      throw FormatException('$label has no host');
    }
    if (port is! int || !isTcpPort(port)) {
      throw FormatException('$label has no usable port');
    }
    String? optional(String key, {bool Function(String)? usable}) =>
        switch (item[key]) {
          null => null,
          final String value
              when value.isNotEmpty && (usable?.call(value) ?? true) =>
            value,
          _ => throw FormatException('$label has an unusable $key'),
        };

    return ImportedHost(
      alias: alias,
      hostName: host,
      port: port,
      user: optional(_userKey),
      identityFile: full
          ? optional(_identityFileKey, usable: isImportedIdentityFile)
          : null,
      proxyJump: full ? optional(_proxyJumpKey) : null,
    );
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
