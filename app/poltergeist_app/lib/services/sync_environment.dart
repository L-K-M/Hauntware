// The sync feature's app-side composition root (05 §11's environment
// seam): where journals and sync_state live, which device identity
// stamps run ids, and how a pair's endpoints resolve to the
// RemoteFileSystem objects the scanner and executor speak. Local
// endpoints bind a LocalFileSystem directly (D3 — one VFS contract);
// remote endpoints lease engine-side channels through the bridged
// transfer lease (protocol v13, STATUS item 23) — and answer the honest
// `unsupported` refusal only when the engine failed to spawn.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart' show basicLocaleListResolution;
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../l10n/app_localizations.dart';
import 'server_config_source.dart';
import 'sync_state_store.dart';
import 'sync_trash_activity.dart';

/// The `sync_runs/` directory name under app support (05 §8's journal
/// home).
const String kSyncRunsDirectoryName = 'sync_runs';
const String kSyncTrashActivityDirectoryName = '.trash-activity';

/// Everything a sync session needs that is not the pair itself: the
/// state store, the journal directory, the run-id device prefix, and
/// the endpoint → filesystem resolution. Constructed once at the app
/// composition root and shared by every plan-view session.
final class SyncEnvironment {
  SyncEnvironment({
    required this.states,
    required this.syncRunsDirectory,
    required this.deviceId,
    RemoteFileSystem Function()? localFileSystem,
    this._connections,
    this._serverConfigs,
    SyncTrashActivityRegistry? trashActivity,
  }) : _localFileSystem = localFileSystem ?? LocalFileSystem.new,
       trashActivity =
           trashActivity ??
           SyncTrashActivityRegistry(
             lockDirectory: p.join(
               syncRunsDirectory,
               kSyncTrashActivityDirectoryName,
             ),
           );

  /// The production shape: file-backed state under the app-support
  /// directory, the enrollment state's device id, the real local fs.
  factory SyncEnvironment.forSupportDirectory(
    String supportDirectoryPath, {
    required Future<String> Function() deviceId,
    ConnectionManager? connections,
    AppServerConfigSource? serverConfigs,
  }) => SyncEnvironment(
    states: FileSyncStateStore(
      Directory(
        '$supportDirectoryPath${Platform.pathSeparator}'
        '$kSyncStateDirectoryName',
      ),
    ),
    syncRunsDirectory:
        '$supportDirectoryPath${Platform.pathSeparator}'
        '$kSyncRunsDirectoryName',
    deviceId: deviceId,
    connections: connections,
    serverConfigs: serverConfigs,
  );

  /// §9's per-pair local state (mtime-trust flags, probe cache, trash
  /// cache, last-run stamps).
  final SyncStateStore states;

  /// `<app-support>/sync_runs` — where SyncRunJournal files live.
  final String syncRunsDirectory;

  /// 04 §3.1's device identity — the runId prefix source (05 §6).
  final Future<String> Function() deviceId;
  final RemoteFileSystem Function() _localFileSystem;

  /// Process-wide active sync runs, keyed by owned trash-root identity.
  final SyncTrashActivityRegistry trashActivity;

  /// The engine's bridged lease seam; null when the engine failed to
  /// spawn — remote endpoints then refuse typed.
  final ConnectionManager? _connections;
  final AppServerConfigSource? _serverConfigs;

  /// One lease-on-demand filesystem per remote server, shared by every
  /// scan, diff, and run of every pair naming that server.
  final Map<String, LeasedRemoteFileSystem> _remote = {};

  /// Whether [endpoint] can serve a filesystem in this process — local
  /// always; remote once the engine bridge is composed.
  bool endpointAvailable(SyncEndpoint endpoint) => switch (endpoint) {
    LocalEndpoint() => true,
    RemoteEndpoint() => _connections != null && _serverConfigs != null,
  };

