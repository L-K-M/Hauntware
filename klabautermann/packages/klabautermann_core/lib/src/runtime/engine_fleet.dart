import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart' show HostProfile;
import 'package:seance_core/catalog.dart' show EndpointPin, EndpointPinStore;
import 'package:seance_core/seance_core.dart' show ImportedHost, ServerConfig;

import '../admin/admin_mode.dart';
import '../alerts/alert_evaluator.dart';
import '../capabilities/capability_cache.dart';
import '../catalog/engine_sync.dart';
import '../docker/docker_router.dart';
import '../docker/exec_sessions.dart';
import '../forwards/port_forwards.dart';
import '../history/history_store.dart';
import '../links/channel_quota.dart';
import '../links/link_connector.dart' show ConnectPurpose;
import '../links/link_supervisor.dart';
import '../logs/log_stream_router.dart';
import '../operations/operation_tracker.dart';
import '../operations/plan_registry.dart';
import '../sampling/sampling_scheduler.dart';
import '../sampling/subscriptions.dart';
import '../services/disk_usage.dart';
import '../services/packages.dart';
import '../fleet/imported_fleet.dart';
import '../fleet/monitor_set.dart';
import '../fleet/reachability_service.dart';
import '../fleet/synced_fleet.dart';
import '../engine/protocol.dart';

/// What [EngineFleet] reads of the ssh_config import store. The engine
/// hands it these getters rather than the store itself: the store is
/// opened in the startup chain, after the fleet object exists, and each
/// import replaces its hosts, hops and detail while the engine runs.
typedef EngineImports = ({
  List<ImportedHost> Function() hosts,
  List<ImportedHost> Function() hops,
  ImportedHostDetail Function() detail,
});

/// The engine's fleet bookkeeping (ENG-11 step 2, ARC-05), moved out of
/// `engineMain` so the state every request reads and the functions that
/// rebuild it live in one place and can be tested without an isolate.
///
/// The fleet the engine serves is the sync account's servers, then the
/// imports, with the config of each import and hop it can dial, and its
/// server ids. A synced server has a config only while its endpoint is
/// confirmed on this device (03 §4.7, SAF-09), so neither the user nor a
/// background connect dials it otherwise. Imports count as confirmed on
/// the device that imported them (03 §4.3, owner question O6's default).
///
/// Every dependency is fixed at construction: a value where the engine's
/// local is final and never reassigned, a getter where the engine assigns
/// it later or replaces it ([scheduler], [logs], [docker], [imports],
/// [sync]), so no captured snapshot goes stale.
final class EngineFleet {
  EngineFleet({
    required this._sampling,
    required this._alerts,
    required this._scheduler,
    required this._logs,
    required this._operations,
    required this._channelQuotas,
    required this._links,
    required this._viewed,
    required this._terminals,
    required this._forwards,
    required this._docker,
    required this._admin,
    required this._plans,
    required this._packageReports,
    required this._diskTrees,
    required this._profiles,
    required this._capabilities,
    required this._history,
    required this._reachability,
    required this._imports,
    required this._localUser,
    required this._endpointPins,
    required this._sync,
    required this._detach,
    required this._send,
  });

  final SamplingSubscriptions _sampling;
  final AlertEvaluator _alerts;
  final SamplingScheduler? Function() _scheduler;
  final LogStreamRouter? Function() _logs;
  final OperationTracker? Function() _operations;
  final ChannelQuotas _channelQuotas;
  final LinkSupervisor? _links;
  final Set<String> _viewed;
  final ExecSessions? Function() _terminals;
  final PortForwards? Function() _forwards;
  final DockerRouter? Function() _docker;
  final AdminModeController? Function() _admin;
  final PlanRegistry _plans;
  final PackageReports _packageReports;
  final DiskUsageTrees _diskTrees;
  final Map<String, HostProfile> _profiles;
  final CapabilityCache? Function() _capabilities;
  final HistoryStore? Function() _history;
  final ReachabilityService? _reachability;
  final EngineImports _imports;
  final String? _localUser;
  final EndpointPinStore _endpointPins;
  final EngineSync Function() _sync;
  final void Function(Future<void>? work) _detach;
  final void Function(EngineEvent event) _send;

  /// The synced servers the last [refreshSynced] read from the account.
  /// Only the engine assigns it: the startup chain before the first
  /// request, and [refreshSynced] itself.
  var syncedServers = const <ServerConfig>[];

  /// The synced servers as listed against this device's pins; see
  /// [applySynced].
  var synced = SyncedFleet.empty;

  /// The current imports, rebuilt by [refreshFleet].
  late ImportedFleet _fleet;

