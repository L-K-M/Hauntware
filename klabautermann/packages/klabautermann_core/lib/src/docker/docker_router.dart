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
///   failed unreachable or on a link error while a watch holds ─▶
///     resolving again after 5 s, 10 s, ... 2 min
///   Disconnect, fleet removal, endpoint change (SYN-08) ─▶ session ends
/// ```
///
/// A [DockerWatch] opens the session as a query does, and its
/// [DockerWatcher] reads over the endpoint while it is ready. So does an
/// [OpenLogStream] of a [ContainerLogSource], whose [ContainerLogReader]
/// waits for the endpoint, pauses while it drops and resumes over the
/// next one, and ends with the session or a failed endpoint.
///
/// Each ready endpoint has its [StackSources]: the stacks list a watch
/// gets carries their verdicts, and a [DockerStackFileQuery] reads a
/// verified stack's file. Their commands take short-action slots of the
/// server's quota on every rank, since each is an exec channel.
///
/// That quota is the one the host log reads count against (M9,
/// [ChannelQuotas]). On relay ranks every Docker connection is a session
/// channel and takes a slot of it: the pooled connection a short
/// action's, while open; the events stream and each container log
/// follow a follower's, and a window a short action's. Streamlocal costs
/// no session. A learned session limit is 03 §5.2's low-session mode,
/// which [DockerEndpointState.lowSession] names: on a relay the events
/// stream gives way to re-lists every 15 s, the follows share one slot
/// with the host's, and stats are read one at a time on every rank. A
/// new link, which has learned nothing, ends it.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show EngineRuntime, HostProfile;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandResult, SshLink, SshLinkClosed;

import '../admin/admin_mode.dart' show AdminSession;
import '../engine/protocol.dart';
import '../links/channel_quota.dart';
import '../logs/log_stream_router.dart' show kLogStreamsPerServerMax;
import 'container_logs.dart';
import 'docker_ladder.dart';
import 'docker_watch.dart';
import 'inspect_masking.dart';
import 'stack_sources.dart';

/// The most queries one server holds while its endpoint resolves [E]: a
/// Docker view asks a few at once, and more means the app is stuck.
const kDockerQueriesWaitingMax = 32;

/// How long `_ping` and `/version` may take over a route before the
/// session tries the next one [E].
const _answerTimeout = Duration(seconds: 10);

/// How long a relay's pooled connection stays open without a query
/// (M9 [E]): it holds a session channel.
const _relayIdle = Duration(seconds: 30);

/// Why [DockerRouter.useEndpoint] had no endpoint to run on.
final class DockerEndpointUnavailable implements Exception {
  const DockerEndpointUnavailable(this.failure);

  final DockerQueryFailure failure;

  @override
  String toString() => 'DockerEndpointUnavailable(${failure.name})';
}

/// The pooled connections a relay holds (03 §5.2's one keep-alive duplex
/// for short calls). A stack file read lists over the pool and then
/// waits for a short-action slot for its checks, so a pool that could
/// hold both slots could leave every such read waiting on another.
const _relayPoolConnections = 1;

/// The first wait before a failed endpoint is looked for again while a
/// watch holds, doubling up to the cap [E].
const _retryBase = Duration(seconds: 5);
const _retryCap = Duration(minutes: 2);

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

/// Owned by the engine isolate, which hands it the Docker queries,
/// watches and container log streams and tells it what changed: [update]
/// after a server's [LinkState], [probed] for each probe answer,
/// [disconnect], [forget] for servers that left the fleet or changed
/// endpoint, [retain] for the fleet and [close].
final class DockerRouter {
  /// [linkFor] gives a server's ready link, null while it has none.
  /// [quotas] holds each server's channel slots, shared with the log
  /// router (M9); without it the router counts alone. [startTimer] arms
  /// the relays' idle close, the retries and the watches' timers, and
  /// [now] dates the lists; [elapsed], a monotonic clock, paces the log
  /// batches. Tests pass a fake clock.
  DockerRouter({
    required this._linkFor,
    required this._emit,
    this._adminFor,
    ChannelQuotas? quotas,
    this._startTimer = Timer.new,
    this._now = DateTime.now,
    Duration Function()? elapsed,
  }) : _quotas = quotas ?? ChannelQuotas(),
       _elapsed = elapsed ?? _monotonicClock() {
    // A slot another consumer gave back may let a waiting log stream run.
    _quotas.onFreed((serverId) {
      if (_sessions[serverId] case final session?) _serveLogs(session);
    });
  }

  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;