  /// The filesystem [endpoint] resolves to. A remote endpoint leases a
  /// transfer channel of its server on first use and keeps it until
  /// [releaseRemoteLeases] (or its idle backstop); without the engine
  /// bridge it throws the typed `unsupported` refusal — the plan view
  /// catches it and renders the honest-absence state.
  RemoteFileSystem fileSystemFor(SyncEndpoint endpoint) {
    switch (endpoint) {
      case LocalEndpoint():
        return _localFileSystem();
      case RemoteEndpoint(:final server, :final path):
        final connections = _connections;
        final configs = _serverConfigs;
        if (connections == null || configs == null) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.unsupported,
            operation: 'sync endpoint',
            path: path,
            message: 'remote sync endpoints are not available yet',
          );
        }
        final serverId = configs.registerEndpoint(server);
        return _remote[serverId] ??= LeasedRemoteFileSystem(
          connections,
          serverId,
        );
    }
  }

  /// Resolves a remote endpoint to the pooled identity used by queued
  /// preview production. Registration stays inside this environment boundary.
  String serverIdFor(RemoteEndpoint endpoint) {
    final configs = _serverConfigs;
    if (configs == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'sync endpoint',
        path: endpoint.path,
        message: 'remote sync endpoints are not available yet',
      );
    }

    return configs.registerEndpoint(endpoint.server);
  }

  /// Builds an unresolved location for cache display only. It cannot
  /// participate in locking until the root marker has been read.
  Future<SyncTrashLocation> trashLocationFor({
    required SyncEndpoint endpoint,
    required String canonicalRoot,
    required SyncRuleSet rules,
    required SyncSide side,
    SyncTrashPathCase pathCase = SyncTrashPathCase.sensitive,
  }) async {
    final trashRoot = _resolveTrashPath(
      endpoint,
      canonicalRoot,
      switch (side) {
        SyncSide.left => rules.trashPathLeft,
        SyncSide.right => rules.trashPathRight,
      },
    );
    String? endpointIdentity;
    try {
      endpointIdentity = await _trashEndpointIdentity(
        endpoint,
        canonicalRoot,
      );
    } on RemoteFileException {
      // An unresolved catalog cannot safely reuse a host-scoped cache.
    }

    return unresolvedSyncTrashLocation(
      endpoint: endpoint,
      trashRoot: trashRoot,
      pathCase: pathCase,
      locationKey: syncTrashLocationKey(
        endpoint: endpoint,
        trashRoot: trashRoot,
        pathCase: pathCase,
        endpointIdentity: endpointIdentity,
      ),
    );
  }

  /// Resolves the configured trash path exactly as execution does, so scans
  /// exclude relative and home-relative roots before walking the endpoint.
  Future<String> effectiveTrashPath({
    required SyncEndpoint endpoint,
    required String canonicalRoot,
    required SyncRuleSet rules,
    required SyncSide side,
  }) async {
    final configured = switch (side) {
      SyncSide.left => rules.trashPathLeft,
      SyncSide.right => rules.trashPathRight,
    };
    final unresolved = _resolveTrashPath(endpoint, canonicalRoot, configured);

    return _expandTrashHome(fileSystemFor(endpoint), endpoint, unresolved);
  }

  /// Claims or opens the trash root before it becomes an activity key.
  /// The on-root random marker makes aliases share the same lock scope.
  Future<SyncTrashLocation> resolveTrashLocation({
    required SyncEndpoint endpoint,
    required String canonicalRoot,
    required SyncRuleSet rules,
    required SyncSide side,
    required SyncTrashPathCase pathCase,
  }) async {
    final endpointIdentity = await _trashEndpointIdentity(
      endpoint,
      canonicalRoot,
    );
    final fileSystem = fileSystemFor(endpoint);
    final configuredTrashRoot = _resolveTrashPath(
      endpoint,
      canonicalRoot,
      switch (side) {
        SyncSide.left => rules.trashPathLeft,
        SyncSide.right => rules.trashPathRight,
      },
    );
    final effectiveTrashRoot = await _expandTrashHome(
      fileSystem,
      endpoint,
      configuredTrashRoot,
    );
    final resolved = await _canonicalizeWithMissingSuffix(
      fileSystem,
      endpoint,
      effectiveTrashRoot,
    );
    final pathStyle = endpoint is LocalEndpoint && Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    await _verifyTrashEndpointIdentity(endpoint, endpointIdentity, resolved);
    final locationKey = syncTrashLocationKey(
      endpoint: endpoint,
      trashRoot: configuredTrashRoot,
      pathCase: pathCase,
      endpointIdentity: endpointIdentity,
    );
    SyncTrashLocation locationFor(SyncTrashRootIdentity identity) =>
        syncTrashLocation(
          endpoint: endpoint,
          canonicalRoot: canonicalRoot,
          rules: rules,
          side: side,
          rootId: identity.rootId,
          resolvedTrashRoot: identity.canonicalRoot,
          pathCase: pathCase,
          locationKey: locationKey,
          locationKeyRoot: configuredTrashRoot,
        );

    SyncTrashRootIdentity? currentIdentity;
    RemoteFileException? openError;
    try {
      currentIdentity = await resolveSyncTrashRoot(
        fileSystem,
        resolved,
        pathStyle: pathStyle,
        access: SyncTrashRootAccess.openExisting,
      );
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound &&
          error.kind != RemoteFileErrorKind.conflict) {
        rethrow;
      }
      openError = error;
    }
    await _verifyTrashEndpointIdentity(endpoint, endpointIdentity, resolved);

    final pendingLocation = unresolvedSyncTrashLocation(
      endpoint: endpoint,
      trashRoot: resolved,
      pathCase: pathCase,
      locationKey: locationKey,
      locationKeyRoot: configuredTrashRoot,
    );
    final service = SyncTrashPurgeService(syncRunsDirectory);
    var priorScopes = await service.trashScopesForLocationKey(
      pendingLocation.locationKey,
    );
    final currentScope = currentIdentity?.scopeKey;
    final staleScopes = priorScopes.where((scope) => scope != currentScope);
    if (currentIdentity != null && staleScopes.isEmpty) {
      await _verifyTrashEndpointIdentity(endpoint, endpointIdentity, resolved);

      return locationFor(currentIdentity);
    }
    if (openError?.kind == RemoteFileErrorKind.conflict &&
        priorScopes.isNotEmpty) {
      throw openError!;
    }
    final priorLocations = [
      for (final scope in priorScopes)
        knownSyncTrashLocation(
          endpoint: endpoint,
          trashRoot: resolved,
          pathCase: pathCase,
          scopeKey: scope,
          locationKey: locationKey,
          locationKeyRoot: configuredTrashRoot,
        ),
    ];
    final transition = await trashActivity.tryBeginRootTransition(
      pendingLocation.locationKey,
      priorLocations,
    );
    if (transition == null) throw const SyncTrashPurgeInProgressException();

    try {
      SyncTrashRootIdentity? verifiedIdentity;
      RemoteFileException? verifiedError;
      try {
        verifiedIdentity = await resolveSyncTrashRoot(
          fileSystem,
          resolved,
          pathStyle: pathStyle,
          access: SyncTrashRootAccess.openExisting,
        );
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.notFound &&
            error.kind != RemoteFileErrorKind.conflict) {
          rethrow;
        }
        verifiedError = error;
      }

      priorScopes = await service.trashScopesForLocationKey(locationKey);
      if (verifiedIdentity != null) {
        await _retireAbsentTrashScopes(
          fileSystem: fileSystem,
          service: service,
          trashRoot: resolved,
          locationKey: locationKey,
          identity: verifiedIdentity,
          priorScopes: priorScopes,
          pathStyle: pathStyle,
          pathCase: pathCase,
          endpointIdentity: endpointIdentity,
          endpoint: endpoint,
        );
        await _verifyTrashEndpointIdentity(
          endpoint,
          endpointIdentity,
          resolved,
        );

        return locationFor(verifiedIdentity);
      }
      if (verifiedError?.kind == RemoteFileErrorKind.conflict &&
          priorScopes.isNotEmpty) {
        throw verifiedError!;
      }

      if (verifiedError?.kind == RemoteFileErrorKind.notFound) {
        await _verifyTrashEndpointIdentity(
          endpoint,
          endpointIdentity,
          resolved,
        );
        await _markSupersededTrashScopes(service, locationKey);
      }
      final identity = await resolveSyncTrashRoot(
        fileSystem,
        resolved,
        pathStyle: pathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      await _verifyTrashEndpointIdentity(endpoint, endpointIdentity, resolved);

      return locationFor(identity);
    } finally {
      await transition.close();
    }
  }

  Future<void> _retireAbsentTrashScopes({
    required RemoteFileSystem fileSystem,
    required SyncTrashPurgeService service,
    required String trashRoot,
    required String locationKey,
    required SyncTrashRootIdentity identity,
    required Set<String> priorScopes,
    required SyncTrashPathStyle pathStyle,
    required SyncTrashPathCase pathCase,
    required String endpointIdentity,
    required SyncEndpoint endpoint,
  }) async {
    final staleScopes = priorScopes
        .where((scope) => scope != identity.scopeKey)
        .toSet();
    if (staleScopes.isEmpty) return;

    final runIdsByScope = await service.trashRunIdsByLocationScope(locationKey);
    final listing = await fileSystem.listDirectory(identity.canonicalRoot);
    final listedNames = {for (final entry in listing) entry.name};
    for (final scope in staleScopes) {
      for (final runId in runIdsByScope[scope] ?? const <String>{}) {
        if (listedNames.any(
          (name) => name == runId || name.startsWith('$runId.purging-'),
        )) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.conflict,
            operation: 'open sync trash',
            path: trashRoot,
            message: 'The sync-trash marker changed while old trash remains.',
          );
        }
      }
    }

    final verified = await resolveSyncTrashRoot(
      fileSystem,
      trashRoot,
      pathStyle: pathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    final expectedRoot = normalizeSyncTrashPath(
      identity.canonicalRoot,
      pathStyle,
      pathCase,
    );
    final actualRoot = normalizeSyncTrashPath(
      verified.canonicalRoot,
      pathStyle,
      pathCase,
    );
    if (verified.rootId != identity.rootId || actualRoot != expectedRoot) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'open sync trash',
        path: trashRoot,
        message: 'The sync-trash root changed during reconciliation.',
      );
    }

    await _verifyTrashEndpointIdentity(endpoint, endpointIdentity, trashRoot);

    await _markSupersededTrashScopes(
      service,
      locationKey,
      keepScope: identity.scopeKey,
    );
  }

  Future<void> _markSupersededTrashScopes(
    SyncTrashPurgeService service,
    String locationKey, {
    String? keepScope,
  }) async {
    final purgedByScope = await service.markSupersededLocationScopes(
      locationKey,
      keepScope: keepScope,
    );
    for (final entry in purgedByScope.entries) {
      trashActivity.recordPurged(entry.value, entry.key);
    }
  }

  Future<String> _trashEndpointIdentity(
    SyncEndpoint endpoint,
    String path,
  ) async {
    var endpointIdentity = 'local';
    if (endpoint case RemoteEndpoint(:final server)) {
      final configs = _serverConfigs;
      if (configs == null) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.unsupported,
          operation: 'resolve sync trash',
          path: path,
          message: 'remote sync endpoints are not available yet',
        );
      }
      final serverId = configs.registerEndpoint(server);
      final config = await configs.configFor(serverId);
      if (config == null) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.notFound,
          operation: 'resolve sync trash',
          path: path,
          message: 'The sync endpoint is no longer available.',
        );
      }
      endpointIdentity =
          '${config.username}@${config.host.toLowerCase()}:'
          '${config.port}';
    }

    return endpointIdentity;
  }

  Future<void> _verifyTrashEndpointIdentity(
    SyncEndpoint endpoint,
    String expected,
    String path,
  ) async {
    final actual = await _trashEndpointIdentity(endpoint, path);
    if (actual == expected) return;

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'resolve sync trash',
      path: path,
      message: _syncEnvironmentLocalizations().syncTrashEndpointChanged,
    );
  }

  /// Re-checks the on-root marker immediately before a mutating action.
  Future<void> verifyTrashLocation(
    SyncEndpoint endpoint,
    SyncTrashLocation location,
  ) async {
    if (!location.isResolved) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'verify sync trash',
        path: location.trashRoot,
        message: 'The sync-trash root identity is unresolved.',
      );
    }
    final endpointIdentity = await _trashEndpointIdentity(
      endpoint,
      location.trashRoot,
    );
    final identity = await resolveSyncTrashRoot(
      fileSystemFor(endpoint),
      location.trashRoot,
      pathStyle: location.pathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    await _verifyTrashEndpointIdentity(
      endpoint,
      endpointIdentity,
      location.trashRoot,
    );
    final expectedRoot = normalizeSyncTrashPath(
      location.trashRoot,
      location.pathStyle,
      location.pathCase,
    );
    final actualRoot = normalizeSyncTrashPath(
      identity.canonicalRoot,
      location.pathStyle,
      location.pathCase,
    );
    final locationKeyMatches = location.matchesLocationKey(
      endpoint: endpoint,
      endpointIdentity: endpointIdentity,
    );
    if (identity.scopeKey == location.scopeKey &&
        actualRoot == expectedRoot &&
        locationKeyMatches) {
      return;
    }

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'verify sync trash',
      path: location.trashRoot,
      message: 'The sync-trash root changed after planning.',
    );
  }

  /// Returns every remote lease sync holds — called when a scan, run,
  /// retry, or restore settles and when a plan view disposes, so an idle
  /// pair never pins pool channels. The next remote call leases again.
  Future<void> releaseRemoteLeases() async {
    await Future.wait([for (final fs in _remote.values) fs.release()]);
  }

  /// The root path a scan/executor runs under for [endpoint].
  String rootFor(SyncEndpoint endpoint) => switch (endpoint) {
    LocalEndpoint(:final path) => path,
    RemoteEndpoint(:final path) => path,
  };
}

