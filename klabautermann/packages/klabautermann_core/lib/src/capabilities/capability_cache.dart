/// The device's capability cache (03 §4.10, §6.1, D59): each fleet
/// server's last probed [HostProfile] in `capabilities/<name>.json` under
/// the support directory, usable for 24 hours, so a known server shows
/// its last profile before this run's probe answers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart' show HostProfile;
import 'package:meta/meta.dart';

import '../engine/protocol.dart' show HostProfileChanged;
import '../fleet/server_file_stem.dart';
import '../sampling/sample_pipeline.dart' show volatileProfileKeys;
import '../settings/device_settings_store.dart' show writeFileAtomically;
import '../settings/instance_lock.dart' show SupportDirectoryAccess;

/// The cache's directory under the support directory (03 §4.10).
const String capabilityCacheDirectoryName = 'capabilities';

/// How long a cached profile stays usable (03 §6.1).
const Duration capabilityCacheTtl = Duration(hours: 24);

/// The `format` every cache file names, so a file of anything else is
/// recognised as foreign rather than misread.
const String _format = 'klabautermann.capabilities';
const int _version = 1;

/// A profile's JSON is a few kilobytes; a file far larger is not one.
const int _maxFileBytes = 256 * 1024;

const String _extension = '.json';

/// The names [capabilityCacheFileName] gives, and the temporary files an
/// interrupted atomic write leaves beside them.
final _ownName = RegExp(
  r'^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|'
  r'ssh-config-[0-9a-f]{64})\.json(\.tmp-.+)?$',
);

/// The cache file name of [serverId] (D59), or null when the id names
/// none: its [serverFileStem] and `.json`.
String? capabilityCacheFileName(String serverId) =>
    switch (serverFileStem(serverId)) {
      final stem? => '$stem$_extension',
      null => null,
    };

/// What reading one server's cache file found.
sealed class CachedProfileRead {
  const CachedProfileRead();
}

/// A profile probed less than [capabilityCacheTtl] ago.
final class CachedProfileFresh extends CachedProfileRead {
  const CachedProfileFresh(this.profile, this.probedAt);

  final HostProfile profile;

  /// When its probe answered, by the engine's clock in UTC.
  final DateTime probedAt;
}

/// A profile too old to use, or probed after the clock's present time.
final class CachedProfileExpired extends CachedProfileRead {
  const CachedProfileExpired(this.probedAt);

  final DateTime probedAt;
}

/// No file for the server.
final class CachedProfileMissing extends CachedProfileRead {
  const CachedProfileMissing();
}

/// A file that is not a usable cache entry for the server.
final class CachedProfileRejected extends CachedProfileRead {
  const CachedProfileRejected(this.reason);

  final CachedProfileRejection reason;
}

/// Why a [CachedProfileRejected] file is not used. The next probe
/// replaces it.
enum CachedProfileRejection {
  /// The server id names no cache file ([capabilityCacheFileName]).
  unnamedServer,

  /// The file system refused the read.
  unreadable,

  /// Not JSON, oversized, or a field missing or of the wrong type.
  corrupt,

  /// Another format, or another server's profile.
  foreign,

  /// Written by a newer build.
  newerVersion,
}

/// What a write or a purge did.
enum CacheUpdate {
  /// Written, or deleted (also when there was nothing to delete).
  applied,

  /// Another instance may use the support directory (03 §4.10), so the
  /// cache changed nothing.
  notExclusive,

  /// The server id names no cache file.
  unnamed,

  /// The fleet is not saved this run ([CachePurge.never]), so the purge
  /// kept the file.
  purgeWithheld,

  /// An import of this run was not saved ([FleetSave.unsaved]), so the
  /// write left the file as it is.
  unsavedFleet,

  /// The file system refused it.
  failed,
}

/// Whether the import store holds the fleet the engine runs (D59).
enum FleetSave {
  /// It does, so the next start reads the same servers and endpoints.
  saved,

  /// An import of this run was not saved, so the next start reads an
  /// older fleet, in which a server may keep its id under its old
  /// endpoint.
  unsaved,
}

