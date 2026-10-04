// The sync feature's app-side composition root (05 §11's environment
// seam): where journals and sync_state live, which device identity
// stamps run ids, and how a pair's endpoints resolve to the
// RemoteFileSystem objects the scanner and executor speak. Local
// endpoints bind a LocalFileSystem directly (D3 — one VFS contract);
// remote endpoints lease engine-side channels through the bridged
// transfer lease (protocol v13, STATUS item 23) — and answer the honest
// `unsupported` refusal only when the engine failed to spawn.
import 'dart:async';
import 'dart:convert';
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
const int _maximumJumpHosts = 16;
const String _restoreRecoveryOperation = 'resume sync restore';

/// Opaque authenticated endpoint identity captured after a scan.
final class SyncEndpointBinding {
  const SyncEndpointBinding._(this._endpointIdentity);

  final String _endpointIdentity;
}

/// Read-only endpoint resolution for resuming one journal-owned restore.
/// Maps are keyed by the journal's sides, even when the current panes swapped.
final class SyncRestoreRecoveryContext {
  SyncRestoreRecoveryContext._({
    required Map<SyncSide, SyncEndpoint> endpoints,
    required Map<SyncSide, String> roots,
    required Map<SyncSide, SyncTrashLocation> trashLocations,
    required Map<SyncSide, SyncEndpointBinding> endpointBindings,
  }) : endpoints = Map.unmodifiable(endpoints),
       roots = Map.unmodifiable(roots),
       trashLocations = Map.unmodifiable(trashLocations),
       endpointBindings = Map.unmodifiable(endpointBindings);

  final Map<SyncSide, SyncEndpoint> endpoints;
  final Map<SyncSide, String> roots;
  final Map<SyncSide, SyncTrashLocation> trashLocations;
  final Map<SyncSide, SyncEndpointBinding> endpointBindings;
}

/// The newest recovery candidate whose durable roots identify this pair.
final class SyncRestoreRecoverySelection {
  const SyncRestoreRecoverySelection._({
    required this.journal,
    required this.context,
  });