AppLocalizations _syncEnvironmentLocalizations() => lookupAppLocalizations(
  basicLocaleListResolution(
    PlatformDispatcher.instance.locales,
    AppLocalizations.supportedLocales,
  ),
);

String _resolveTrashPath(
  SyncEndpoint endpoint,
  String canonicalRoot,
  String? configured,
) {
  final path = configured ?? RemoteTrash.rootDirectoryName;
  if (_isAnchoredPath(endpoint, path)) return path;

  return endpoint is LocalEndpoint
      ? p.join(canonicalRoot, path)
      : remoteJoin(canonicalRoot, path);
}

Future<String> _expandTrashHome(
  RemoteFileSystem fileSystem,
  SyncEndpoint endpoint,
  String path,
) async {
  if (path != '~' && !path.startsWith('~/')) return path;

  final home = await fileSystem.canonicalize(
    endpoint is LocalEndpoint ? '~' : '.',
  );
  if (path == '~') return home;
  final suffix = path.substring(2);
  return endpoint is LocalEndpoint
      ? p.join(home, suffix)
      : remoteJoin(home, suffix);
}

bool _isAnchoredPath(SyncEndpoint endpoint, String path) {
  if (path == '~' || path.startsWith('~/')) return true;
  return endpoint is LocalEndpoint
      ? p.isAbsolute(path)
      : p.posix.isAbsolute(path);
}

Future<String> _canonicalizeWithMissingSuffix(
  RemoteFileSystem fileSystem,
  SyncEndpoint endpoint,
  String path,
) async {
  final missing = <String>[];
  var candidate = path;
  while (true) {
    try {
      await fileSystem.stat(candidate);
      var resolved = await fileSystem.canonicalize(candidate);
      for (final component in missing.reversed) {
        resolved = endpoint is LocalEndpoint
            ? p.join(resolved, component)
            : remoteJoin(resolved, component);
      }
      return resolved;
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
    }

    final parent = endpoint is LocalEndpoint
        ? p.dirname(candidate)
        : remoteParent(candidate);
    if (parent == candidate) return fileSystem.canonicalize(path);

    final component = endpoint is LocalEndpoint
        ? p.basename(candidate)
        : remoteBasename(candidate);
    if (component.isEmpty || component == '.') {
      return fileSystem.canonicalize(path);
    }
    missing.add(component);
    candidate = parent;
  }
}