/// Whether the cache deletes the files of servers outside its fleet.
enum CachePurge {
  /// The fleet is the one the device keeps, so a server outside it was
  /// removed (SYN-08) and its file goes.
  removedServers,

  /// The fleet is not saved this run, as when the engine leaves the import
  /// store as it is: a server outside it may still be the device's, so no
  /// file goes.
  never,
}

/// The engine's capability cache. It reads every fleet server's fresh
/// profile when it opens, hands each out once ([takeCached]) unless a
/// probe of this run answered first, rewrites a server's file on each
/// probe answer ([probed]) while the store holds the fleet it runs
/// ([fleetSave]) and deletes it when the server leaves the fleet or its
/// endpoint changes ([forget], SYN-08), unless [CachePurge.never] keeps
/// it. It writes and deletes only with [SupportDirectoryAccess.exclusive]
/// access, and one file operation at a time, in call order, so a purge
/// cannot overtake a write.
final class CapabilityCache {
  CapabilityCache._(this._directory, this._access, this._purge, this._now);

  final Directory _directory;
  final SupportDirectoryAccess _access;
  final CachePurge _purge;
  final DateTime Function() _now;

  /// Fresh profiles read at open and not handed out or superseded yet.
  final Map<String, CachedProfileFresh> _unsent = {};

  Future<void> _tail = Future.value();

  /// Set after each import: while [FleetSave.unsaved], [probed] writes no
  /// file, which the next start would read for the store's older
  /// endpoint. Purges go on, since a file deleted early only waits for
  /// the next probe.
  FleetSave fleetSave = FleetSave.saved;

