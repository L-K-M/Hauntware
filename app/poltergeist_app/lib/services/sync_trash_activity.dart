import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

/// One owned trash root, identified by its on-root marker.
final class SyncTrashLocation {
  const SyncTrashLocation._({
    required this.trashRoot,
    required this.pathStyle,
    required this.pathCase,
    required this.locationKey,
    required this._locationKeyRoot,
    required this._scopeKey,
    required this._identityKey,
  });

  final String trashRoot;
  final SyncTrashPathStyle pathStyle;
  final SyncTrashPathCase pathCase;
  final String locationKey;
  final String _locationKeyRoot;
  final String? _scopeKey;
  final String _identityKey;

  bool get isResolved => _scopeKey != null;

  /// Stable journal and lock identity read from the owned root marker.
  String get scopeKey {
    final value = _scopeKey;
    if (value != null) return value;
    throw StateError('The sync-trash root identity is unresolved.');
  }

  /// Confirms the endpoint still names the logical slot used at resolution.
  bool matchesLocationKey({
    required SyncEndpoint endpoint,
    required String endpointIdentity,
  }) =>
      locationKey ==
      syncTrashLocationKey(
        endpoint: endpoint,
        trashRoot: _locationKeyRoot,
        pathCase: pathCase,
        endpointIdentity: endpointIdentity,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncTrashLocation && other._identityKey == _identityKey;

  @override
  int get hashCode => _identityKey.hashCode;
}

/// Resolves the per-side trash location used by the executor.
SyncTrashLocation syncTrashLocation({
  required SyncEndpoint endpoint,
  required String canonicalRoot,
  required SyncRuleSet rules,
  required SyncSide side,
  required String rootId,
  String? resolvedTrashRoot,
  SyncTrashPathCase pathCase = SyncTrashPathCase.sensitive,
  String? locationKey,
  String? locationKeyRoot,
}) {
  final configured = switch (side) {
    SyncSide.left => rules.trashPathLeft,
    SyncSide.right => rules.trashPathRight,
  };
  final trashRoot =
      resolvedTrashRoot ??
      configured ??
      remoteJoin(canonicalRoot, RemoteTrash.rootDirectoryName);

  final normalizedRoot = _normalizeTrashRoot(endpoint, trashRoot);
  final normalizedLocationKeyRoot = _normalizeTrashRoot(
    endpoint,
    locationKeyRoot ?? trashRoot,
  );
  final effectiveLocationKey =
      locationKey ??
      syncTrashLocationKey(
        endpoint: endpoint,
        trashRoot: normalizedLocationKeyRoot,
        pathCase: pathCase,
      );
  final scopeKey = sha256
      .convert(utf8.encode('poltergeist-sync-trash\u0000$rootId'))
      .toString();

  return SyncTrashLocation._(
    trashRoot: normalizedRoot,
    pathStyle: endpoint is LocalEndpoint && Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix,
    pathCase: pathCase,
    locationKey: effectiveLocationKey,
    locationKeyRoot: normalizedLocationKeyRoot,
    scopeKey: scopeKey,
    identityKey: scopeKey,
  );
}

SyncTrashLocation unresolvedSyncTrashLocation({
  required SyncEndpoint endpoint,
  required String trashRoot,
  required SyncTrashPathCase pathCase,
  String? locationKey,
  String? locationKeyRoot,
}) {
  final normalizedRoot = _normalizeTrashRoot(endpoint, trashRoot);
  final normalizedLocationKeyRoot = _normalizeTrashRoot(
    endpoint,
    locationKeyRoot ?? trashRoot,
  );
  final effectiveLocationKey =
      locationKey ??
      syncTrashLocationKey(
        endpoint: endpoint,
        trashRoot: normalizedLocationKeyRoot,
        pathCase: pathCase,
      );
  return SyncTrashLocation._(
    trashRoot: normalizedRoot,
    pathStyle: endpoint is LocalEndpoint && Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix,
    pathCase: pathCase,
    locationKey: effectiveLocationKey,
    locationKeyRoot: normalizedLocationKeyRoot,
    scopeKey: null,
    identityKey: 'unresolved:$effectiveLocationKey',
  );
}

/// Rehydrates a prior root scope from persisted state so its activity gate
/// can be held while journals are released after whole-root deletion.
SyncTrashLocation knownSyncTrashLocation({
  required SyncEndpoint endpoint,
  required String trashRoot,
  required SyncTrashPathCase pathCase,
  required String scopeKey,
  String? locationKey,
  String? locationKeyRoot,
}) {
  if (!isSyncTrashIdentityKey(scopeKey)) {
    throw ArgumentError.value(scopeKey, 'scopeKey', 'is invalid');
  }
  if (locationKey != null && !isSyncTrashIdentityKey(locationKey)) {
    throw ArgumentError.value(locationKey, 'locationKey', 'is invalid');
  }

  final normalizedRoot = _normalizeTrashRoot(endpoint, trashRoot);
  final normalizedLocationKeyRoot = _normalizeTrashRoot(
    endpoint,
    locationKeyRoot ?? trashRoot,
  );

  return SyncTrashLocation._(
    trashRoot: normalizedRoot,
    pathStyle: endpoint is LocalEndpoint && Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix,
    pathCase: pathCase,
    locationKey:
        locationKey ??
        syncTrashLocationKey(
          endpoint: endpoint,
          trashRoot: normalizedLocationKeyRoot,
          pathCase: pathCase,
        ),
    locationKeyRoot: normalizedLocationKeyRoot,
    scopeKey: scopeKey,
    identityKey: scopeKey,
  );
}

/// Stable endpoint/path slot identity shared by every marker generation.
String syncTrashLocationKey({
  required SyncEndpoint endpoint,
  required String trashRoot,
  required SyncTrashPathCase pathCase,
  String? endpointIdentity,
}) {
  final endpointKey =
      endpointIdentity ??
      switch (endpoint) {
        LocalEndpoint() => 'local',
        RemoteEndpoint(:final server) =>
          server.identity == null
              ? 'config:${server.serverConfigId}'
              : '${server.identity!.username}@'
                    '${server.identity!.host.toLowerCase()}:'
                    '${server.identity!.port}',
      };
  var normalizedRoot = _normalizeTrashRoot(endpoint, trashRoot);
  if (pathCase == SyncTrashPathCase.insensitive) {
    normalizedRoot = normalizedRoot.toLowerCase();
  }

  return sha256
      .convert(
        utf8.encode(
          'poltergeist-sync-trash-location\u0000$endpointKey\u0000'
          '$normalizedRoot',
        ),
      )
      .toString();
}

String _normalizeTrashRoot(SyncEndpoint endpoint, String path) {
  final normalized = endpoint is LocalEndpoint
      ? p.normalize(path)
      : p.posix.normalize(path);
  if (normalized == '/') return normalized;
  return normalized.replaceFirst(RegExp(r'/+$'), '');
}

/// Whether a purge may coexist with runs already active at its roots.
enum SyncTrashPurgeAdmission {
  /// The aged selection excludes their run ids, so existing runs may finish.
  excludeActiveRuns,

