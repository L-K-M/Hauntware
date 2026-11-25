part of 'docker_router.dart';

/// An HTTP pool over [route], each connection made by [open]. Streamlocal
/// costs no session and gets 03 §5.2's 16 connections. On a relay, the
/// sudo relay included, each connection is a session channel (M9): the
/// pool holds [_relayPoolConnections], each taking a short-action slot
/// of [quota] while open, so the idle close gives it back.
DockerHttpClient _pool(
  ChannelQuota quota,
  SshLink link,
  DockerRoute route,
  Future<ByteDuplex> Function(DockerRoute route) open,
) => route.rank == DockerRank.streamlocal
    ? DockerHttpClient(() => open(route), maxConnections: defaultMaxConnections)
    : DockerHttpClient(
        () => _relayConnection(quota, link, route, open),
        maxConnections: _relayPoolConnections,
      );

/// A relay connection by [open] once a short-action slot of [quota] is
/// free; the slot goes back when it closes.
Future<ByteDuplex> _relayConnection(
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

  /// Runs a short command over that link, as the stack checks do.
  late final StackCommandRunner hostRun;

  /// The server's update checks, kept by the router across endpoints.
  late final ImageUpdateCache imageUpdates;

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
  Future<T> use<T>(Future<T> Function(DockerClient client) read) =>
      _router._counted(_session, _endpoint, () => read(_endpoint.client));

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
