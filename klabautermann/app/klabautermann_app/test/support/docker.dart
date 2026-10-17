import 'package:klabautermann_core/klabautermann_core.dart';

/// [serverId]'s endpoint ready over [rank] (03 §5.9), as the engine
/// reports it: a rootful Docker at its default path unless told
/// otherwise.
DockerEndpointState dockerReady(
  String serverId, {
  DockerRank rank = DockerRank.streamlocal,
  DockerRootEquivalence rootEquivalence = DockerRootEquivalence.rootfulSocket,
  EngineRuntime runtime = EngineRuntime.docker,
  EngineMode? mode = EngineMode.rootful,
  String socketPath = '/var/run/docker.sock',
  ApiVersion api = const ApiVersion(1, 47),
  bool lowSession = false,
}) => DockerEndpointState(
  serverId: serverId,
  phase: DockerEndpointPhase.ready,
  route: DockerEndpointRoute(
    rank: rank,
    socketPath: socketPath,
    runtime: runtime,
    rootEquivalence: rootEquivalence,
    mode: mode,
  ),
  negotiatedApi: api,
  lowSession: lowSession,
);

/// [serverId]'s endpoint failed with no route, for [reason].
DockerEndpointState dockerNoRoute(
  String serverId,
  DockerNoRouteReason reason,
) => DockerEndpointState(
  serverId: serverId,
  phase: DockerEndpointPhase.failed,
  failure: DockerEndpointFailure.noRoute,
  noRouteReason: reason,
);

/// The engine's answer to [query].
DockerResult dockerAnswer(DockerQuery query, DockerPayload payload) =>
    DockerResult(
      serverId: query.serverId,
      queryId: query.queryId,
      payload: payload,
    );

/// A Docker 27 engine on Ubuntu, as `/info` and `/version` describe it
/// (DKE-01).
DockerEnginePayload dockerEngine() => const DockerEnginePayload(
  EngineInfo(
    name: 'web-1',
    serverVersion: '27.3.1',
    operatingSystem: 'Ubuntu 24.04.1 LTS',
    architecture: 'x86_64',
  ),
  DockerServerVersion(
    apiVersion: ApiVersion(1, 47),
    minApiVersion: ApiVersion(1, 24),
    version: '27.3.1',
    os: 'linux',
    arch: 'amd64',
    platformName: 'Docker Engine - Community',
  ),
);