  /// The explicit whole-trash command must find every target root idle.
  requireIdle,
}

final class SyncTrashPurgeInProgressException implements Exception {
  const SyncTrashPurgeInProgressException();
}

/// A local lock could not be established or released safely.
final class SyncTrashActivityLockException implements Exception {
  const SyncTrashActivityLockException(this.operation, [this.cause]);

  final String operation;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'SyncTrashActivityLockException: $operation'
      : 'SyncTrashActivityLockException: $operation: $cause';
}

/// Active sync runs keyed by owned trash-root identities.
///
/// A configured lock directory extends the registry across app processes.
/// Gate locks make admission atomic; active-marker locks identify live runs.
final class SyncTrashActivityRegistry extends ChangeNotifier {
  SyncTrashActivityRegistry({String? lockDirectory})
    : _lockDirectory = lockDirectory == null
          ? null
          : p.absolute(p.normalize(lockDirectory)),
      _namespace = lockDirectory == null
          ? 'memory:${_nextMemoryNamespace++}'
          : p.absolute(p.normalize(lockDirectory));

  static const _gateSuffix = '.gate.lock';
  static const _activeMarker = '.active.';
  static const _lockSuffix = '.lock';

  static var _nextMemoryNamespace = 0;
  static final Map<String, _ProcessScopeState> _processScopes = {};
  static final Map<String, _AsyncMutex> _processMutexes = {};
  static final Map<String, _ProcessLocationState> _processLocations = {};
  static final Map<String, _AsyncMutex> _processLocationMutexes = {};

