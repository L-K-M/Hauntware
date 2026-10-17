/// The engine's Docker endpoints (03 §5.8, §5.9, §10.1): one session per
/// server a [DockerQuery] named, which finds the route over the server's
/// ready link once its capability probe has answered, negotiates the API
/// over it and runs the queries.
///
/// ```text
///   first query ─▶ waiting (no link, or no probe answer on it): the
///                    │ query is answered at once with that failure
///                    │ link ready and probed
///                    ▼
///                  resolving: ladder ─▶ _ping, /version over the route
///                    │   └─ no answer ─▶ ladder again without that route
///                    ├─▶ ready ─▶ queries run
///                    └─▶ failed (no route, unreachable, version refused)
///   new link, changed sockets or tools, a route that drops ─▶ resolving
///   a query while failed ─▶ resolving again
///   Disconnect, fleet removal, endpoint change (SYN-08) ─▶ session ends
/// ```
library;

import 'dart:async';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show EngineRuntime, HostProfile;
import 'package:seance_core/seance_core.dart' show SshLink, SshLinkClosed;

import '../engine/protocol.dart';
import '../links/channel_quota.dart';
import 'docker_ladder.dart';
import 'inspect_masking.dart';

/// The most queries one server holds while its endpoint resolves [E]: a
/// Docker view asks a few at once, and more means the app is stuck.
const kDockerQueriesWaitingMax = 32;

/// How long `_ping` and `/version` may take over a route before the
/// session tries the next one [E].
const _answerTimeout = Duration(seconds: 10);

/// How long a relay's pooled connections stay open without a query
/// (M9 [E]): each holds a session channel.
const _relayIdle = Duration(seconds: 30);

/// Owned by the engine isolate, which hands it the Docker queries and
/// tells it what changed: [update] after a server's [LinkState],
/// [probed] for each probe answer, [disconnect], [forget] for servers
/// that left the fleet or changed endpoint, [retain] for the fleet and
/// [close].
final class DockerRouter {
  /// [linkFor] gives a server's ready link, null while it has none.
  /// [startTimer] arms the relays' idle close; tests pass a fake clock.
  DockerRouter({
    required this._linkFor,
    required this._emit,
    this._startTimer = Timer.new,
  });

  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;
  final Timer Function(Duration duration, void Function() callback) _startTimer;

  final Map<String, _Session> _sessions = {};
  final Map<String, HostProfile> _profiles = {};
  final Set<Future<void>> _closing = {};
  Set<String> _fleet = const {};

  /// Accepts [request]: while its server has no ready link or no probe
  /// answer it is answered at once with that failure; otherwise it waits
  /// for the endpoint to resolve and runs once it is ready. Every query
  /// gets exactly one [DockerResult].
  void query(DockerQuery request) {
    if (!_fleet.contains(request.serverId)) {
      return _answer(request, DockerQueryFailure.notInFleet);
    }
    if (request.query case DockerContainerQuery(containerId: '')) {
      return _answer(request, DockerQueryFailure.invalidQuery);
    }

    final session = _sessions.putIfAbsent(
      request.serverId,
      () => _Session(request.serverId),
    );
    if (session.waiting.length >= kDockerQueriesWaitingMax) {
      return _answer(request, DockerQueryFailure.tooManyQueries);
    }
    session.waiting.add(request);
    _pump(session);
  }

  /// Follows [serverId]'s link: a new link resolves the endpoint again,
  /// and none leaves it waiting.
  void update(String serverId) {
    if (_sessions[serverId] case final session?) _pump(session);
  }

  /// Takes [profile], a probe answer for [serverId]. One whose sockets,
  /// tools or sudo differ from the last resolves the endpoint again.
  void probed(String serverId, HostProfile profile) {
    final before = _profiles[serverId];
    _profiles[serverId] = profile;
    final session = _sessions[serverId];
    if (session == null) return;

    if (before == null || _ladderInputs(before) != _ladderInputs(profile)) {
      _drop(session);
    }
    _pump(session);
  }

  /// Ends [serverId]'s session: the app let its link go.
  void disconnect(String serverId) {
    if (_sessions.remove(serverId) case final session?) _end(session);
  }

  /// Ends the sessions of [serverIds] and forgets their probe answers:
  /// they left the fleet, or their endpoint now names another machine
  /// (SYN-08).
  void forget(Iterable<String> serverIds) {
    for (final serverId in serverIds) {
      _profiles.remove(serverId);
      disconnect(serverId);
    }
  }

  /// Takes [fleet] as the servers queries may name, and forgets every
  /// server outside it.
  void retain(Set<String> fleet) {
    _fleet = fleet;
    forget(
      {
        ..._sessions.keys,
        ..._profiles.keys,
      }.where((serverId) => !fleet.contains(serverId)),
    );
  }

