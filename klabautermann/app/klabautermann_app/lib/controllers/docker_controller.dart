import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// The app's Docker endpoints for one engine run (03 §5.9, §10.1): each
/// server's [DockerEndpointState], which the server header names in
/// every mode (E4) and the Docker tab's gate follows, and the engine's
/// details (DKE-01) for the tab's engine strip.
///
/// The engine reports a server's endpoint only once a [DockerQuery] has
/// named it, and from then follows the server's link and probe itself
/// until the app lets the link go (03 §5.9). So each time a server's
/// link comes up, this sends one [DockerEngineQuery]: it starts the
/// endpoint, and answers with the engine's details once the endpoint is
/// ready, or with why not, which the endpoint's own state then says. A
/// Docker tab that shows the server ([openView]) has the details read
/// again whenever a ready endpoint has none: after a new route or API
/// version, or a read that failed.
///
/// A Containers view that shows a server ([watchContainers]) has its
/// containers and their list stats watched (03 §7.12 CTR-01, CST-01): one
/// [DockerWatch] per server while any such view shows, replaced under its
/// id as the rows on screen change ([showStatsFor]), and a
/// [DockerUnwatch] once the last view hides. The engine keeps a watch
/// across a dropped endpoint and resumes it over the next one, so only
/// the views start and end it. The lists it delivers stay here
/// ([containersFor]) after the views hide.
///
/// Every query and watch id is minted here and never reused this run; at
/// most one engine query per server is in flight. A server that leaves
/// the fleet takes its state with it and comes back without it (SYN-08),
/// as in `MonitoringController`; the engine ends its session, and with it
/// the server's watches, too.
final class DockerController {
  DockerController(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  int _count = 0;
  bool _stopped = false;

  final Map<String, _DockerServer> _servers = {};

  /// The fleet's ids from the last [CatalogReplaced] seen, as in
  /// `MonitoringController`: null until then, when every server counts
  /// as listed.
  Set<String>? _fleetIds;

  /// What the engine last said of [serverId]'s Docker endpoint, or null
  /// before it said anything this run.
  ValueListenable<DockerEndpointState?> endpointFor(String serverId) =>
      _server(serverId).endpoint;

  /// The engine's details for [serverId]'s ready endpoint: a
  /// [DockerEnginePayload], or a [DockerQueryFailed] saying why they
  /// could not be read; null while none were read for this endpoint.
  ValueListenable<DockerPayload?> engineFor(String serverId) =>
      _server(serverId).engine;

  /// What [serverId]'s container watch last delivered: the containers
  /// and their list stats, or why they could not be read.
  ValueListenable<DockerContainerList> containersFor(String serverId) =>
      _server(serverId).containers;

  /// A Containers view shows [serverId]; [unwatchContainers] says it no
  /// longer does. The first view starts the server's container watch,
  /// reading stats for [statsFor] as [showStatsFor] would.
  void watchContainers(
    String serverId, {
    Iterable<String> statsFor = const [],
  }) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.containerViews++;
    if (server.containerViews > 1) return;

    server.statsFor = statsFor.take(kDockerStatsForMax).toSet();
    _watch(serverId, server);
  }

  /// The last view to hide ends the server's container watch.
  void unwatchContainers(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.containerViews == 0) return;
    server.containerViews--;
    if (server.containerViews > 0) return;