  final String? _lockDirectory;
  final String _namespace;
  final Map<String, Set<String>> _purgedScopesByRun = {};

  Set<String> activeRunIds(SyncTrashLocation location) {
    if (!location.isResolved) return const <String>{};
    return Set.unmodifiable(
      _processScopes[_processKey(location)]?.activeRunIds ?? const <String>{},
    );
  }

  bool hasActiveRun(SyncTrashLocation location) =>
      location.isResolved &&
      (_processScopes[_processKey(location)]?.activeRunIds.isNotEmpty ?? false);

  bool hasPurge(SyncTrashLocation location) =>
      location.isResolved &&
      (_processScopes[_processKey(location)]?.purging ?? false);

  bool wasPurged(String runId, String trashScope) =>
      _purgedScopesByRun[runId]?.contains(trashScope) ?? false;

  Set<String> purgedTrashScopes(String runId) =>
      Set.unmodifiable(_purgedScopesByRun[runId] ?? const <String>{});

  /// Invalidates live journal objects after another controller marks a scope.
  void recordPurged(Iterable<String> runIds, String trashScope) {
    if (!isSyncTrashIdentityKey(trashScope)) {
      throw ArgumentError.value(trashScope, 'trashScope', 'is invalid');
    }

    var changed = false;
    for (final runId in runIds) {
      changed =
          _purgedScopesByRun
              .putIfAbsent(runId, () => <String>{})
              .add(trashScope) ||
          changed;
    }
    if (changed) notifyListeners();
  }

  /// Reserves [runId] before the executor creates its journal or trash dir.
  Future<SyncTrashActivityLease> begin(
    String runId,
    Iterable<SyncTrashLocation> locations,
  ) async {
    if (runId.isEmpty) {
      throw ArgumentError.value(runId, 'runId', 'must not be empty');
    }

    final ordered = _orderedLocations(locations);
    final locationKeys = _orderedLocationKeys(ordered);
    final locationGuards = await _acquireLocationGuards(locationKeys);
    final guards = await _acquireProcessGuards(ordered);
    final gates = <_HeldFileLock>[];
    final locationGates = <_HeldFileLock>[];
    final markers = <_RunMarker>[];

    try {
      if (ordered.any(hasPurge) ||
          locationKeys.any((key) => _locationState(key).transitioning)) {
        throw const SyncTrashPurgeInProgressException();
      }
      if (ordered.any((location) => activeRunIds(location).contains(runId))) {
        throw const SyncTrashActivityLockException(
          'reserve duplicate active run',
        );
      }

      if (_lockDirectory != null) {
        await _ensureLockDirectory();
        for (final locationKey in locationKeys) {
          final gate = await _tryLock(
            _locationGatePath(locationKey),
            FileLock.shared,
          );
          if (gate == null) {
            throw const SyncTrashPurgeInProgressException();
          }
          locationGates.add(gate);
        }

        for (final location in ordered) {
          final gate = await _tryLock(
            _scopeGatePath(location),
            FileLock.shared,
          );
          if (gate == null) {
            throw const SyncTrashPurgeInProgressException();
          }
          gates.add(gate);
        }

        for (final location in ordered) {
          final path = _markerPath(location, runId);
          final marker = await _tryLock(path, FileLock.exclusive);
          if (marker == null) {
            throw const SyncTrashActivityLockException(
              'reserve active-run marker',
            );
          }
          markers.add(_RunMarker(marker));
          await _writeMarker(marker.file, runId);
        }
      }

      for (final location in ordered) {
        _scopeState(location).activeRunIds.add(runId);
      }
      for (final locationKey in locationKeys) {
        _locationState(locationKey).sharedHolders++;
      }
    } catch (_) {
      await _releaseMarkers(markers);
      await _releaseLocks(locationGates);
      rethrow;
    } finally {
      try {
        await _releaseLocks(gates);
      } finally {
        try {
          _releaseProcessGuards(guards);
        } finally {
          _releaseLocationGuards(locationGuards);
        }
      }
    }

    if (ordered.isNotEmpty) notifyListeners();
    return SyncTrashActivityLease._(
      this,
      runId,
      ordered.toSet(),
      markers,
      locationGates,
    );
  }