  /// The server ids of the latest fleet snapshot, which the fleet's
  /// consumers retain against.
  var _fleetIds = <String>{};

  /// The synced servers whose endpoints count as confirmed when the next
  /// fleet is compared: those confirmed in the last one, and those whose
  /// pin, or a hop's, could not be read since they were, so a change made
  /// while the store failed is caught once it reads again. A server whose
  /// pin could not be read at startup is here too, as its cached profile
  /// was kept.
  var trustedIds = const <String>{};

  /// FL-21's monitor set (03 §4.3 step 4, §6.4): the servers whose
  /// `overview` the fleet rows read while the app is in the foreground,
  /// whether or not a view shows them, over links dialed unattended so
  /// nothing prompts. It holds eligible fleet servers only. The servers
  /// a view holds a link to ([Connect] without its [Disconnect] yet) are
  /// kept beside it: a server that leaves the set keeps the link a view
  /// holds, and a view that leaves keeps a monitored server's link.
  var _monitored = const <String>{};

  /// Whether the app has had a fleet. Probing waits for it, since the app
  /// keeps answers only for servers its fleet lists.
  var fleetSent = false;

  /// The imports as the engine lists and connects to them.
  ImportedFleet get fleet => _fleet;

  /// The fleet's server ids.
  Set<String> get fleetIds => _fleetIds;

  /// The servers the monitor set samples now.
  Set<String> get monitored => _monitored;

  /// The fleet's entries in listing order: the synced servers, then the
  /// imports.
  List<FleetEntry> fleetEntries() => [...synced.entries, ..._fleet.entries];

  /// The config of the synced server or import [id] while the engine can
  /// dial it; null otherwise.
  ServerConfig? configOf(String id) =>
      synced.serverConfig(id) ?? _fleet.serverConfig(id);

  // Probes the confirmed endpoints (FL-04, 03 §5.12); none while probes
  // are off. A server with a link is answered online without a probe.
  void probeFleet() {
    if (!fleetSent) return;
    _reachability?.update(probeTargets(fleetEntries(), configOf));
  }

  // The fleet servers the monitor set may hold now: those the shared rule
  // allows and the engine can dial, which an import naming no user lacks
  // on a system that names no local account.
  Set<String> monitorEligibleIds() => {
    for (final entry in fleetEntries())
      if (monitorEligibilityOf(entry) == MonitorEligibility.eligible &&
          configOf(entry.serverId) != null)
        entry.serverId,
  };

  // Makes [next], eligible fleet servers only, the monitor set: a server
  // that joins gets its subscription and an unattended connect, and one
  // that leaves loses both, its link only when no view holds it.
  void applyMonitorSet(Set<String> next) {
    final before = _monitored;
    _monitored = Set.unmodifiable(next);
    for (final serverId in before.difference(next)) {
      _sampling.unsubscribe(
        Unsubscribe(serverId: serverId, subscriptionId: monitorSubscriptionId),
      );
      _scheduler()?.update(serverId);
      if (_viewed.contains(serverId)) continue;
      _logs()?.disconnect(serverId);
      _links?.disconnect(serverId);
    }
    for (final serverId in next.difference(before)) {
      final subscription = Subscribe(
        serverId: serverId,
        subscriptionId: monitorSubscriptionId,
        streams: const {SampleStream.overview},
      );
      _sampling.subscribe(subscription);
      _scheduler()?.subscribed(subscription);
      _links?.connect(serverId, purpose: ConnectPurpose.background);
    }
  }