  /// Each server's admin session, whose elevation the sudo relay (rank 3)
  /// runs through; absent in an engine without admin mode.
  final AdminSession? Function(String serverId)? _adminFor;
  final ChannelQuotas _quotas;
  final Timer Function(Duration duration, void Function() callback) _startTimer;
  final DateTime Function() _now;
  final Duration Function() _elapsed;

  final Map<String, _Session> _sessions = {};
  final Map<String, HostProfile> _profiles = {};

  /// The session of each open container log stream, by stream id.
  final Map<String, _Session> _logOwners = {};
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
    if (!_valid(request.query)) {
      return _answer(request, DockerQueryFailure.invalidQuery);
    }

    final session = _session(request.serverId);
    if (session.waiting.length >= kDockerQueriesWaitingMax) {
      return _answer(request, DockerQueryFailure.tooManyQueries);
    }
    session.waiting.add(request);
    _pump(session);
  }

  /// Runs [body] with [serverId]'s client and route once its endpoint is
  /// ready, as a query would run (M4 E15: the Docker planners and the
  /// runner's API steps). Throws [DockerEndpointUnavailable] when the
  /// endpoint cannot be reached; a connection that drops under [body]
  /// drops the endpoint, as a query's does, and the error propagates.
  Future<T> useEndpoint<T>(
    String serverId,
    Future<T> Function(DockerClient client, DockerEndpointRoute route) body,
  ) => _use(serverId, (endpoint) => body(endpoint.client, endpoint.route));

  /// [useEndpoint] with the endpoint's [StackSources] too (M4 E18: the
  /// redeploy planner and its re-validation).
  Future<T> useStacks<T>(
    String serverId,
    Future<T> Function(
      DockerClient client,
      DockerEndpointRoute route,
      StackSources stacks,
    )
    body,
  ) => _use(
    serverId,
    (endpoint) => body(endpoint.client, endpoint.route, endpoint.stacks),
  );

  Future<T> _use<T>(
    String serverId,
    Future<T> Function(_Endpoint endpoint) body,
  ) async {
    if (!_fleet.contains(serverId)) {
      throw const DockerEndpointUnavailable(DockerQueryFailure.notInFleet);
    }
    final session = _session(serverId);
    final ready = Completer<_Endpoint>();
    session.users.add(ready);
    _pump(session);
    final endpoint = await ready.future;

    session.idle?.cancel();
    session.idle = null;
    endpoint.inFlight++;
    try {
      return await body(endpoint);
    } on DockerException catch (e) {
      if ((e is DockerTransportException || e is DockerProtocolException) &&
          identical(session.endpoint, endpoint)) {
        _drop(session);
        _pump(session);
      }
      rethrow;
    } finally {
      endpoint.inFlight--;
      if (identical(session.endpoint, endpoint)) _idleCheck(session, endpoint);
    }
  }

  /// Takes [request], replacing the server's watch with its id. A new
  /// watch looks for a failed endpoint again, as a query does.
  void watch(DockerWatch request) {
    final serverId = request.serverId;
    final refusal = switch (request) {
      _ when !_fleet.contains(serverId) => DockerQueryFailure.notInFleet,
      DockerWatch(:final statsFor) when statsFor.length > kDockerStatsForMax =>
        DockerQueryFailure.invalidQuery,
      _ => null,
    };
    final session = _sessions[serverId];
    final before = session?.watches[request.watchId];
    if (refusal != null ||
        (before == null &&
            (session?.watches.length ?? 0) >= kDockerWatchesMax)) {
      for (final list in request.lists) {
        _emit(
          DockerListChanged(
            serverId: serverId,
            list: list,
            payload: DockerQueryFailed(
              refusal ?? DockerQueryFailure.tooManyQueries,
            ),
            at: _now(),
          ),
        );
      }
      return;
    }

    final opened = _session(serverId);
    opened.watches[request.watchId] = request;
    final watcher = opened.watcher ??= DockerWatcher(
      serverId: serverId,
      emit: _emit,
      dropped: () => _routeDropped(opened),
      now: _now,
      startTimer: _startTimer,
    );
    watcher.watch(
      opened.watches.values,
      asked: request.lists.difference(before?.lists ?? const {}),
    );
    if (before == null) {
      opened
        ..failed = false
        ..retries = 0;
    }
    _pump(opened);
  }

  /// Ends the watch [request] names; the last one stops the server's
  /// events stream and stats.
  void unwatch(DockerUnwatch request) {
    final session = _sessions[request.serverId];
    if (session?.watches.remove(request.watchId) == null) return;
    final watcher = session!.watcher!;
    if (session.watches.isNotEmpty) {
      return watcher.watch(session.watches.values);
    }
    session.watcher = null;
    session.target = null;
    session.retry?.cancel();
    session.retry = null;
    _track(watcher.close());
  }

  /// Accepts [request], an open of a container's logs, and returns null,
  /// having sent the stream's first [LogStreamState], or returns why the
  /// engine rejects it: a server outside the fleet, or one holding
  /// [kLogStreamsPerServerMax] container log streams, a count of their
  /// own beside the log router's host streams. The log router
  /// refuses a reused id first. A new stream looks for a failed endpoint
  /// again, as a watch does.
  String? openLogs(OpenLogStream request) {
    final OpenLogStream(:streamId, :spec) = request;
    final serverId = spec.serverId;
    if (!_fleet.contains(serverId)) return 'no fleet server $serverId';
    if ((_sessions[serverId]?.logs.length ?? 0) >= kLogStreamsPerServerMax) {
      return '$serverId holds $kLogStreamsPerServerMax container log streams';
    }
    if (!ContainerLogReader.accepts(spec)) {
      _emit(
        LogStreamState(
          streamId,
          const LogStreamEnded(LogStreamEndReason.invalid),
        ),
      );
      return null;
    }

    final session = _session(serverId);
    late final _LogStream stream;
    stream = _LogStream(
      spec,
      ContainerLogReader(
        streamId: streamId,
        spec: spec,
        emit: _emit,
        onEnded: () => _logEnded(session, streamId, stream),
        track: _track,
        elapsed: _elapsed,
        startTimer: _startTimer,
      ),
    );
    session.logs[streamId] = stream;
    _logOwners[streamId] = session;
    session.failed = false;
    _pump(session);
    return null;
  }

  /// [CloseStream] for a container log stream: ends it as closed. Does
  /// nothing when no container log stream is open as [streamId].
  void closeLogs(String streamId) => _logOwners[streamId]
      ?.logs[streamId]
      ?.reader
      .end(const LogStreamEnded(LogStreamEndReason.closed));

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

  /// Admin mode turned on or off for [serverId] (plan M7). When it ends,
  /// a sudo relay's connections close and the route is looked for again,
  /// which now passes over rank 3; when it starts, a route that failed
  /// is looked for again, which may now take it.
  void adminChanged(String serverId) {
    final session = _sessions[serverId];
    if (session == null) return;
    final on = _adminFor?.call(serverId) != null;
    if (session.endpoint case final endpoint?) {
      if (on || endpoint.route.rank != DockerRank.sudoRelay) return;
      _drop(session);
      _pump(session);
      return;
    }
    if (on && session.failed) {
      session.failed = false;
      _pump(session);
    }
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

  _Session _session(String serverId) => _sessions.putIfAbsent(
    serverId,
    () => _Session(serverId, _quotas.of(serverId)),
  );

  /// Whether [session]'s link learned a session limit: 03 §5.2's
  /// low-session mode (M9).
  static bool _lowSession(_Session session) =>
      session.link?.seen.learnedSessionLimit != null;

  /// Moves [session] on as far as its link and probe answer allow. A
  /// closed link the supervisor has not reported yet counts as none.
  void _pump(_Session session) {
    var link = _linkFor(session.serverId);
    if (link?.state is SshLinkClosed) link = null;
    if (!identical(link, session.link)) {
      _drop(session);
      session.link = link;
    } else {
      _modeCheck(session);
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
      _serveLogs(session);
      return;
    }

    _serveLogs(session);
    if (session.endpoint case final endpoint?) {
      if (session.watcher case final watcher?) {
        watcher.attach(
          session.target ??= _WatchTarget(this, session, endpoint),
        );
      }
      final queries = session.waiting.toList();
      session.waiting.clear();
      for (final query in queries) {
        unawaited(_run(session, endpoint, query));
      }
      final users = session.users.toList();
      session.users.clear();
      for (final user in users) {
        user.complete(endpoint);
      }
      return;
    }

    // A failure stands for its link and probe answer until a query asks
    // again.
    if (session.resolving ||
        (session.failed && session.waiting.isEmpty && session.users.isEmpty)) {
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
    session.retry?.cancel();
    session.retry = null;
    final epoch = session.epoch;
    _state(session, DockerEndpointPhase.resolving);

    final outcome = await _connect(
      session.serverId,
      session.quota,
      link,
      profile,
    );
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
        endpoint.stacks = StackSources(
          socketPath: endpoint.route.socketPath,
          run: (command, {required timeout, required maxOutputBytes}) =>
              _shortAction(
                session,
                () => link.run(
                  command,
                  timeout: timeout,
                  maxOutputBytes: maxOutputBytes,
                ),
              ),
          openFileSystem: link.openFileSystem,
          admin: () => _adminFor?.call(session.serverId),
        );
        session
          ..endpoint = endpoint
          ..retries = 0;
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
        // The state that explains the failure goes out first, so an app
        // reading it on a failed answer never sees `resolving`.
        _state(
          session,
          DockerEndpointPhase.failed,
          route: route,
          failure: failure,
          noRouteReason: noRouteReason,
        );
        _answerWaiting(session, DockerQueryFailure.endpointUnavailable);
        _endLogs(
          session,
          LogStreamEnded(
            LogStreamEndReason.failed,
            detail: 'no Docker endpoint: ${failure.name}',
          ),
        );
        _retryLater(session, failure);
    }
  }

  /// Looks for [session]'s failed endpoint again while a watch holds
  /// (D06): an engine that did not answer, or a link that failed under
  /// the ladder, may come back without the probe answer changing. Other
  /// failures stand until a query, a new watch or a new probe answer.
  void _retryLater(_Session session, DockerEndpointFailure failure) {
    if (session.watches.isEmpty) return;
    if (failure != DockerEndpointFailure.unreachable &&
        failure != DockerEndpointFailure.linkError) {
      return;
    }

    final delay = _retryBase * math.pow(2, math.min(session.retries, 5));
    session.retries++;
    session.retry = _startTimer(delay < _retryCap ? delay : _retryCap, () {
      session.retry = null;
      if (!identical(_sessions[session.serverId], session) ||
          !session.failed ||
          session.watches.isEmpty) {
        return;
      }
      session.failed = false;
      _pump(session);
    });
  }

  /// Finds a route and negotiates over it (03 §5.8, §5.9). A route the
  /// engine does not answer on is passed over and the ladder runs again;
  /// each pass excludes one more route, so the loop ends.
  Future<_Outcome> _connect(
    String serverId,
    ChannelQuota quota,
    SshLink link,
    HostProfile profile,
  ) async {
    final excluded = <DockerRoute>{};
    // Each connection asks for the session as it opens, so a relay opened
    // after admin mode ended fails rather than elevate.
    Future<ByteDuplex> open(DockerRoute route) =>
        openDockerDuplex(link, route, admin: _adminFor?.call(serverId));
    while (true) {
      final DockerRouteResult found;
      try {
        found = await DockerLadder.resolve(
          link,
          profile,
          excluding: excluded,
          adminMode: _adminFor?.call(serverId) != null,
        );
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

      final http = _pool(quota, link, route, open);
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
            () => _pool(quota, link, route, open),
            () => open(route),
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

  /// An HTTP pool over [route], each connection made by [open]. Streamlocal
  /// costs no session and gets 03 §5.2's 16 connections. On a relay, the
  /// sudo relay included, each connection is a session channel (M9): the
  /// pool holds [_relayPoolConnections], each taking a short-action slot
  /// of [quota] while open, so the idle close gives it back.
  static DockerHttpClient _pool(
    ChannelQuota quota,
    SshLink link,
    DockerRoute route,
    Future<ByteDuplex> Function(DockerRoute route) open,
  ) => route.rank == DockerRank.streamlocal
      ? DockerHttpClient(
          () => open(route),
          maxConnections: defaultMaxConnections,
        )
      : DockerHttpClient(
          () => _relayConnection(quota, link, route, open),
          maxConnections: _relayPoolConnections,
        );

  /// A relay connection by [open] once a short-action slot of [quota] is
  /// free; the slot goes back when it closes.
  static Future<ByteDuplex> _relayConnection(
    ChannelQuota quota,
    SshLink link,
    DockerRoute route,
    Future<ByteDuplex> Function(DockerRoute route) open,
  ) async {
    await quota.acquire(
      ChannelShare.shortAction,
      learnedSessionLimit: () => link.seen.learnedSessionLimit,
    );
    final ByteDuplex duplex;
    try {
      duplex = await open(route);
    } on Object {
      quota.give(ChannelShare.shortAction);
      rethrow;
    }
    return _SlotDuplex(duplex, () => quota.give(ChannelShare.shortAction));
  }

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
        case DockerStackFileQuery(:final project, :final path):
          return read(
            await endpoint.stacks.readFile(client, project, path),
            const [],
          );
      }
    } on DockerException catch (e) {
      final (:failure, :dropped) = dockerReadFailure(e);
      return (
        payload: failure,
        warnings: const <String>[],
        routeDropped: dropped,
      );
    }
  }

  /// Whether [spec] names what it reads in a form the engine takes.
  static bool _valid(DockerQuerySpec spec) => switch (spec) {
    DockerContainerQuery(:final containerId) => containerId.isNotEmpty,
    DockerStackFileQuery(:final project, :final path) =>
      composeNamePattern.hasMatch(project) && _absolute(path),
    _ => true,
  };

  static bool _absolute(String path) {
    try {
      validateAbsolutePath(path);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  /// Runs [action] once a short-action slot of [session]'s quota is
  /// free, and frees it after (M9).
  static Future<RemoteCommandResult> _shortAction(
    _Session session,
    Future<RemoteCommandResult> Function() action,
  ) async {
    await session.quota.acquire(
      ChannelShare.shortAction,
      learnedSessionLimit: () => session.link?.seen.learnedSessionLimit,
    );
    try {
      return await action();
    } finally {
      session.quota.give(ChannelShare.shortAction);
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

  /// A watch's pooled read lost its connection: the endpoint is found
  /// again, as for a query's.
  void _routeDropped(_Session session) {
    if (!identical(_sessions[session.serverId], session)) return;
    _drop(session);
    _pump(session);
  }

  /// Lets [session]'s endpoint go, and any resolution under way. A
  /// failure belongs to the link and probe answer it was found with.
  /// The watches stay, to resume over the next endpoint.
  void _drop(_Session session) {
    session
      ..epoch += 1
      ..resolving = false
      ..failed = false
      ..retries = 0
      ..target = null;
    session.retry?.cancel();
    session.retry = null;
    if (session.watcher case final watcher?) _track(watcher.detach());
    session.idle?.cancel();
    session.idle = null;
    if (session.endpoint case final endpoint?) {
      session.endpoint = null;
      _track(endpoint.closeConnections());
    }
    _pauseLogs(session);
  }

  void _end(_Session session) {
    _drop(session);
    _endLogs(session, const LogStreamEnded(LogStreamEndReason.failed));
    session.watches.clear();
    if (session.watcher case final watcher?) _track(watcher.close());
    session.watcher = null;
    _answerWaiting(session, DockerQueryFailure.cancelled);
    session.link = null;
    _state(session, DockerEndpointPhase.waiting);
  }

  void _track(Future<void> closing) {
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));
  }

  // -- container logs -------------------------------------------------

  /// Runs [session]'s waiting log streams over its ready endpoint, in the
  /// order they opened, or tells each why it waits. On a relay each takes
  /// a slot of its share from the quota the log router's reads take
  /// from (M9); streamlocal costs no session.
  void _serveLogs(_Session session) {
    final endpoint = session.endpoint;
    for (final stream in session.logs.values.toList()) {
      if (stream.running) continue;
      if (endpoint == null) {
        _logStatus(stream, const LogStreamWaiting(LogStreamWaitReason.link));
        continue;
      }
      if (endpoint.route.rank != DockerRank.streamlocal) {
        if (!session.quota.take(
          stream.share,
          learnedSessionLimit: session.link?.seen.learnedSessionLimit,
        )) {
          _logStatus(
            stream,
            const LogStreamWaiting(LogStreamWaitReason.channel),
          );
          continue;
        }
        stream.slot = stream.share;
      }
      stream.running = true;
      _logStatus(
        stream,
        LogStreamRunning(continuity: stream.reader.run(endpoint)),
      );
    }
  }

  /// Stops [session]'s running follows, which resume over the next
  /// endpoint; a window ends as failed, as one on a lost link does.
  void _pauseLogs(_Session session) {
    for (final stream in session.logs.values.toList()) {
      if (!stream.running) continue;
      if (!stream.spec.follow) {
        stream.reader.end(const LogStreamEnded(LogStreamEndReason.failed));
      } else if (stream.reader.pause()) {
        _release(session, stream);
      }
    }
  }

  void _endLogs(_Session session, LogStreamEnded status) {
    for (final stream in session.logs.values.toList()) {
      stream.reader.end(status);
    }
  }

  /// Forgets [stream], which sent its end, and runs what its slot lets.
  void _logEnded(_Session session, String streamId, _LogStream stream) {
    session.logs.remove(streamId);
    _logOwners.remove(streamId);
    _release(session, stream);
    if (identical(_sessions[session.serverId], session)) _serveLogs(session);
  }

  void _release(_Session session, _LogStream stream) {
    stream.running = false;
    if (stream.slot case final share?) session.quota.give(share);
    stream.slot = null;
  }

  /// Sends [status] for [stream] unless it was the last one sent.
  void _logStatus(_LogStream stream, LogStreamStatus status) {
    if (stream.status == status) return;
    stream.status = status;
    _emit(LogStreamState(stream.reader.streamId, status));
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
    final users = session.users.toList();
    session.users.clear();
    for (final user in users) {
      user.completeError(DockerEndpointUnavailable(failure));
    }
  }

  /// Sends [session]'s state; waiting goes out once while the mode
  /// stays, since nothing else in it changes.
  void _state(
    _Session session,
    DockerEndpointPhase phase, {
    DockerEndpointRoute? route,
    ApiVersion? negotiatedApi,
    DockerEndpointFailure? failure,
    DockerNoRouteReason? noRouteReason,
  }) {
    final lowSession = _lowSession(session);
    if (session.sent case DockerEndpointState(
      phase: DockerEndpointPhase.waiting,
      lowSession: final was,
    ) when phase == DockerEndpointPhase.waiting && was == lowSession) {
      return;
    }
    _emit(
      session.sent = DockerEndpointState(
        serverId: session.serverId,
        phase: phase,
        route: route,
        negotiatedApi: negotiatedApi,
        lowSession: lowSession,
        failure: failure,
        noRouteReason: noRouteReason,
      ),
    );
  }

  /// Sends [session]'s state again when its link learned a session limit
  /// since (M9), and has a relay's events stream give way to re-lists.
  void _modeCheck(_Session session) {
    final sent = session.sent;
    final lowSession = _lowSession(session);
    if (sent == null || sent.lowSession == lowSession) return;

    _emit(
      session.sent = DockerEndpointState(
        serverId: sent.serverId,
        phase: sent.phase,
        route: sent.route,
        negotiatedApi: sent.negotiatedApi,
        lowSession: lowSession,
        failure: sent.failure,
        noRouteReason: sent.noRouteReason,
      ),
    );
    if (lowSession && session.endpoint?.route.rank != DockerRank.streamlocal) {
      session.watcher?.yieldStream();
    }
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
  _Session(this.serverId, this.quota);

  final String serverId;

  /// Queries waiting for the endpoint, oldest first.
  final List<DockerQuery> waiting = [];

  /// [DockerRouter.useEndpoint] calls waiting for the endpoint.
  final List<Completer<_Endpoint>> users = [];

  /// The link [endpoint] and any resolution under way belong to.
  SshLink? link;

  /// Bumped whenever the endpoint is let go, so a resolution that
  /// finishes after it knows to discard its result.
  int epoch = 0;
  bool resolving = false;

  /// Whether the last resolution on this link and probe answer failed.
  bool failed = false;
  _Endpoint? endpoint;

  /// The state last sent; null before any.
  DockerEndpointState? sent;
  Timer? idle;

  /// The next look for a failed endpoint while a watch holds, and how
  /// many came since it was last ready.
  Timer? retry;
  int retries = 0;

  /// The watches by id, and what reads for them.
  final Map<String, DockerWatch> watches = {};
  DockerWatcher? watcher;

  /// [endpoint] as [watcher] reads over it.
  DockerWatchTarget? target;

  /// The container log streams by id, in the order they opened.
  final Map<String, _LogStream> logs = {};

  /// The server's slots, shared with the host log reads (M9): those the
  /// relay connections and running log streams hold, and the stack
  /// checks' exec channels on every rank.
  final ChannelQuota quota;
}

/// One container log stream as the session runs it.
final class _LogStream {
  _LogStream(this.spec, this.reader);

  final LogStreamSpec spec;
  final ContainerLogReader reader;
  bool running = false;

  /// The relay slot it holds while running; null on streamlocal.
  ChannelShare? slot;

  /// The last status the router sent; null before any.
  LogStreamStatus? status;

  ChannelShare get share =>
      spec.follow ? ChannelShare.follower : ChannelShare.shortAction;
}

/// A negotiated route, with the HTTP pool over it.
final class _Endpoint implements ContainerLogTarget {
  _Endpoint(
    this._openPool,
    this._openDuplex,
    this._pool, {
    required this.route,
    required this.version,
    required this.api,
  });

  final DockerHttpClient Function() _openPool;
  final DuplexOpener _openDuplex;
  DockerHttpClient? _pool;
  final DockerEndpointRoute route;

  /// The `/version` the engine answered while negotiating, for DKE-01.
  final DockerServerVersion version;

  /// The negotiated version every path uses.
  final ApiVersion api;
  int inFlight = 0;

  /// The stack checks over the link this endpoint was found on.
  late final StackSources stacks;

  /// The client at [api], over a pool opened again after an idle close.
  DockerClient get client =>
      DockerClient(_pool ??= _openPool(), apiVersion: api);

  @override
  bool get podman => route.runtime == EngineRuntime.podman;

  /// Bounded by the head timeout only, as every stream is (03 §5.5).
  @override
  DockerClient openStream() => DockerClient(
    DockerHttpClient(_openDuplex, maxConnections: 1),
    apiVersion: api,
  );

  /// Closes the pooled connections; the endpoint stays usable.
  Future<void> closeConnections() async {
    final pool = _pool;
    _pool = null;
    await pool?.close();
  }
}

/// [_Endpoint] as a watcher reads over it: its pooled reads count as
/// queries for the relays' idle close.
final class _WatchTarget implements DockerWatchTarget {
  _WatchTarget(this._router, this._session, this._endpoint);

  final DockerRouter _router;
  final _Session _session;
  final _Endpoint _endpoint;

  @override
  DockerRank get rank => _endpoint.route.rank;

  @override
  String get socketPath => _endpoint.route.socketPath;

  @override
  Future<T> use<T>(Future<T> Function(DockerClient client) read) async {
    _session.idle?.cancel();
    _session.idle = null;
    _endpoint.inFlight++;
    try {
      return await read(_endpoint.client);
    } finally {
      _endpoint.inFlight--;
      if (identical(_session.endpoint, _endpoint)) {
        _router._idleCheck(_session, _endpoint);
      }
    }
  }

  @override
  bool get lowSession => DockerRouter._lowSession(_session);

  @override
  DockerStreamLease? openEvents() {
    if (rank == DockerRank.streamlocal) {
      return DockerStreamLease(_endpoint.openStream());
    }
    final quota = _session.quota;
    if (lowSession || !quota.take(ChannelShare.follower)) return null;
    return DockerStreamLease(
      _endpoint.openStream(),
      release: () => quota.give(ChannelShare.follower),
    );
  }

  @override
  StackSources get stacks => _endpoint.stacks;
}

/// A relay connection holding a short-action slot, which goes back once
/// it closes from either side (M9).
final class _SlotDuplex implements ByteDuplex {
  _SlotDuplex(this._duplex, this._release) {
    unawaited(
      _duplex.done.then<void>((_) => _free(), onError: (Object _) => _free()),
    );
  }

  final ByteDuplex _duplex;
  void Function()? _release;

  @override
  Stream<List<int>> get stream => _duplex.stream;

  @override
  StreamSink<List<int>> get sink => _duplex.sink;

  @override
  Future<void> get done => _duplex.done;

  @override
  Future<void> closeWrite() => _duplex.closeWrite();

  @override
  Future<void> close() {
    _free();
    return _duplex.close();
  }

  void _free() {
    final release = _release;
    _release = null;
    release?.call();
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