  /// Atomically reserves roots for purge. Once reserved, no new run can
  /// register there until the returned lease closes.
  Future<SyncTrashPurgeLease?> tryBeginPurge(
    Iterable<SyncTrashLocation> locations,
    SyncTrashPurgeAdmission admission,
  ) async {
    final ordered = _orderedLocations(locations);
    final locationKeys = _orderedLocationKeys(ordered);
    final locationGuards = await _acquireLocationGuards(locationKeys);
    final guards = await _acquireProcessGuards(ordered);
    final gates = <_HeldFileLock>[];
    final locationGates = <_HeldFileLock>[];
    var retainGates = false;

    try {
      if (ordered.any(hasPurge) ||
          locationKeys.any((key) => _locationState(key).transitioning)) {
        return null;
      }

      if (_lockDirectory != null) {
        await _ensureLockDirectory();
        for (final locationKey in locationKeys) {
          final gate = await _tryLock(
            _locationGatePath(locationKey),
            FileLock.shared,
          );
          if (gate == null) return null;
          locationGates.add(gate);
        }

        for (final location in ordered) {
          final gate = await _tryLock(
            _scopeGatePath(location),
            FileLock.exclusive,
          );
          if (gate == null) return null;
          gates.add(gate);
        }
      }

      final activeByLocation = <SyncTrashLocation, Set<String>>{};
      for (final location in ordered) {
        final active = <String>{...activeRunIds(location)};
        if (_lockDirectory != null) {
          active.addAll(await _lockedMarkerRunIds(location));
        }
        activeByLocation[location] = active;
      }

      if (admission == SyncTrashPurgeAdmission.requireIdle &&
          activeByLocation.values.any((runIds) => runIds.isNotEmpty)) {
        return null;
      }

      for (final location in ordered) {
        _scopeState(location).purging = true;
      }
      for (final locationKey in locationKeys) {
        _locationState(locationKey).sharedHolders++;
      }
      if (ordered.isNotEmpty) notifyListeners();

      retainGates = true;
      return SyncTrashPurgeLease._(
        this,
        ordered.toSet(),
        gates,
        locationGates,
        activeByLocation,
      );
    } finally {
      try {
        if (!retainGates) {
          await _releaseLocks(gates);
          await _releaseLocks(locationGates);
        }
      } finally {
        try {
          _releaseProcessGuards(guards);
        } finally {
          _releaseLocationGuards(locationGuards);
        }
      }
    }
  }

  /// Serializes a missing root's journal retirement and marker claim across
  /// processes and across marker generations of the same endpoint/path slot.
  Future<SyncTrashTransitionLease?> tryBeginRootTransition(
    String locationKey,
    Iterable<SyncTrashLocation> priorLocations,
  ) async {
    if (!isSyncTrashIdentityKey(locationKey)) {
      throw ArgumentError.value(locationKey, 'locationKey', 'is invalid');
    }
    final ordered = _orderedLocations(priorLocations);
    if (ordered.any((location) => location.locationKey != locationKey)) {
      throw const SyncTrashActivityLockException(
        'reserve mismatched trash-root transition',
      );
    }

    final locationGuards = await _acquireLocationGuards([locationKey]);
    final guards = await _acquireProcessGuards(ordered);
    final locks = <_HeldFileLock>[];
    var retainLocks = false;
    try {
      final locationState = _locationState(locationKey);
      if (locationState.transitioning || locationState.sharedHolders > 0) {
        return null;
      }
      if (ordered.any(hasPurge) || ordered.any(hasActiveRun)) return null;

      if (_lockDirectory != null) {
        await _ensureLockDirectory();
        final locationGate = await _tryLock(
          _locationGatePath(locationKey),
          FileLock.exclusive,
        );
        if (locationGate == null) return null;
        locks.add(locationGate);

        for (final location in ordered) {
          final scopeGate = await _tryLock(
            _scopeGatePath(location),
            FileLock.exclusive,
          );
          if (scopeGate == null) return null;
          locks.add(scopeGate);
          if ((await _lockedMarkerRunIds(location)).isNotEmpty) return null;
        }
      }

      locationState.transitioning = true;
      for (final location in ordered) {
        _scopeState(location).purging = true;
      }
      if (ordered.isNotEmpty) notifyListeners();

      retainLocks = true;
      return SyncTrashTransitionLease._(
        this,
        locationKey,
        ordered.toSet(),
        locks,
      );
    } finally {
      try {
        if (!retainLocks) await _releaseLocks(locks);
      } finally {
        try {
          _releaseProcessGuards(guards);
        } finally {
          _releaseLocationGuards(locationGuards);
        }
      }
    }
  }