  /// Ends every session; completes once their connections have closed.
  Future<void> close() async {
    for (final serverId in _sessions.keys.toList()) {
      disconnect(serverId);
    }
    while (_closing.isNotEmpty) {
      await Future.wait(_closing.toList());
    }
  }

  // -- sessions -------------------------------------------------------

  /// Moves [session] on as far as its link and probe answer allow. A
  /// closed link the supervisor has not reported yet counts as none.
  void _pump(_Session session) {
    var link = _linkFor(session.serverId);
    if (link?.state is SshLinkClosed) link = null;
    if (!identical(link, session.link)) {
      _drop(session);
      session.link = link;
    }

    final profile = _profiles[session.serverId];
    if (link == null || profile == null) {
      _answerWaiting(
        session,
        link == null
            ? DockerQueryFailure.linkUnavailable
            : DockerQueryFailure.profileUnknown,
      );
      _state(session, DockerEndpointPhase.waiting);
      return;
    }

    if (session.endpoint case final endpoint?) {
      final queries = session.waiting.toList();
      session.waiting.clear();
      for (final query in queries) {
        unawaited(_run(session, endpoint, query));
      }
      return;
    }

    // A failure stands for its link and probe answer until a query asks
    // again.
    if (session.resolving || (session.failed && session.waiting.isEmpty)) {
      return;
    }
    unawaited(_resolve(session, link, profile));
  }

  Future<void> _resolve(
    _Session session,
    SshLink link,
    HostProfile profile,
  ) async {
    session
      ..resolving = true
      ..failed = false;
    final epoch = session.epoch;
    _state(session, DockerEndpointPhase.resolving);

    final outcome = await _connect(link, profile);
    if (epoch != session.epoch ||
        !identical(_sessions[session.serverId], session)) {
      if (outcome case _Ready(:final endpoint)) {
        _track(endpoint.closeConnections());
      }
      return;
    }

    session.resolving = false;
    switch (outcome) {
      case _Ready(:final endpoint):
        session.endpoint = endpoint;
        _state(
          session,
          DockerEndpointPhase.ready,
          route: endpoint.route,
          negotiatedApi: endpoint.api,
        );
        _idleCheck(session, endpoint);
        _pump(session);
      case _Failed(:final failure, :final route, :final noRouteReason):
        session.failed = true;
        _answerWaiting(session, DockerQueryFailure.endpointUnavailable);
        _state(
          session,
          DockerEndpointPhase.failed,
          route: route,
          failure: failure,
          noRouteReason: noRouteReason,
        );
    }
  }

  /// Finds a route and negotiates over it (03 §5.8, §5.9). A route the
  /// engine does not answer on is passed over and the ladder runs again;
  /// each pass excludes one more route, so the loop ends.
  Future<_Outcome> _connect(SshLink link, HostProfile profile) async {
    final excluded = <DockerRoute>{};
    while (true) {
      final DockerRouteResult found;
      try {
        found = await DockerLadder.resolve(link, profile, excluding: excluded);
      } on Object {
        // A link failure other than a forwarding refusal (D04). Anything
        // else thrown here would leave the session resolving for good.
        return const _Failed(DockerEndpointFailure.linkError);
      }

      final DockerRoute route;
      switch (found) {
        case DockerRouteNone(:final reason):
          return excluded.isEmpty
              ? _Failed(DockerEndpointFailure.noRoute, noRouteReason: reason)
              : const _Failed(DockerEndpointFailure.unreachable);
        case final DockerRoute r:
          route = r;
      }

      final http = _pool(link, route);
      final PingInfo ping;
      final DockerServerVersion version;
      try {
        final probe = DockerClient(http, apiVersion: clientMaxTestedApiVersion);
        ping = await probe.ping(timeout: _answerTimeout);
        version = await probe.version(timeout: _answerTimeout);
      } on DockerException {
        _track(http.close());
        excluded.add(route);
        continue;
      }

      // M13: the API is the runtime's truth, so a Podman behind a Docker
      // path is named Podman.
      final endpointRoute = DockerEndpointRoute(
        rank: route.rank,
        socketPath: route.socketPath,
        rootEquivalence: route.rootEquivalence,
        runtime: ping.isPodman || version.isPodman
            ? EngineRuntime.podman
            : EngineRuntime.docker,
        mode: route.mode,
      );
      try {
        final negotiation = negotiateApiVersion(
          serverMax: version.apiVersion ?? ping.apiVersion,
          serverMin: version.minApiVersion,
          isPodman: ping.isPodman || version.isPodman,
        );
        return _Ready(
          _Endpoint(
            () => _pool(link, route),
            http,
            route: endpointRoute,
            version: version,
            api: negotiation.negotiated,
          ),
        );
      } on NegotiationRefusedException catch (e) {
        _track(http.close());
        return _Failed(switch (e.reason) {
          NegotiationRefusal.serverVersionUnknown =>
            DockerEndpointFailure.apiVersionUnknown,
          NegotiationRefusal.belowClientFloor =>
            DockerEndpointFailure.belowClientFloor,
          NegotiationRefusal.belowServerMinimum =>
            DockerEndpointFailure.belowServerMinimum,
        }, route: endpointRoute);
      }
    }
  }

