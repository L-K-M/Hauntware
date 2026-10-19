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
/// Every query id is minted here and never reused this run; at most one
/// engine query per server is in flight. A server that leaves the fleet
/// takes its state with it and comes back without it (SYN-08), as in
/// `MonitoringController`; the engine ends its session too.
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

  /// The engine query in flight, whose answer [engine] takes.
  String? engineQuery;

  /// How many Docker tabs show the server.
  int views = 0;

  /// Whether the server's last [LinkState] was a usable link.
  bool linked = false;

  void dispose() {
    endpoint.dispose();
    engine.dispose();
  }
}
