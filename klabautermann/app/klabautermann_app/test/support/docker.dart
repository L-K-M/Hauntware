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

/// One container as the engine lists it (CTR-01): running unless told
/// otherwise, in the compose [project] when one is given.
ContainerSummary dockerContainer(
  String id, {
  String? name,
  String state = 'running',
  String? status,
  String image = 'nginx:1.27',
  String? project,
  List<ContainerPort> ports = const [],
  HealthStatus? health,
}) => ContainerSummary(
  id: id,
  names: ['/${name ?? id}'],
  image: image,
  state: state,
  status:
      status ?? (state == 'running' ? 'Up 2 hours' : 'Exited (0) 1 day ago'),
  ports: ports,
  health: health,
  labels: {
    if (project != null)
      'com.docker.compose.project': MaskedValue.plain(project),
  },
);

/// [containers] on [serverId], as a container watch delivers them.
DockerListChanged dockerContainerList(
  String serverId,
  List<ContainerSummary> containers, {
  required DateTime at,
  bool fullRelist = false,
}) => DockerListChanged(
  serverId: serverId,
  list: DockerWatchList.containers,
  payload: DockerContainersPayload(containers),
  at: at,
  fullRelist: fullRelist,
);

/// One stats round on [serverId] (CST-01).
DockerListChanged dockerStatsRound(
  String serverId,
  List<ContainerListStats> stats, {
  required DateTime at,
}) => DockerListChanged(
  serverId: serverId,
  list: DockerWatchList.stats,
  payload: DockerStatsPayload(stats),
  at: at,
);

/// A failed read of [list] on [serverId], or a refused watch.
DockerListChanged dockerListFailed(
  String serverId,
  DockerWatchList list,
  DockerQueryFailure failure, {
  required DateTime at,
  String? detail,
}) => DockerListChanged(
  serverId: serverId,
  list: list,
  payload: DockerQueryFailed(failure, detail: detail),
  at: at,
);

/// One image as the engine lists it (IMG-01): tagged [tags], dangling
/// with none, and used by [containers] containers.
ImageSummary dockerImage(
  String id, {
  List<String> tags = const [],
  int containers = 0,
}) => ImageSummary(id: id, repoTags: tags, containers: containers);

/// [images] on [serverId], as a watch of the images delivers them.
DockerListChanged dockerImageList(
  String serverId,
  List<ImageSummary> images, {
  required DateTime at,
}) => DockerListChanged(
  serverId: serverId,
  list: DockerWatchList.images,
  payload: DockerImagesPayload(images),
  at: at,
  fullRelist: true,
);

/// A `/system/df` answer whose images free [images] bytes and volumes
/// [volumes] (OV-05).
DockerSystemDfPayload dockerDiskUse({int images = 0, int volumes = 0}) =>
    DockerSystemDfPayload(
      SystemDf(
        images: DiskUsageTotals(reclaimable: images),
        containers: const DiskUsageTotals(reclaimable: 0),
        volumes: DiskUsageTotals(reclaimable: volumes),
        buildCache: const DiskUsageTotals(reclaimable: 0),
      ),
    );