    server.statsFor = const {};
    _unwatch(serverId, server);
  }

  /// The containers, by id, whose rows [serverId]'s Containers view shows,
  /// whose list stats the watch reads from now on (CST-01): at most
  /// [kDockerStatsForMax] of them, in order. Sends the watch again under
  /// its id, which replaces it, when they changed.
  void showStatsFor(String serverId, Iterable<String> containerIds) {
    final server = _servers[serverId];
    if (server == null || server.watchId == null) return;

    final ids = containerIds.take(kDockerStatsForMax).toSet();
    if (setEquals(ids, server.statsFor)) return;
    server.statsFor = ids;
    _watch(serverId, server);
  }

  /// Watches [serverId]'s containers anew after a failure: a watch under
  /// a new id, which the engine reads from nothing, where the same one
  /// again would change nothing it reads.
  void retryContainers(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.watchId == null) return;

    _unwatch(serverId, server);
    _watch(serverId, server);
  }

  /// Sends [serverId]'s container watch, minting its id if it has none.
  void _watch(String serverId, _DockerServer server) {
    if (_stopped) return;

    final watchId = server.watchId ??= 'containers-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.containers, DockerWatchList.stats},
        statsFor: server.statsFor,
      ),
    );
  }

  void _unwatch(String serverId, _DockerServer server) {
    final watchId = server.watchId;
    server.watchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  void _send(EngineRequest request) {
    try {
      _engine.send(request);
    } on StateError {
      _stopped = true;
    }
  }

  /// A Docker tab shows [serverId]; [closeView] says it no longer does.
  void openView(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.views++;
    _readIfShown(serverId, server);
  }

  void closeView(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.views == 0) return;
    server.views--;
  }

  /// Asks again: a failed endpoint resolves anew on the next query (03
  /// §5.9), and a ready one reads its details again.
  void retry(String serverId) {
    if (!_listed(serverId)) return;
    _read(serverId, _server(serverId));
  }

  /// Reads the details of a ready endpoint a Docker tab shows, unless
  /// they were read.
  void _readIfShown(String serverId, _DockerServer server) {
    if (server.views == 0) return;
    if (server.endpoint.value?.phase != DockerEndpointPhase.ready) return;
    if (server.engine.value is DockerEnginePayload) return;
    _read(serverId, server);
  }

  /// Sends one [DockerEngineQuery] for [serverId] unless one is in flight
  /// or the engine has stopped.
  void _read(String serverId, _DockerServer server) {
    if (server.engineQuery != null || _stopped) return;

    final queryId = 'docker-${_count++}';
    try {
      _engine.send(
        DockerQuery(
          serverId: serverId,
          queryId: queryId,
          query: const DockerEngineQuery(),
        ),
      );
    } on StateError {
      _stopped = true;
      return;
    }
    server.engineQuery = queryId;
  }

  void _onEvent(EngineEvent event) {
    switch (event) {
      case LinkState(:final serverId, :final status):
        if (!_listed(serverId)) return;
        final server = _server(serverId);
        final linked = status is LinkReady || status is LinkDegraded;
        final rose = linked && !server.linked;
        server.linked = linked;
        if (rose) _read(serverId, server);
      case DockerEndpointState(:final serverId):
        if (!_listed(serverId)) return;
        final server = _server(serverId);
        final before = server.endpoint.value;
        server.endpoint.value = event;
        // The details describe the endpoint they were read over. A read
        // still owed by a replaced ready endpoint would answer with what
        // that endpoint said, so its answer is dropped by id and the new
        // one is read.
        if (!_sameEndpoint(before, event)) {
          server.engine.value = null;
          if (before?.phase == DockerEndpointPhase.ready) {
            server.engineQuery = null;
          }
        }
        _readIfShown(serverId, server);
      case DockerResult(:final serverId, :final queryId, :final payload):
        final server = _servers[serverId];
        if (server == null || server.engineQuery != queryId) return;
        server.engineQuery = null;
        switch (payload) {
          // Nothing was read because no endpoint was ready: its state
          // says why, and once one is, a shown tab reads again.
          case DockerQueryFailed(
            failure: DockerQueryFailure.linkUnavailable ||
                DockerQueryFailure.profileUnknown ||
                DockerQueryFailure.endpointUnavailable ||
                DockerQueryFailure.cancelled,
          ):
            break;
          case _:
            server.engine.value = payload;
        }
      case DockerListChanged(
        :final serverId,
        :final list,
        :final payload,
        :final at,
      ):
        // Lists arrive for the server, whichever watch asked for them.
        final server = _servers[serverId];
        if (server == null) return;
        server.containers.value = _takeList(
          server.containers.value,
          list,
          payload,
          at,
        );
      case CatalogReplaced(:final entries):
        // SYN-08: a server leaving the fleet takes its endpoint with it.
        final ids = _fleetIds = {for (final entry in entries) entry.serverId};
        _servers.removeWhere((serverId, server) {
          if (ids.contains(serverId)) return false;
          server.dispose();
          return true;
        });
      case EngineEvent():
        break;
    }
  }

  /// A stopped engine answers nothing more.
  void _onEngineDone() {
    _stopped = true;
    for (final server in _servers.values) {
      server.engineQuery = null;
    }
  }

  bool _listed(String serverId) => _fleetIds?.contains(serverId) ?? true;

  _DockerServer _server(String serverId) =>
      _servers.putIfAbsent(serverId, _DockerServer.new);

  void dispose() {
    unawaited(_events.cancel());
    _stopped = true;
    for (final server in _servers.values) {
      server.dispose();
    }
    _servers.clear();
  }
}