  Future<void> _end(
    String runId,
    Set<SyncTrashLocation> locations,
    List<_RunMarker> markers,
    List<_HeldFileLock> locationGates,
  ) async {
    final ordered = _orderedLocations(locations);
    final locationKeys = _orderedLocationKeys(ordered);
    final locationGuards = await _acquireLocationGuards(locationKeys);
    final guards = await _acquireProcessGuards(ordered);
    var changed = false;

    try {
      // Keep failed releases visible as active rather than admitting purge.
      await _releaseMarkers(markers);
      await _releaseLocks(locationGates);

      for (final location in ordered) {
        final state = _processScopes[_processKey(location)];
        if (state == null || !state.activeRunIds.remove(runId)) continue;
        changed = true;
        _discardEmptyScope(location, state);
      }
      for (final locationKey in locationKeys) {
        _releaseLocationHolder(locationKey);
      }
    } finally {
      try {
        _releaseProcessGuards(guards);
      } finally {
        _releaseLocationGuards(locationGuards);
      }
    }

    if (changed) notifyListeners();
  }

  Future<void> _endPurge(
    Set<SyncTrashLocation> locations,
    List<_HeldFileLock> gates,
    List<_HeldFileLock> locationGates,
  ) async {
    final ordered = _orderedLocations(locations);
    final locationKeys = _orderedLocationKeys(ordered);
    final locationGuards = await _acquireLocationGuards(locationKeys);
    final guards = await _acquireProcessGuards(ordered);
    var changed = false;

    try {
      // The process-local guard stays closed if an OS gate cannot unlock.
      await _releaseLocks(gates);
      await _releaseLocks(locationGates);

      for (final location in ordered) {
        final state = _processScopes[_processKey(location)];
        if (state == null || !state.purging) continue;
        state.purging = false;
        changed = true;
        _discardEmptyScope(location, state);
      }
      for (final locationKey in locationKeys) {
        _releaseLocationHolder(locationKey);
      }
    } finally {
      try {
        _releaseProcessGuards(guards);
      } finally {
        _releaseLocationGuards(locationGuards);
      }
    }

    if (changed) notifyListeners();
  }

  Future<void> _endTransition(
    String locationKey,
    Set<SyncTrashLocation> locations,
    List<_HeldFileLock> locks,
  ) async {
    final ordered = _orderedLocations(locations);
    final locationGuards = await _acquireLocationGuards([locationKey]);
    final guards = await _acquireProcessGuards(ordered);
    var changed = false;
    try {
      await _releaseLocks(locks);

      final locationState = _locationState(locationKey);
      if (locationState.transitioning) {
        locationState.transitioning = false;
        changed = true;
      }
      _discardEmptyLocation(locationKey, locationState);
      for (final location in ordered) {
        final state = _processScopes[_processKey(location)];
        if (state == null || !state.purging) continue;
        state.purging = false;
        changed = true;
        _discardEmptyScope(location, state);
      }
    } finally {
      try {
        _releaseProcessGuards(guards);
      } finally {
        _releaseLocationGuards(locationGuards);
      }
    }

    if (changed) notifyListeners();
  }

  List<SyncTrashLocation> _orderedLocations(
    Iterable<SyncTrashLocation> locations,
  ) {
    final unique = locations.toSet().toList();
    if (unique.any((location) => !location.isResolved)) {
      throw const SyncTrashActivityLockException(
        'reserve an unresolved trash root',
      );
    }
    unique.sort((left, right) => left.scopeKey.compareTo(right.scopeKey));
    return unique;
  }

  List<String> _orderedLocationKeys(Iterable<SyncTrashLocation> locations) =>
      ({for (final location in locations) location.locationKey}.toList()
        ..sort());

  String _processKey(SyncTrashLocation location) =>
      '$_namespace\u0000${location.scopeKey}';