  // Rebuilds the fleet from the store. A server that left it is forgotten
  // (03 §5.1): its samplers, link and attempts end and its subscriptions
  // go. One that keeps its id under another endpoint, an import whose
  // endpoint changed or a synced server in [moved], loses what the engine
  // learned or chose for that machine: its cached profile and history,
  // Docker session and choices, admin state, reports and forwards
  // (SYN-08).
  void refreshFleet({Set<String> moved = const {}}) {
    final previous = _fleetIds.isEmpty ? null : _fleet;
    _fleet = ImportedFleet(
      _imports.hosts(),
      hops: _imports.hops(),
      localUser: _localUser,
      detail: _imports.detail(),
    );
    final before = _fleetIds;
    final entries = fleetEntries();
    _fleetIds = {for (final entry in entries) entry.serverId};
    _sampling.fleet = _fleetIds;
    _alerts
        .setFleet({
          for (final entry in entries) entry.serverId: entry.group,
        }, DateTime.now().toUtc())
        .forEach(_send);
    _scheduler()?.retain(_fleetIds);
    _logs()?.retain(_fleetIds);
    _operations()?.retain(_fleetIds);
    _channelQuotas.retain(_fleetIds);
    _links?.forget(before.difference(_fleetIds));
    _viewed.retainAll(_fleetIds);
    // A monitored server that left the fleet or is no longer eligible (a
    // sync changed its endpoint, an import its credentials) leaves the
    // set; the app hears the fleet and sends its own set again.
    if (_monitored.isNotEmpty) {
      applyMonitorSet(_monitored.intersection(monitorEligibleIds()));
    }
    final forgotten = {
      for (final id in before)
        if (!_fleetIds.contains(id) ||
            moved.contains(id) ||
            previous?.endpointOf(id) != _fleet.endpointOf(id))
          id,
    };
    _terminals()?.forget(forgotten);
    _forwards()?.forget(forgotten);
    _docker()
      ?..forget(forgotten)
      ..retain(_fleetIds);
    _admin()?.forget(forgotten);
    _plans.forget(forgotten);
    _packageReports.forget(forgotten);
    _diskTrees.forget(forgotten);
    _profiles.removeWhere((id, _) => forgotten.contains(id));
    // A kept import whose endpoint changed names another machine, so its
    // link and log streams would otherwise go on serving the old one. A
    // synced server belongs to [applySynced]: one it moved waits for the
    // user's confirmation, and one whose pins could not be read stays
    // undialed until they are.
    final importedIds = {for (final entry in _fleet.entries) entry.serverId};
    for (final id in forgotten) {
      if (!importedIds.contains(id)) continue;
      _logs()?.disconnect(id);
      _links?.disconnect(id);
      if (_viewed.contains(id)) {
        _links?.connect(id, purpose: ConnectPurpose.interactive);
      } else if (_monitored.contains(id)) {
        _links?.connect(id, purpose: ConnectPurpose.background);
      }
    }
    // Before the caller sends the fleet or an EndpointChanged, so no
    // probe of a server starts, and no answer for it goes out, once the
    // app hears it left or lost its pin.
    probeFleet();
    _detach(_capabilities()?.forget(forgotten));
    _detach(_history()?.forget(forgotten));
  }

  // Lists [servers] against this device's pins. A pin the store cannot
  // read fails closed: its server waits to be confirmed and nothing dials
  // it, but it is listed as unreadable rather than changed. The file
  // store throws only FileSystemException, for a file it cannot read
  // (corrupt files are quarantined and read as empty); anything else is
  // a bug and propagates.
  Future<SyncedFleet> listSynced(List<ServerConfig> servers) async {
    final pins = <String, EndpointPin>{};
    final unreadable = <String>{};
    for (final server in servers) {
      try {
        if (await _endpointPins.pinFor(server.id) case final pin?) {
          pins[server.id] = pin;
        }
      } on FileSystemException {
        unreadable.add(server.id);
      }
    }
    return SyncedFleet(servers, pins: pins, unreadable: unreadable);
  }

  // Takes [next] as the synced fleet. A trusted server that the account
  // still holds and that is no longer confirmed, with its pins read, had
  // its endpoint changed by a sync (03 §4.7, SYN-08): the app hears it,
  // its link and log streams close, and refreshFleet forgets what the
  // engine held for the old machine, as for a moved import. Nothing redials it until the user
  // confirms it again. One whose pins could not be read is only not
  // dialed for now: a store failure is no endpoint change. A server the
  // account no longer holds needs nothing here: refreshFleet drops it
  // from fleetIds, so its link, streams, samplers and cached profile go
  // with the retain and forget there (03 §5.1).
  void applySynced(SyncedFleet next) {
    final changed = {
      for (final id in trustedIds)
        if (next.lists(id) &&
            !next.confirmedIds.contains(id) &&
            !next.unreadableIds.contains(id))
          id,
    };
    trustedIds = {
      ...next.confirmedIds,
      for (final id in trustedIds)
        if (next.unreadableIds.contains(id)) id,
    };
    synced = next;
    refreshFleet(moved: changed);
    for (final id in changed) {
      _send(EndpointChanged(id));
      _logs()?.disconnect(id);
      _links?.disconnect(id);
    }
  }

  // Lists the synced servers again with the pins as they stand. A
  // confirmation in the request queue and a sync round beside it both
  // relist; one whose servers a round replaced while it read the pins
  // leaves the fleet to that round's own relist, which reads them later.
  Future<void> relistSynced() async {
    final servers = syncedServers;
    final next = await listSynced(servers);
    if (identical(servers, syncedServers)) applySynced(next);
  }

  // Lists the synced servers again after a round or write took, so a
  // chained operation never reads a fleet a later one replaced.
  Future<void> refreshSynced() async {
    syncedServers = await _sync().servers();
    await relistSynced();
  }
}