  /// An HTTP pool over [route]. M9: on a relay each connection is a
  /// session channel, so the short-action share's size bounds the pool
  /// until low-session mode (D09) accounts for them; streamlocal costs no
  /// session, and gets 03 §5.2's 16.
  static DockerHttpClient _pool(SshLink link, DockerRoute route) =>
      DockerHttpClient(
        () => openDockerDuplex(link, route),
        maxConnections: route.rank == DockerRank.streamlocal
            ? defaultMaxConnections
            : ChannelShare.shortAction.limit,
      );

  /// Runs [query] over [endpoint] and answers it. A connection that
  /// drops, or answers no HTTP, drops the endpoint, which resolves again;
  /// a query that fails because its endpoint was let go meanwhile is
  /// answered as cancelled.
  Future<void> _run(
    _Session session,
    _Endpoint endpoint,
    DockerQuery query,
  ) async {
    session.idle?.cancel();
    session.idle = null;
    endpoint.inFlight++;
    final (:payload, :warnings, :routeDropped) = await _read(
      endpoint,
      query.query,
    );
    endpoint.inFlight--;

    final current = identical(session.endpoint, endpoint);
    _emit(
      DockerResult(
        serverId: query.serverId,
        queryId: query.queryId,
        payload: switch (payload) {
          DockerQueryFailed() when !current => const DockerQueryFailed(
            DockerQueryFailure.cancelled,
          ),
          _ => payload,
        },
        warnings: warnings,
      ),
    );
    if (!current) return;

    if (routeDropped) {
      _drop(session);
      _pump(session);
      return;
    }
    _idleCheck(session, endpoint);
  }

  Future<_Read> _read(_Endpoint endpoint, DockerQuerySpec spec) async {
    final client = endpoint.client;
    _Read read(DockerPayload payload, List<String> warnings) =>
        (payload: payload, warnings: warnings, routeDropped: false);
    _Read failed(
      DockerQueryFailure failure,
      String? detail, {
      bool routeDropped = false,
    }) => (
      payload: DockerQueryFailed(failure, detail: detail),
      warnings: const <String>[],
      routeDropped: routeDropped,
    );

    try {
      switch (spec) {
        case DockerEngineQuery():
          final info = await client.engineInfo();
          return read(
            DockerEnginePayload(info.value, endpoint.version),
            info.warnings,
          );
        case DockerContainersQuery():
          final list = await client.listContainers();
          return read(
            DockerContainersPayload(withoutCommands(list.value)),
            list.warnings,
          );
        case DockerContainerQuery(:final containerId):
          final inspect = await client.inspectContainer(containerId);
          return read(
            DockerContainerPayload(maskContainerInspect(inspect.value)),
            inspect.warnings,
          );
        case DockerImagesQuery():
          final images = await client.listImages();
          return read(DockerImagesPayload(images.value), images.warnings);
      }
    } on DockerNotFoundException catch (e) {
      return failed(DockerQueryFailure.notFound, e.daemonMessage);
    } on DockerApiException catch (e) {
      return failed(
        DockerQueryFailure.daemonError,
        e.daemonMessage ?? 'HTTP ${e.statusCode}',
      );
    } on DockerException catch (e) {
      // A channel or relay that went answers no more: a relay's exit
      // reads as a response that never came.
      final dropped =
          e is DockerTransportException || e is DockerProtocolException;
      return failed(
        DockerQueryFailure.connectionFailed,
        '${e.cause ?? e.message}',
        routeDropped: dropped,
      );
    }
  }

  /// Closes a relay's idle connections after [_relayIdle] without a
  /// query; the next query opens one again, without negotiating.
  void _idleCheck(_Session session, _Endpoint endpoint) {
    if (endpoint.route.rank == DockerRank.streamlocal) return;
    if (endpoint.inFlight > 0) return;
    session.idle?.cancel();
    session.idle = _startTimer(_relayIdle, () {
      session.idle = null;
      if (identical(session.endpoint, endpoint) && endpoint.inFlight == 0) {
        _track(endpoint.closeConnections());
      }
    });
  }