  _ProcessScopeState _scopeState(SyncTrashLocation location) =>
      _processScopes.putIfAbsent(_processKey(location), _ProcessScopeState.new);

  String _processLocationKey(String locationKey) =>
      '$_namespace\u0000location\u0000$locationKey';

  _ProcessLocationState _locationState(String locationKey) => _processLocations
      .putIfAbsent(_processLocationKey(locationKey), _ProcessLocationState.new);

  void _discardEmptyScope(
    SyncTrashLocation location,
    _ProcessScopeState state,
  ) {
    if (state.purging || state.activeRunIds.isNotEmpty) return;
    _processScopes.remove(_processKey(location));
  }

  void _releaseLocationHolder(String locationKey) {
    final state = _locationState(locationKey);
    if (state.sharedHolders > 0) state.sharedHolders--;
    _discardEmptyLocation(locationKey, state);
  }

  void _discardEmptyLocation(String locationKey, _ProcessLocationState state) {
    if (state.transitioning || state.sharedHolders > 0) return;
    _processLocations.remove(_processLocationKey(locationKey));
  }

  Future<List<_MutexLease>> _acquireProcessGuards(
    List<SyncTrashLocation> locations,
  ) async {
    final leases = <_MutexLease>[];
    for (final location in locations) {
      final key = _processKey(location);
      final mutex = _processMutexes.putIfAbsent(key, _AsyncMutex.new);
      leases.add(await mutex.acquire());
    }
    return leases;
  }

  void _releaseProcessGuards(List<_MutexLease> guards) {
    for (final guard in guards.reversed) {
      guard.release();
    }
  }

  Future<List<_MutexLease>> _acquireLocationGuards(
    List<String> locationKeys,
  ) async {
    final leases = <_MutexLease>[];
    for (final locationKey in locationKeys) {
      final key = _processLocationKey(locationKey);
      final mutex = _processLocationMutexes.putIfAbsent(key, _AsyncMutex.new);
      leases.add(await mutex.acquire());
    }
    return leases;
  }

  void _releaseLocationGuards(List<_MutexLease> guards) {
    for (final guard in guards.reversed) {
      guard.release();
    }
  }

  Future<void> _ensureLockDirectory() async {
    try {
      await Directory(_lockDirectory!).create(recursive: true);
    } on FileSystemException catch (error) {
      throw SyncTrashActivityLockException('create lock directory', error);
    }
  }

  String _scopeGatePath(SyncTrashLocation location) =>
      p.join(_lockDirectory!, '${location.scopeKey}$_gateSuffix');

  String _locationGatePath(String locationKey) =>
      p.join(_lockDirectory!, '$locationKey.location$_gateSuffix');

  String _markerPath(SyncTrashLocation location, String runId) {
    final runKey = sha256.convert(utf8.encode(runId));
    return p.join(
      _lockDirectory!,
      '${location.scopeKey}$_activeMarker$runKey$_lockSuffix',
    );
  }

  Future<_HeldFileLock?> _tryLock(String path, FileLock mode) async {
    RandomAccessFile? file;
    try {
      file = await File(path).open(mode: FileMode.append);
      await file.lock(mode);
      return _HeldFileLock(file);
    } on FileSystemException {
      await file?.close();
      return null;
    }
  }

  Future<void> _writeMarker(RandomAccessFile file, String runId) async {
    try {
      await file.truncate(0);
      await file.setPosition(0);
      await file.writeString(runId);
      await file.flush();
    } on FileSystemException catch (error) {
      throw SyncTrashActivityLockException('write active-run marker', error);
    }
  }

  Future<Set<String>> _lockedMarkerRunIds(SyncTrashLocation location) async {
    final active = <String>{};
    final local = activeRunIds(location);
    final localPaths = {
      for (final runId in local) _markerPath(location, runId),
    };
    final prefix = '${location.scopeKey}$_activeMarker';

    try {
      await for (final entity in Directory(
        _lockDirectory!,
      ).list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(prefix) || !name.endsWith(_lockSuffix)) continue;

        if (localPaths.contains(entity.path)) {
          active.addAll(
            local.where((runId) => _markerPath(location, runId) == entity.path),
          );
          continue;
        }

        final marker = await _tryLock(entity.path, FileLock.exclusive);
        if (marker == null) {
          final runId = await entity.readAsString();
          if (runId.isEmpty) {
            throw const SyncTrashActivityLockException(
              'read an empty active-run marker',
            );
          }
          active.add(runId);
          continue;
        }

        await marker.release();
        await entity.delete();
      }
    } on SyncTrashActivityLockException {
      rethrow;
    } on FileSystemException catch (error) {
      throw SyncTrashActivityLockException('inspect active-run markers', error);
    }