  final SyncRunJournal journal;
  final SyncRestoreRecoveryContext context;
}

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
    this._acceptedHostKeys,
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
    HostKeyStore? acceptedHostKeys,
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
    acceptedHostKeys: acceptedHostKeys,
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
  final HostKeyStore? _acceptedHostKeys;

  /// One lease-on-demand filesystem per remote server, shared by every
  /// scan, diff, and run of every pair naming that server.
  final Map<String, LeasedRemoteFileSystem> _remote = {};

  /// Whether [endpoint] can serve a filesystem in this process — local
  /// always; remote once the engine bridge is composed.
  bool endpointAvailable(SyncEndpoint endpoint) => switch (endpoint) {
    LocalEndpoint() => true,
    RemoteEndpoint() => _connections != null && _serverConfigs != null,
  };

  /// Selects and resolves an interrupted restore without walking either sync
  /// tree or creating/reconciling trash roots. Distinct-root pair-id collisions
  /// are skipped; a matching journal must have exactly one endpoint ordering.
  Future<SyncRestoreRecoverySelection?> resolveRestoreRecoveryContext({
    required SyncPair pair,
    required Iterable<SyncRunJournal> journals,
  }) async {
    final candidates = journals.toList()
      ..sort((left, right) {
        final newest = right.record.startedAt.compareTo(left.record.startedAt);
        return newest != 0 ? newest : left.path.compareTo(right.path);
      });
    if (candidates.isEmpty) return null;

    for (final journal in candidates) {
      if (!journal.hasIncompleteRestore) {
        throw _restoreRecoveryConflict(
          journal,
          'The sync journal has no incomplete restore.',
        );
      }
      final leftRecordedRoot = journal.record.canonicalRootLeft;
      final rightRecordedRoot = journal.record.canonicalRootRight;
      if (leftRecordedRoot == null ||
          leftRecordedRoot.isEmpty ||
          rightRecordedRoot == null ||
          rightRecordedRoot.isEmpty) {
        throw _restoreRecoveryConflict(
          journal,
          'The recovery journal does not identify both canonical sync roots.',
        );
      }
    }

    final leftRoot = await _canonicalRestoreRoot(pair.left);
    final rightRoot = await _canonicalRestoreRoot(pair.right);
    for (final journal in candidates) {
      final direct = _restoreRootsMatch(
        journal: journal,
        leftEndpoint: pair.left,
        leftRoot: leftRoot,
        rightEndpoint: pair.right,
        rightRoot: rightRoot,
      );
      final swapped = _restoreRootsMatch(
        journal: journal,
        leftEndpoint: pair.right,
        leftRoot: rightRoot,
        rightEndpoint: pair.left,
        rightRoot: leftRoot,
      );
      if (!direct && !swapped) continue;
      if (direct && swapped) {
        throw _restoreRecoveryConflict(
          journal,
          'The recovery journal matches both endpoint orders.',
        );
      }
      if (SyncSide.values.any(
        (side) =>
            journal.trashScopeForSide(side) == null ||
            _journalTrashLocationKey(journal, side) == null,
      )) {
        throw _restoreRecoveryConflict(
          journal,
          'The recovery journal does not identify both sync-trash locations.',
        );
      }

      final leftJournalSide = direct ? SyncSide.left : SyncSide.right;
      final rightJournalSide = direct ? SyncSide.right : SyncSide.left;
      final left = await _resolveRestoreEndpoint(
        pair.left,
        journal,
        journalSide: leftJournalSide,
        expectedCanonicalRoot: direct
            ? journal.record.canonicalRootLeft!
            : journal.record.canonicalRootRight!,
      );
      final right = await _resolveRestoreEndpoint(
        pair.right,
        journal,
        journalSide: rightJournalSide,
        expectedCanonicalRoot: direct
            ? journal.record.canonicalRootRight!
            : journal.record.canonicalRootLeft!,
      );
      final context = direct
          ? _restoreRecoveryAssignment(
              leftForJournal: left,
              rightForJournal: right,
            )
          : _restoreRecoveryAssignment(
              leftForJournal: right,
              rightForJournal: left,
            );
      if (context == null) {
        throw _restoreRecoveryConflict(
          journal,
          'The recovery journal does not match this pair\'s endpoint identities.',
        );
      }

      return SyncRestoreRecoverySelection._(journal: journal, context: context);
    }

    return null;
  }

  Future<String> _canonicalRestoreRoot(SyncEndpoint endpoint) async {
    final requestedRoot = rootFor(endpoint);
    final fileSystem = fileSystemFor(endpoint);

    Future<String> resolve(
      RemoteFileSystem exactFileSystem,
      AuthenticatedEndpointIdentity? _,
    ) => exactFileSystem.canonicalize(requestedRoot);

    if (fileSystem is LeasedRemoteFileSystem) {
      return fileSystem.withAuthenticatedFileSystem(resolve);
    }

    return resolve(fileSystem, null);
  }

  bool _restoreRootsMatch({
    required SyncRunJournal journal,
    required SyncEndpoint leftEndpoint,
    required String leftRoot,
    required SyncEndpoint rightEndpoint,
    required String rightRoot,
  }) =>
      _canonicalRestoreRootsEqual(
        leftEndpoint,
        leftRoot,
        journal.record.canonicalRootLeft!,
      ) &&
      _canonicalRestoreRootsEqual(
        rightEndpoint,
        rightRoot,
        journal.record.canonicalRootRight!,
      );

  Future<_RestoreEndpointContext> _resolveRestoreEndpoint(
    SyncEndpoint endpoint,
    SyncRunJournal journal, {
    required SyncSide journalSide,
    required String expectedCanonicalRoot,
  }) async {
    final requestedRoot = rootFor(endpoint);
    final initialBinding = _trashEndpointBinding(endpoint, requestedRoot);
    final fileSystem = fileSystemFor(endpoint);

    Future<_RestoreEndpointContext> resolve(
      RemoteFileSystem exactFileSystem,
      AuthenticatedEndpointIdentity? authenticatedIdentity,
    ) async {
      final canonicalRoot = await exactFileSystem.canonicalize(requestedRoot);
      if (!_canonicalRestoreRootsEqual(
        endpoint,
        canonicalRoot,
        expectedCanonicalRoot,
      )) {
        throw _restoreRecoveryConflict(
          journal,
          'The sync root changed while restore recovery was being verified.',
        );
      }
      final endpointIdentity = await _trashEndpointIdentityAfterAccess(
        endpoint,
        initialBinding,
        canonicalRoot,
        authenticatedIdentity: authenticatedIdentity,
      );
      SyncTrashLocation? location;
      try {
        location = await _openRestoreTrashLocation(
          endpoint: endpoint,
          canonicalRoot: canonicalRoot,
          journal: journal,
          journalSide: journalSide,
          fileSystem: exactFileSystem,
          endpointIdentity: endpointIdentity,
          authenticatedIdentity: authenticatedIdentity,
        );
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.notFound &&
            error.kind != RemoteFileErrorKind.conflict) {
          rethrow;
        }
      }

      return _RestoreEndpointContext(
        endpoint: endpoint,
        canonicalRoot: canonicalRoot,
        endpointBinding: SyncEndpointBinding._(endpointIdentity),
        locations: {journalSide: location},
      );
    }

    if (fileSystem is LeasedRemoteFileSystem) {
      return fileSystem.withAuthenticatedFileSystem(resolve);
    }

    return resolve(fileSystem, null);
  }

  Future<SyncTrashLocation?> _openRestoreTrashLocation({
    required SyncEndpoint endpoint,
    required String canonicalRoot,
    required SyncRunJournal journal,
    required SyncSide journalSide,
    required RemoteFileSystem fileSystem,
    required String endpointIdentity,
    required AuthenticatedEndpointIdentity? authenticatedIdentity,
  }) async {
    final configured = switch (journalSide) {
      SyncSide.left => journal.record.rules.trashPathLeft,
      SyncSide.right => journal.record.rules.trashPathRight,
    };
    final configuredRoot = _resolveTrashPath(
      endpoint,
      canonicalRoot,
      configured,
    );
    final expandedRoot = await _expandTrashHome(
      fileSystem,
      endpoint,
      configuredRoot,
    );
    final pathStyle = endpoint is LocalEndpoint && Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    final identity = await resolveSyncTrashRoot(
      fileSystem,
      expandedRoot,
      pathStyle: pathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    await _verifyTrashEndpointIdentity(
      endpoint,
      endpointIdentity,
      identity.canonicalRoot,
      authenticatedIdentity: authenticatedIdentity,
    );
    if (identity.scopeKey != journal.trashScopeForSide(journalSide)) {
      return null;
    }

    final expectedLocationKey = _journalTrashLocationKey(journal, journalSide)!;
    final pathCases = configured == null
        ? const [SyncTrashPathCase.sensitive, SyncTrashPathCase.insensitive]
        : const [SyncTrashPathCase.sensitive];
    for (final pathCase in pathCases) {
      final locationKey = syncTrashLocationKey(
        endpoint: endpoint,
        trashRoot: configuredRoot,
        pathCase: pathCase,
        endpointIdentity: endpointIdentity,
      );
      if (expectedLocationKey != locationKey) continue;

      return syncTrashLocation(
        endpoint: endpoint,
        canonicalRoot: canonicalRoot,
        rules: journal.record.rules,
        side: journalSide,
        rootId: identity.rootId,
        resolvedTrashRoot: identity.canonicalRoot,
        pathCase: pathCase,
        locationKey: locationKey,
        locationKeyRoot: configuredRoot,
      );
    }

    return null;
  }

  SyncRestoreRecoveryContext? _restoreRecoveryAssignment({
    required _RestoreEndpointContext leftForJournal,
    required _RestoreEndpointContext rightForJournal,
  }) {
    final leftLocation = leftForJournal.locations[SyncSide.left];
    final rightLocation = rightForJournal.locations[SyncSide.right];
    if (leftLocation == null || rightLocation == null) return null;

    return SyncRestoreRecoveryContext._(
      endpoints: {
        SyncSide.left: leftForJournal.endpoint,
        SyncSide.right: rightForJournal.endpoint,
      },
      roots: {
        SyncSide.left: leftForJournal.canonicalRoot,
        SyncSide.right: rightForJournal.canonicalRoot,
      },
      trashLocations: {
        SyncSide.left: leftLocation,
        SyncSide.right: rightLocation,
      },
      endpointBindings: {
        SyncSide.left: leftForJournal.endpointBinding,
        SyncSide.right: rightForJournal.endpointBinding,
      },
    );
  }

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

  /// Captures the exact authenticated endpoint used by the preceding scan.
  Future<SyncEndpointBinding> endpointBindingAfterAccess(
    SyncEndpoint endpoint,
  ) async {
    final path = rootFor(endpoint);
    final initialBinding = _trashEndpointBinding(endpoint, path);
    final fileSystem = fileSystemFor(endpoint);
    if (fileSystem is LeasedRemoteFileSystem) {
      return fileSystem.withAuthenticatedFileSystem((_, identity) async {
        final endpointIdentity = await _trashEndpointIdentityAfterAccess(
          endpoint,
          initialBinding,
          path,
          authenticatedIdentity: identity,
        );
        return SyncEndpointBinding._(endpointIdentity);
      });
    }

    final endpointIdentity = await _trashEndpointIdentityAfterAccess(
      endpoint,
      initialBinding,
      path,
    );
    return SyncEndpointBinding._(endpointIdentity);
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
    final configuredTrashPath = switch (side) {
      SyncSide.left => rules.trashPathLeft,
      SyncSide.right => rules.trashPathRight,
    };
    final effectivePathCase = _trashRootPathCase(configuredTrashPath, pathCase);
    final trashRoot = _resolveTrashPath(
      endpoint,
      canonicalRoot,
      configuredTrashPath,
    );
    String endpointIdentity;
    try {
      endpointIdentity = await _trashEndpointIdentity(endpoint, canonicalRoot);
    } on RemoteFileException {
      // An unresolved catalog cannot safely reuse a host-scoped cache.
      endpointIdentity = _unverifiedTrashEndpointIdentity(endpoint);
    }

    return unresolvedSyncTrashLocation(
      endpoint: endpoint,
      trashRoot: trashRoot,
      pathCase: effectivePathCase,
      locationKey: syncTrashLocationKey(
        endpoint: endpoint,
        trashRoot: trashRoot,
        pathCase: effectivePathCase,
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
    final fileSystem = fileSystemFor(endpoint);
    final expanded = await _expandTrashHome(fileSystem, endpoint, unresolved);

    return _canonicalizeWithMissingSuffix(fileSystem, endpoint, expanded);
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
    final initialEndpointBinding = _trashEndpointBinding(
      endpoint,
      canonicalRoot,
    );
    final fileSystem = fileSystemFor(endpoint);
    if (fileSystem is LeasedRemoteFileSystem) {
      return fileSystem.withAuthenticatedFileSystem(
        (boundFileSystem, identity) => _resolveTrashLocationWithFileSystem(
          endpoint: endpoint,
          canonicalRoot: canonicalRoot,
          rules: rules,
          side: side,
          pathCase: pathCase,
          initialEndpointBinding: initialEndpointBinding,
          fileSystem: boundFileSystem,
          authenticatedIdentity: identity,
        ),
      );
    }

    return _resolveTrashLocationWithFileSystem(
      endpoint: endpoint,
      canonicalRoot: canonicalRoot,
      rules: rules,
      side: side,
      pathCase: pathCase,
      initialEndpointBinding: initialEndpointBinding,
      fileSystem: fileSystem,
    );
  }

  Future<SyncTrashLocation> _resolveTrashLocationWithFileSystem({
    required SyncEndpoint endpoint,
    required String canonicalRoot,
    required SyncRuleSet rules,
    required SyncSide side,
    required SyncTrashPathCase pathCase,
    required _TrashEndpointBinding initialEndpointBinding,
    required RemoteFileSystem fileSystem,
    AuthenticatedEndpointIdentity? authenticatedIdentity,
  }) async {
    final configuredTrashPath = switch (side) {
      SyncSide.left => rules.trashPathLeft,
      SyncSide.right => rules.trashPathRight,
    };
    final effectivePathCase = _trashRootPathCase(configuredTrashPath, pathCase);
    final configuredTrashRoot = _resolveTrashPath(
      endpoint,
      canonicalRoot,
      configuredTrashPath,
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
    final endpointIdentity = await _trashEndpointIdentityAfterAccess(
      endpoint,
      initialEndpointBinding,
      resolved,
      authenticatedIdentity: authenticatedIdentity,
    );
    final pathStyle = endpoint is LocalEndpoint && Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    Future<void> verifyEndpoint(String path) => _verifyTrashEndpointIdentity(
      endpoint,
      endpointIdentity,
      path,
      authenticatedIdentity: authenticatedIdentity,
    );
    await verifyEndpoint(resolved);
    final locationKey = syncTrashLocationKey(
      endpoint: endpoint,
      trashRoot: configuredTrashRoot,
      pathCase: effectivePathCase,
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
          pathCase: effectivePathCase,
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
    await verifyEndpoint(resolved);

    final pendingLocation = unresolvedSyncTrashLocation(
      endpoint: endpoint,
      trashRoot: resolved,
      pathCase: effectivePathCase,
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
      await verifyEndpoint(resolved);

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
          pathCase: effectivePathCase,
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
          pathCase: effectivePathCase,
          endpointIdentity: endpointIdentity,
          endpoint: endpoint,
          authenticatedIdentity: authenticatedIdentity,
        );
        await verifyEndpoint(resolved);

        return locationFor(verifiedIdentity);
      }
      if (verifiedError?.kind == RemoteFileErrorKind.conflict &&
          priorScopes.isNotEmpty) {
        throw verifiedError!;
      }

      if (verifiedError?.kind == RemoteFileErrorKind.notFound) {
        await verifyEndpoint(resolved);
      }
      final identity = await resolveSyncTrashRoot(
        fileSystem,
        resolved,
        pathStyle: pathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      await verifyEndpoint(resolved);
      await _retireAbsentTrashScopes(
        fileSystem: fileSystem,
        service: service,
        trashRoot: resolved,
        locationKey: locationKey,
        identity: identity,
        priorScopes: priorScopes,
        pathStyle: pathStyle,
        pathCase: effectivePathCase,
        endpointIdentity: endpointIdentity,
        endpoint: endpoint,
        authenticatedIdentity: authenticatedIdentity,
      );

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
    required AuthenticatedEndpointIdentity? authenticatedIdentity,
  }) async {
    final staleScopes = priorScopes
        .where((scope) => scope != identity.scopeKey)
        .toSet();
    if (staleScopes.isEmpty) return;

    final runIdsByScope = await service.trashRunIdsByLocationScope(locationKey);
    final listing = await fileSystem.listDirectory(identity.canonicalRoot);
    final listedNames = {
      for (final entry in listing)
        normalizeSyncTrashPath(entry.name, pathStyle, pathCase),
    };
    for (final scope in staleScopes) {
      for (final runId in runIdsByScope[scope] ?? const <String>{}) {
        final runName = normalizeSyncTrashPath(runId, pathStyle, pathCase);
        if (listedNames.any(
          (name) => name == runName || name.startsWith('$runName.purging-'),
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

    await _verifyTrashEndpointIdentity(
      endpoint,
      endpointIdentity,
      trashRoot,
      authenticatedIdentity: authenticatedIdentity,
    );

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
    final binding = _trashEndpointBinding(endpoint, path);
    try {
      return await _requireTrashEndpointIdentity(binding, path);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.unsupported) rethrow;
    }

    final store = _acceptedHostKeys;
    final host = binding.host;
    final port = binding.port;
    if (host == null || port == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'resolve sync trash',
        path: path,
        message: _syncEnvironmentLocalizations().syncTrashHostKeyUnavailable,
      );
    }
    var pin = await store?.get(host, port);
    if (pin == null && store != null) {
      final normalizedHost = host.trim().toLowerCase();
      final matches = (await store.all())
          .where(
            (candidate) =>
                candidate.host.trim().toLowerCase() == normalizedHost &&
                candidate.port == port,
          )
          .toList(growable: false);
      final fingerprints = {
        for (final candidate in matches) candidate.fingerprintSha256,
      };
      if (fingerprints.length == 1) pin = matches.first;
    }
    if (pin == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'resolve sync trash',
        path: path,
        message: _syncEnvironmentLocalizations().syncTrashHostKeyUnavailable,
      );
    }

    return _remoteTrashEndpointIdentity(
      AuthenticatedEndpointIdentity(
        host: host,
        port: port,
        username: binding.username!,
        fingerprintSha256: pin.fingerprintSha256,
        jumpHostId: binding.jumpHostId,
        routeContext: binding.routeContext,
      ),
    );
  }

  _TrashEndpointBinding _trashEndpointBinding(
    SyncEndpoint endpoint,
    String path,
  ) {
    if (endpoint is LocalEndpoint) {
      return const _TrashEndpointBinding(
        kind: _TrashEndpointKind.local,
        addressIdentity: 'local',
      );
    }
    final server = switch (endpoint) {
      RemoteEndpoint(:final server) => server,
      LocalEndpoint() => throw StateError('local endpoint already handled'),
    };

    final configs = _serverConfigs;
    if (configs == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'resolve sync trash',
        path: path,
        message: 'remote sync endpoints are not available yet',
      );
    }
    final resolved = configs.resolveEndpoint(server);
    final serverId = resolved.serverId;
    final config = resolved.config;
    final routeContext = _trashRouteContext(config, path);
    return _TrashEndpointBinding(
      kind: _TrashEndpointKind.remote,
      addressIdentity: _remoteTrashAddressIdentity(
        host: config.host,
        port: config.port,
        username: config.username,
        jumpHostId: config.jumpHostId,
        routeContext: routeContext,
      ),
      serverId: serverId,
      host: config.host,
      port: config.port,
      username: config.username.trim(),
      jumpHostId: config.jumpHostId,
      routeContext: routeContext,
    );
  }

  String? _trashRouteContext(ServerConfig target, String path) {
    if (target.jumpHostId == null) return null;
    final configs = _serverConfigs!;
    final route = <List<Object?>>[];
    final visited = <String>{target.id};
    var current = target;

    while (current.jumpHostId != null) {
      final jumpHostId = current.jumpHostId!;
      if (!visited.add(jumpHostId) || route.length >= _maximumJumpHosts) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'resolve sync trash',
          path: path,
          message: _syncEnvironmentLocalizations().syncTrashJumpRouteInvalid,
        );
      }
      final jump = configs.catalogConfigFor(jumpHostId);
      if (jump == null) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.notFound,
          operation: 'resolve sync trash',
          path: path,
          message: _syncEnvironmentLocalizations().syncTrashJumpHostUnavailable,
        );
      }
      route.add([
        jump.id,
        jump.host.trim().toLowerCase(),
        jump.port,
        jump.username.trim(),
        jump.jumpHostId,
      ]);
      current = jump;
    }

    return jsonEncode(route);
  }

  Future<String> _trashEndpointIdentityAfterAccess(
    SyncEndpoint endpoint,
    _TrashEndpointBinding expected,
    String path, {
    AuthenticatedEndpointIdentity? authenticatedIdentity,
  }) async {
    final actual = _trashEndpointBinding(endpoint, path);
    if (expected.addressIdentity != actual.addressIdentity) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'resolve sync trash',
        path: path,
        message: _syncEnvironmentLocalizations().syncTrashEndpointChanged,
      );
    }

    return _requireTrashEndpointIdentity(
      actual,
      path,
      authenticatedIdentity: authenticatedIdentity,
    );
  }

  Future<String> _requireTrashEndpointIdentity(
    _TrashEndpointBinding binding,
    String path, {
    AuthenticatedEndpointIdentity? authenticatedIdentity,
  }) async {
    if (binding.kind == _TrashEndpointKind.local) {
      return binding.addressIdentity;
    }

    final remote = _remote[binding.serverId];
    final identity =
        authenticatedIdentity ?? await remote?.heldEndpointIdentity();
    if (identity == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'resolve sync trash',
        path: path,
        message:
            _syncEnvironmentLocalizations().syncTrashAuthenticationUnavailable,
      );
    }
    return _requireAuthenticatedTrashEndpointIdentity(binding, path, identity);
  }

  String _requireAuthenticatedTrashEndpointIdentity(
    _TrashEndpointBinding binding,
    String path,
    AuthenticatedEndpointIdentity identity,
  ) {
    final leaseAddress = _remoteTrashAddressIdentity(
      host: identity.host,
      port: identity.port,
      username: identity.username,
      jumpHostId: identity.jumpHostId,
      routeContext: identity.routeContext,
    );
    if (leaseAddress != binding.addressIdentity) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'resolve sync trash',
        path: path,
        message: _syncEnvironmentLocalizations().syncTrashEndpointChanged,
      );
    }

    return _remoteTrashEndpointIdentity(identity);
  }

  String _unverifiedTrashEndpointIdentity(SyncEndpoint endpoint) =>
      switch (endpoint) {
        LocalEndpoint() => 'unverified\u0000local',
        RemoteEndpoint(:final server) =>
          server.identity == null
              ? 'unverified\u0000config\u0000${server.serverConfigId}'
              : 'unverified\u0000embedded\u0000'
                    '${server.identity!.username}\u0000'
                    '${server.identity!.host.toLowerCase()}\u0000'
                    '${server.identity!.port}',
      };

  Future<void> _verifyTrashEndpointIdentity(
    SyncEndpoint endpoint,
    String expected,
    String path, {
    AuthenticatedEndpointIdentity? authenticatedIdentity,
  }) async {
    final binding = _trashEndpointBinding(endpoint, path);
    final actual = await _requireTrashEndpointIdentity(
      binding,
      path,
      authenticatedIdentity: authenticatedIdentity,
    );
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
  ) => withVerifiedTrashLocation(endpoint, location, (_) async {});

  /// Keeps the authenticated lease fixed from verification through [body].
  Future<T> withVerifiedTrashLocation<T>(
    SyncEndpoint endpoint,
    SyncTrashLocation location,
    Future<T> Function(RemoteFileSystem fileSystem) body,
  ) => withVerifiedTrashLocations([
    (endpoint: endpoint, location: location),
  ], (fileSystems) => body(fileSystems.single));

  /// Binds every endpoint and verifies its optional trash location.
  Future<T> withVerifiedTrashLocations<T>(
    Iterable<({SyncEndpoint endpoint, SyncTrashLocation? location})> locations,
    Future<T> Function(List<RemoteFileSystem> fileSystems) body, {
    List<SyncEndpointBinding?> endpointBindings = const [],
  }) {
    final requested = locations.toList(growable: false);
    if (endpointBindings.isNotEmpty &&
        endpointBindings.length != requested.length) {
      throw ArgumentError.value(
        endpointBindings,
        'endpointBindings',
        'must match the endpoint count',
      );
    }
    final pending = [
      for (var index = 0; index < requested.length; index++)
        (
          endpoint: requested[index].endpoint,
          location: requested[index].location,
          endpointBinding: endpointBindings.isEmpty
              ? null
              : endpointBindings[index],
        ),
    ];
    final bound = List<RemoteFileSystem?>.filled(pending.length, null);
    final identities = List<AuthenticatedEndpointIdentity?>.filled(
      pending.length,
      null,
    );

    Future<void> verify(
      ({
        SyncEndpoint endpoint,
        SyncTrashLocation? location,
        SyncEndpointBinding? endpointBinding,
      })
      current,
      RemoteFileSystem fileSystem,
      AuthenticatedEndpointIdentity? identity,
    ) async {
      final expectedEndpoint = current.endpointBinding;
      if (expectedEndpoint != null) {
        await _verifyTrashEndpointIdentity(
          current.endpoint,
          expectedEndpoint._endpointIdentity,
          current.location?.trashRoot ?? rootFor(current.endpoint),
          authenticatedIdentity: identity,
        );
      }

      final location = current.location;
      if (location != null) {
        await _verifyTrashLocationWithFileSystem(
          current.endpoint,
          location,
          fileSystem,
          authenticatedIdentity: identity,
        );
        return;
      }
      if (identity == null) return;

      final path = rootFor(current.endpoint);
      final binding = _trashEndpointBinding(current.endpoint, path);
      await _requireTrashEndpointIdentity(
        binding,
        path,
        authenticatedIdentity: identity,
      );
    }

    Future<T> hold(int index) async {
      if (index == pending.length) {
        // Later lease waits can outlive a catalog retarget. Recheck every
        // endpoint while all exact transports remain held before mutating.
        for (
          var currentIndex = 0;
          currentIndex < pending.length;
          currentIndex++
        ) {
          await verify(
            pending[currentIndex],
            bound[currentIndex]!,
            identities[currentIndex],
          );
        }

        // Marker reads above may yield. This identity-only pass is fully
        // synchronous, so a catalog retarget cannot land before [body].
        for (
          var currentIndex = 0;
          currentIndex < pending.length;
          currentIndex++
        ) {
          final identity = identities[currentIndex];
          if (identity == null) continue;

          final current = pending[currentIndex];
          final path = current.location?.trashRoot ?? rootFor(current.endpoint);
          final binding = _trashEndpointBinding(current.endpoint, path);
          final endpointIdentity = _requireAuthenticatedTrashEndpointIdentity(
            binding,
            path,
            identity,
          );
          final expectedEndpoint = current.endpointBinding;
          if (expectedEndpoint == null ||
              endpointIdentity == expectedEndpoint._endpointIdentity) {
            continue;
          }

          throw RemoteFileException(
            kind: RemoteFileErrorKind.conflict,
            operation: 'resolve sync trash',
            path: path,
            message: _syncEnvironmentLocalizations().syncTrashEndpointChanged,
          );
        }

        return body([for (final fileSystem in bound) fileSystem!]);
      }
      final current = pending[index];
      final fileSystem = fileSystemFor(current.endpoint);

      Future<T> continueWith(
        RemoteFileSystem exactFileSystem,
        AuthenticatedEndpointIdentity? identity,
      ) async {
        await verify(current, exactFileSystem, identity);

        bound[index] = exactFileSystem;
        identities[index] = identity;
        try {
          return await hold(index + 1);
        } finally {
          bound[index] = null;
          identities[index] = null;
        }
      }

      if (fileSystem is LeasedRemoteFileSystem) {
        return fileSystem.withAuthenticatedFileSystem(continueWith);
      }

      return continueWith(fileSystem, null);
    }

    return hold(0);
  }

  /// Verifies optional trash roots and their independent scan identities.
  Future<T> withVerifiedEndpointBindings<T>(
    Iterable<
      ({
        SyncEndpoint endpoint,
        SyncTrashLocation? location,
        SyncEndpointBinding? endpointBinding,
      })
    >
    bindings,
    Future<T> Function(List<RemoteFileSystem> fileSystems) body,
  ) {
    final pending = bindings.toList(growable: false);
    return withVerifiedTrashLocations(
      [
        for (final binding in pending)
          (endpoint: binding.endpoint, location: binding.location),
      ],
      body,
      endpointBindings: [
        for (final binding in pending) binding.endpointBinding,
      ],
    );
  }

  /// Rebinds both sync roots on the already-held restore filesystems, then
  /// enters [body]. External trash roots cannot substitute for this check.
  Future<T> withReboundRestoreRecoveryRoots<T>({
    required SyncRunJournal journal,
    required SyncRestoreRecoveryContext context,
    required Map<SyncSide, RemoteFileSystem> fileSystems,
    required Future<T> Function() body,
  }) async {
    for (final side in SyncSide.values) {
      final endpoint = context.endpoints[side]!;
      final canonicalRoot = await fileSystems[side]!.canonicalize(
        rootFor(endpoint),
      );
      if (_canonicalRestoreRootsEqual(
        endpoint,
        canonicalRoot,
        context.roots[side]!,
      )) {
        continue;
      }

      throw _restoreRecoveryConflict(
        journal,
        'The sync root changed while restore recovery was being verified.',
      );
    }

    return body();
  }

  Future<void> _verifyTrashLocationWithFileSystem(
    SyncEndpoint endpoint,
    SyncTrashLocation location,
    RemoteFileSystem fileSystem, {
    AuthenticatedEndpointIdentity? authenticatedIdentity,
  }) async {
    final endpointBinding = _trashEndpointBinding(endpoint, location.trashRoot);
    final identity = await resolveSyncTrashRoot(
      fileSystem,
      location.trashRoot,
      pathStyle: location.pathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    final endpointIdentity = await _trashEndpointIdentityAfterAccess(
      endpoint,
      endpointBinding,
      location.trashRoot,
      authenticatedIdentity: authenticatedIdentity,
    );
    await _verifyTrashEndpointIdentity(
      endpoint,
      endpointIdentity,
      location.trashRoot,
      authenticatedIdentity: authenticatedIdentity,
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

enum _TrashEndpointKind { local, remote }

final class _RestoreEndpointContext {
  const _RestoreEndpointContext({
    required this.endpoint,
    required this.canonicalRoot,
    required this.endpointBinding,
    required this.locations,
  });

  final SyncEndpoint endpoint;
  final String canonicalRoot;
  final SyncEndpointBinding endpointBinding;
  final Map<SyncSide, SyncTrashLocation?> locations;
}

RemoteFileException _restoreRecoveryConflict(
  SyncRunJournal journal,
  String message,
) => RemoteFileException(
  kind: RemoteFileErrorKind.conflict,
  operation: _restoreRecoveryOperation,
  path: journal.path,
  message: message,
);

String? _journalTrashLocationKey(SyncRunJournal journal, SyncSide side) =>
    switch (side) {
      SyncSide.left => journal.record.trashLocationKeyLeft,
      SyncSide.right => journal.record.trashLocationKeyRight,
    };

bool _canonicalRestoreRootsEqual(
  SyncEndpoint endpoint,
  String current,
  String recorded,
) {
  // Recovery runs before case-sensitivity probes. Folding path components
  // could bind a journal to a distinct case-sensitive Windows directory.
  if (endpoint is! LocalEndpoint || !Platform.isWindows) {
    return current == recorded;
  }

  return _normalizeWindowsDriveLetter(current) ==
      _normalizeWindowsDriveLetter(recorded);
}

String _normalizeWindowsDriveLetter(String path) {
  final normalized = p.windows.normalize(path);
  if (normalized.length < 2 || normalized[1] != ':') return normalized;

  return '${normalized[0].toUpperCase()}${normalized.substring(1)}';
}

final class _TrashEndpointBinding {
  const _TrashEndpointBinding({
    required this.kind,
    required this.addressIdentity,
    this.serverId,
    this.host,
    this.port,
    this.username,
    this.jumpHostId,
    this.routeContext,
  });

  final _TrashEndpointKind kind;
  final String addressIdentity;
  final String? serverId;
  final String? host;
  final int? port;
  final String? username;
  final String? jumpHostId;
  final String? routeContext;
}

String _remoteTrashAddressIdentity({
  required String host,
  required int port,
  required String username,
  required String? jumpHostId,
  required String? routeContext,
}) =>
    'remote\u0000${username.trim()}\u0000${host.trim().toLowerCase()}'
    '\u0000$port\u0000${jumpHostId ?? ''}\u0000${routeContext ?? ''}';

String _remoteTrashEndpointIdentity(AuthenticatedEndpointIdentity identity) =>
    '${_remoteTrashAddressIdentity(host: identity.host, port: identity.port, username: identity.username, jumpHostId: identity.jumpHostId, routeContext: identity.routeContext)}'
    '\u0000${identity.fingerprintSha256}';

/// Custom paths may cross onto a filesystem with different case rules.
SyncTrashPathCase _trashRootPathCase(
  String? configured,
  SyncTrashPathCase scannedRootCase,
) => configured == null ? scannedRootCase : SyncTrashPathCase.sensitive;

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