  /// Opens the cache in [supportDirectory] for [fleet]: with exclusive
  /// access and [CachePurge.removedServers] it first deletes the files of
  /// servers outside [fleet] and the temporary files interrupted writes
  /// left, then it reads each fleet server's file. Never throws.
  static Future<CapabilityCache> open(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    required Set<String> fleet,
    required CachePurge purge,
    @visibleForTesting DateTime Function() now = _utcNow,
  }) async {
    final cache = CapabilityCache._(
      Directory(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$capabilityCacheDirectoryName',
      ),
      access,
      purge,
      now,
    );
    if (access == SupportDirectoryAccess.exclusive &&
        purge == CachePurge.removedServers) {
      await cache._sweep(fleet);
    }
    for (final serverId in fleet) {
      if (await cache.read(serverId) case final CachedProfileFresh fresh) {
        cache._unsent[serverId] = fresh;
      }
    }
    return cache;
  }

  /// [serverId]'s cached profile as the event the engine sends when a
  /// request first names the server (03 §6.1): once per run, only while
  /// fresh, and never after a probe of this run answered.
  HostProfileChanged? takeCached(String serverId) {
    final cached = _unsent.remove(serverId);
    if (cached == null || !_fresh(cached.probedAt)) return null;
    return HostProfileChanged(
      serverId,
      cached.profile,
      cachedAt: cached.probedAt,
    );
  }

  /// Records a probe answer for [serverId]: its cached profile is no
  /// longer sent, and its file holds [profile] without the clock and
  /// session fields, probed now.
  Future<CacheUpdate> probed(String serverId, HostProfile profile) {
    _unsent.remove(serverId);
    if (fleetSave == FleetSave.unsaved) {
      return Future.value(CacheUpdate.unsavedFleet);
    }
    final document = {
      'format': _format,
      'version': _version,
      'serverId': serverId,
      'probedAt': _now().toUtc().toIso8601String(),
      'profile': {
        for (final e in profile.toJson().entries)
          if (!volatileProfileKeys.contains(e.key)) e.key: e.value,
      },
    };
    return _change(
      serverId,
      (file) => writeFileAtomically(file, utf8.encode(jsonEncode(document))),
    );
  }

  /// Forgets [serverIds], which left the fleet or moved to another
  /// endpoint, deleting their files.
  Future<List<CacheUpdate>> forget(Set<String> serverIds) {
    serverIds.forEach(_unsent.remove);
    if (_purge == CachePurge.never) {
      return Future.value([
        for (final _ in serverIds) CacheUpdate.purgeWithheld,
      ]);
    }
    return Future.wait([
      for (final serverId in serverIds)
        _change(serverId, (file) async {
          try {
            await file.delete();
          } on PathNotFoundException {
            // Nothing to delete is a purge done.
          }
        }),
    ]);
  }

  /// Reads [serverId]'s file.
  Future<CachedProfileRead> read(String serverId) async {
    final name = capabilityCacheFileName(serverId);
    if (name == null) {
      return const CachedProfileRejected(CachedProfileRejection.unnamedServer);
    }

    final bytes = BytesBuilder(copy: false);
    try {
      await _file(name).openRead(0, _maxFileBytes + 1).forEach(bytes.add);
    } on PathNotFoundException {
      return const CachedProfileMissing();
    } on FileSystemException {
      return const CachedProfileRejected(CachedProfileRejection.unreadable);
    }
    if (bytes.length > _maxFileBytes) {
      return const CachedProfileRejected(CachedProfileRejection.corrupt);
    }

    try {
      return _decode(serverId, jsonDecode(utf8.decode(bytes.takeBytes())));
    } on FormatException {
      return const CachedProfileRejected(CachedProfileRejection.corrupt);
    }
  }

  CachedProfileRead _decode(String serverId, Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('not a JSON object');
    }
    if (json['format'] != _format) {
      return const CachedProfileRejected(CachedProfileRejection.foreign);
    }
    final version = json['version'];
    if (version is! int || version < 1) {
      throw const FormatException('no version');
    }
    if (version > _version) {
      return const CachedProfileRejected(CachedProfileRejection.newerVersion);
    }
    if (json['serverId'] != serverId) {
      return const CachedProfileRejected(CachedProfileRejection.foreign);
    }
    final probedAt = switch (json['probedAt']) {
      final String text => DateTime.tryParse(text),
      _ => null,
    };
    if (probedAt == null || !probedAt.isUtc) {
      throw const FormatException('no UTC probe time');
    }
    final profile = json['profile'];
    if (profile is! Map<String, Object?>) {
      throw const FormatException('no profile');
    }

    final parsed = HostProfile.fromJson(profile);
    return _fresh(probedAt)
        ? CachedProfileFresh(parsed, probedAt)
        : CachedProfileExpired(probedAt);
  }

  bool _fresh(DateTime probedAt) {
    final age = _now().difference(probedAt);
    return !age.isNegative && age < capabilityCacheTtl;
  }

  /// Runs [change] on [serverId]'s file after every earlier change.
  Future<CacheUpdate> _change(
    String serverId,
    Future<void> Function(File file) change,
  ) {
    if (_access != SupportDirectoryAccess.exclusive) {
      return Future.value(CacheUpdate.notExclusive);
    }
    final name = capabilityCacheFileName(serverId);
    if (name == null) return Future.value(CacheUpdate.unnamed);

    final result = _tail.then((_) async {
      try {
        await change(_file(name));
        return CacheUpdate.applied;
      } on Object {
        // As for the import store's save: whatever the write threw, the
        // engine goes on, and the next probe writes again. Nothing reads
        // the error.
        return CacheUpdate.failed;
      }
    });
    _tail = result;
    return result;
  }

  /// Deletes this cache's files that belong to no server in [fleet].
  /// Files it did not name are left alone.
  Future<void> _sweep(Set<String> fleet) async {
    final kept = {for (final id in fleet) ?capabilityCacheFileName(id)};
    final List<FileSystemEntity> entities;
    try {
      entities = await _directory.list().toList();
    } on FileSystemException {
      // A missing or unreadable directory holds nothing to sweep.
      return;
    }
    for (final entity in entities) {
      final name = entity.uri.pathSegments.last;
      final own = _ownName.firstMatch(name);
      if (entity is! File || own == null) continue;
      if (own[1] == null && kept.contains(name)) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // Swept on a later start.
      }
    }
  }

  File _file(String name) =>
      File('${_directory.path}${Platform.pathSeparator}$name');
}

DateTime _utcNow() => DateTime.now().toUtc();