    return active;
  }

  Future<void> _releaseMarkers(List<_RunMarker> markers) async {
    Object? firstError;
    for (final marker in markers.reversed) {
      try {
        await marker.lock.release();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw SyncTrashActivityLockException(
        'release active-run markers',
        firstError,
      );
    }
  }

  Future<void> _releaseLocks(List<_HeldFileLock> locks) async {
    Object? firstError;
    for (final lock in locks.reversed) {
      try {
        await lock.release();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw SyncTrashActivityLockException('release gate locks', firstError);
    }
  }
}

/// Idempotent ownership token for one registry reservation.
final class SyncTrashActivityLease {
  SyncTrashActivityLease._(
    this._owner,
    this._runId,
    this._locations,
    this._markers,
    this._locationGates,
  );

  final SyncTrashActivityRegistry _owner;
  final String _runId;
  final Set<SyncTrashLocation> _locations;
  final List<_RunMarker> _markers;
  final List<_HeldFileLock> _locationGates;
  Future<void>? _closing;

  Future<void> close() =>
      _closing ??= _owner._end(_runId, _locations, _markers, _locationGates);
}

/// Idempotent ownership token for an atomic purge reservation.
final class SyncTrashPurgeLease {
  SyncTrashPurgeLease._(
    this._owner,
    this._locations,
    this._gates,
    this._locationGates,
    Map<SyncTrashLocation, Set<String>> activeByLocation,
  ) : _activeByLocation = {
        for (final entry in activeByLocation.entries)
          entry.key: Set.unmodifiable(entry.value),
      };

  final SyncTrashActivityRegistry _owner;
  final Set<SyncTrashLocation> _locations;
  final List<_HeldFileLock> _gates;
  final List<_HeldFileLock> _locationGates;
  final Map<SyncTrashLocation, Set<String>> _activeByLocation;
  Future<void>? _closing;

  Set<String> activeRunIds(SyncTrashLocation location) =>
      _activeByLocation[location] ?? const <String>{};

  Future<void> close() =>
      _closing ??= _owner._endPurge(_locations, _gates, _locationGates);
}

/// Idempotent ownership token for one missing-root generation transition.
final class SyncTrashTransitionLease {
  SyncTrashTransitionLease._(
    this._owner,
    this._locationKey,
    this._locations,
    this._locks,
  );

  final SyncTrashActivityRegistry _owner;
  final String _locationKey;
  final Set<SyncTrashLocation> _locations;
  final List<_HeldFileLock> _locks;
  Future<void>? _closing;

  Future<void> close() =>
      _closing ??= _owner._endTransition(_locationKey, _locations, _locks);
}

final class _ProcessScopeState {
  final Set<String> activeRunIds = {};
  var purging = false;
}

final class _ProcessLocationState {
  var sharedHolders = 0;
  var transitioning = false;
}

final class _RunMarker {
  const _RunMarker(this.lock);

  final _HeldFileLock lock;
}

final class _HeldFileLock {
  const _HeldFileLock(this.file);

  final RandomAccessFile file;

  Future<void> release() async {
    Object? firstError;
    try {
      await file.unlock();
    } catch (error) {
      firstError = error;
    }

    try {
      await file.close();
    } catch (error) {
      firstError ??= error;
    }

    if (firstError != null) throw firstError;
  }
}

final class _AsyncMutex {
  final Queue<Completer<_MutexLease>> _waiters = Queue();
  var _locked = false;

  Future<_MutexLease> acquire() {
    if (!_locked) {
      _locked = true;
      return Future.value(_MutexLease(this));
    }

    final waiter = Completer<_MutexLease>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isEmpty) {
      _locked = false;
      return;
    }

    _waiters.removeFirst().complete(_MutexLease(this));
  }
}

final class _MutexLease {
  _MutexLease(this._owner);

  final _AsyncMutex _owner;
  var _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner.release();
  }
}