/// [before] with [payload], a read of [list] at [at], taken in: a new
/// list or stats round, or a failed one, which keeps what was read
/// before. Lists other than the containers and their stats leave it as
/// it was.
DockerContainerList _takeList(
  DockerContainerList before,
  DockerWatchList list,
  DockerPayload payload,
  DateTime at,
) {
  switch ((list, payload)) {
    case (
      DockerWatchList.containers,
      DockerContainersPayload(:final containers),
    ):
      final ids = {for (final container in containers) container.id};
      return DockerContainerList(
        containers: containers,
        at: at,
        // Stats of a container that went go with it.
        stats: {
          for (final MapEntry(:key, :value) in before.stats.entries)
            if (ids.contains(key)) key: value,
        },
        statsFailure: before.statsFailure,
      );
    case (DockerWatchList.containers, final DockerQueryFailed failure):
      return before.copyWith(failure: () => failure);
    case (DockerWatchList.stats, DockerStatsPayload(:final stats)):
      return before.copyWith(
        stats: {...before.stats, for (final row in stats) row.containerId: row},
        statsFailure: () => null,
      );
    case (DockerWatchList.stats, final DockerQueryFailed failure):
      return before.copyWith(statsFailure: () => failure);
    case _:
      return before;
  }
}

/// What a server's container watch delivered (03 §7.12 CTR-01, CST-01).
@immutable
final class DockerContainerList {
  const DockerContainerList({
    this.containers,
    this.at,
    this.failure,
    this.stats = const {},
    this.statsFailure,
  });

  /// The latest list read, stopped containers too; null until one was.
  final List<ContainerSummary>? containers;

  /// When the engine read [containers], by this device's clock.
  final DateTime? at;

  /// Why the latest list read failed, or the engine refused the watch,
  /// while [containers] keeps the list before; null once one is read.
  final DockerQueryFailed? failure;

  /// Each listed container's latest list stats, by id. A container whose
  /// row left the screen keeps its last ones, which age by their
  /// [ContainerListStats.at].
  final Map<String, ContainerListStats> stats;

  /// Why the latest stats round failed; null once one succeeds.
  final DockerQueryFailed? statsFailure;

  DockerContainerList copyWith({
    DockerQueryFailed? Function()? failure,
    Map<String, ContainerListStats>? stats,
    DockerQueryFailed? Function()? statsFailure,
  }) => DockerContainerList(
    containers: containers,
    at: at,
    failure: failure == null ? this.failure : failure(),
    stats: stats ?? this.stats,
    statsFailure: statsFailure == null ? this.statsFailure : statsFailure(),
  );
}

/// Whether [after] is the ready endpoint [before] was: the same route
/// and API version.
bool _sameEndpoint(DockerEndpointState? before, DockerEndpointState after) {
  if (before == null ||
      before.phase != DockerEndpointPhase.ready ||
      after.phase != DockerEndpointPhase.ready) {
    return false;
  }
  final (a, b) = (before.route, after.route);
  if (a == null || b == null) return false;
  return before.negotiatedApi == after.negotiatedApi &&
      a.rank == b.rank &&
      a.socketPath == b.socketPath &&
      a.runtime == b.runtime &&
      a.mode == b.mode &&
      a.rootEquivalence == b.rootEquivalence;
}

/// One server's Docker state.
final class _DockerServer {
  final ValueNotifier<DockerEndpointState?> endpoint = ValueNotifier(null);
  final ValueNotifier<DockerPayload?> engine = ValueNotifier(null);
  final ValueNotifier<DockerContainerList> containers = ValueNotifier(
    const DockerContainerList(),
  );

  /// The engine query in flight, whose answer [engine] takes.
  String? engineQuery;

  /// How many Docker tabs show the server.
  int views = 0;

  /// Whether the server's last [LinkState] was a usable link.
  bool linked = false;

  /// How many Containers views show the server.
  int containerViews = 0;

  /// The container watch the engine holds, while any view shows.
  String? watchId;

  /// The containers whose stats the watch reads: the rows on screen.
  Set<String> statsFor = const {};

  void dispose() {
    endpoint.dispose();
    engine.dispose();
    containers.dispose();
  }
}