  /// Lets [session]'s endpoint go, and any resolution under way. A
  /// failure belongs to the link and probe answer it was found with.
  void _drop(_Session session) {
    session
      ..epoch += 1
      ..resolving = false
      ..failed = false;
    session.idle?.cancel();
    session.idle = null;
    if (session.endpoint case final endpoint?) {
      session.endpoint = null;
      _track(endpoint.closeConnections());
    }
  }

  void _end(_Session session) {
    _drop(session);
    _answerWaiting(session, DockerQueryFailure.cancelled);
    _state(session, DockerEndpointPhase.waiting);
  }

  void _track(Future<void> closing) {
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));
  }

  // -- events ---------------------------------------------------------

  void _answer(DockerQuery query, DockerQueryFailure failure) => _emit(
    DockerResult(
      serverId: query.serverId,
      queryId: query.queryId,
      payload: DockerQueryFailed(failure),
    ),
  );

  void _answerWaiting(_Session session, DockerQueryFailure failure) {
    final queries = session.waiting.toList();
    session.waiting.clear();
    for (final query in queries) {
      _answer(query, failure);
    }
  }

  /// Sends [session]'s state; waiting goes out once, since nothing in it
  /// changes.
  void _state(
    _Session session,
    DockerEndpointPhase phase, {
    DockerEndpointRoute? route,
    ApiVersion? negotiatedApi,
    DockerEndpointFailure? failure,
    DockerNoRouteReason? noRouteReason,
  }) {
    if (phase == DockerEndpointPhase.waiting &&
        session.phase == DockerEndpointPhase.waiting) {
      return;
    }
    session.phase = phase;
    _emit(
      DockerEndpointState(
        serverId: session.serverId,
        phase: phase,
        route: route,
        negotiatedApi: negotiatedApi,
        failure: failure,
        noRouteReason: noRouteReason,
      ),
    );
  }

  /// What the ladder reads of a profile: the sockets, the relays' tools
  /// and sudo.
  static String _ladderInputs(HostProfile profile) => [
    profile.areaStatuses['sockets'],
    for (final socket in profile.engineSockets)
      '${socket.path} ${socket.exists}',
    for (final tool in const ['docker', 'podman', 'socat'])
      '$tool ${profile.toolPresent(tool)}',
    profile.sudoKind,
  ].join('\n');
}

/// One server's endpoint and the queries waiting for it.
final class _Session {
  _Session(this.serverId);

  final String serverId;

  /// Queries waiting for the endpoint, oldest first.
  final List<DockerQuery> waiting = [];

  /// The link [endpoint] and any resolution under way belong to.
  SshLink? link;

  /// Bumped whenever the endpoint is let go, so a resolution that
  /// finishes after it knows to discard its result.
  int epoch = 0;
  bool resolving = false;

  /// Whether the last resolution on this link and probe answer failed.
  bool failed = false;
  _Endpoint? endpoint;

  /// The phase last sent; null before any.
  DockerEndpointPhase? phase;
  Timer? idle;
}

/// A negotiated route, with the HTTP pool over it.
final class _Endpoint {
  _Endpoint(
    this._openPool,
    this._pool, {
    required this.route,
    required this.version,
    required this.api,
  });

  final DockerHttpClient Function() _openPool;
  DockerHttpClient? _pool;
  final DockerEndpointRoute route;

  /// The `/version` the engine answered while negotiating, for DKE-01.
  final DockerServerVersion version;

  /// The negotiated version every path uses.
  final ApiVersion api;
  int inFlight = 0;

  /// The client at [api], over a pool opened again after an idle close.
  DockerClient get client =>
      DockerClient(_pool ??= _openPool(), apiVersion: api);

  /// Closes the pooled connections; the endpoint stays usable.
  Future<void> closeConnections() async {
    final pool = _pool;
    _pool = null;
    await pool?.close();
  }
}

/// What a query read, and whether its connection dropped, so the
/// session resolves the endpoint again.
typedef _Read = ({
  DockerPayload payload,
  List<String> warnings,
  bool routeDropped,
});

/// What [DockerRouter._connect] found.
sealed class _Outcome {
  const _Outcome();
}

final class _Ready extends _Outcome {
  const _Ready(this.endpoint);

  final _Endpoint endpoint;
}

/// A failure, with the route it was found on when there was one.
final class _Failed extends _Outcome {
  const _Failed(this.failure, {this.route, this.noRouteReason});

  final DockerEndpointFailure failure;
  final DockerEndpointRoute? route;
  final DockerNoRouteReason? noRouteReason;
}
