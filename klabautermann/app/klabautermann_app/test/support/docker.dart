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

/// [id] inspected as the engine sends it (CTR-03, CTR-04), masked by the
/// engine (03 §8.9): a running compose service with a secret in its
/// environment, a label and its command line, an unhealthy check whose
/// output holds a URL password, a volume and a bind mount, and a network.
/// [labels] add to the compose labels, as an owning manager's would, and
/// [healthLog] replaces the two checks.
/// Times are local, so nothing depends on the test machine's zone; the
/// container never stopped, so its `FinishedAt` is the API's zero time.
ContainerDetails dockerContainerDetails(
  String id, {
  String name = 'web-db',
  String status = 'running',
  int? exitCode,
  bool oomKilled = false,
  Map<String, MaskedValue> labels = const {},
  HealthStatus health = HealthStatus.unhealthy,
  String restartPolicy = 'unless-stopped',
  DateTime? startedAt,
  List<ContainerHealthCheck>? healthLog,
}) => ContainerDetails(
  id: id,
  name: '/$name',
  created: DateTime(2026, 10, 12, 9, 15),
  image:
      'sha256:3f1c9a6b2e8d4c7a5b0e9f8d7c6b5a4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a',
  restartCount: 2,
  path: 'docker-entrypoint.sh',
  args: [
    MaskedValue.plain('postgres'),
    MaskedValue.plain('--password'),
    MaskedValue.secret('hunter2'),
  ],
  state: ContainerDetailsState(
    status: status,
    running: status == 'running',
    exitCode: exitCode,
    oomKilled: oomKilled,
    pid: status == 'running' ? 4242 : null,
    startedAt: startedAt ?? DateTime(2026, 10, 15, 11, 30),
    finishedAt: DateTime.utc(1),
    health: ContainerDetailsHealth(
      status: health,
      failingStreak: health == HealthStatus.unhealthy ? 3 : 0,
      log:
          healthLog ??
          [
            ContainerHealthCheck(
              end: DateTime(2026, 10, 15, 14, 29, 30),
              exitCode: 0,
              output: MaskedValue.plain('accepting connections'),
            ),
            ContainerHealthCheck(
              end: DateTime(2026, 10, 15, 14, 30),
              exitCode: 1,
              output: MaskedValue.redacted(
                'connect postgres://app:********@db:5432 failed',
                'connect postgres://app:s3cret@db:5432 failed',
              ),
            ),
          ],
    ),
  ),
  config: ContainerDetailsConfig(
    image: 'postgres:16',
    env: [
      EnvVar('POSTGRES_USER', MaskedValue.plain('app')),
      EnvVar('POSTGRES_PASSWORD', MaskedValue.secret('hunter2')),
      EnvVar('PGDATA', MaskedValue.plain('/var/lib/postgresql/data')),
    ],
    entrypoint: [MaskedValue.plain('docker-entrypoint.sh')],
    cmd: [
      MaskedValue.plain('postgres'),
      MaskedValue.plain('--password'),
      MaskedValue.secret('hunter2'),
    ],
    labels: {
      'com.docker.compose.project': MaskedValue.plain('web'),
      'com.docker.compose.service': MaskedValue.plain('db'),
      'backup.token': MaskedValue.secret('t0ken'),
      ...labels,
    },
  ),
  hostConfig: ContainerHostConfig(
    networkMode: 'web_default',
    restartPolicy: ContainerRestartPolicy(name: restartPolicy),
    logConfig: const LogConfig(
      type: 'splunk',
      config: {'splunk-token': 'never-shown'},
    ),
  ),
  mounts: const [
    ContainerMount(
      type: 'volume',
      name: 'web_pgdata',
      source: '/var/lib/docker/volumes/web_pgdata/_data',
      destination: '/var/lib/postgresql/data',
      rw: true,
    ),
    ContainerMount(
      type: 'bind',
      source: '/srv/web/init.sql',
      destination: '/docker-entrypoint-initdb.d/init.sql',
      rw: false,
    ),
  ],
  networkSettings: const ContainerNetworkSettings(
    networks: {
      'web_default': ContainerNetwork(
        ipAddress: '172.18.0.3',
        gateway: '172.18.0.1',
        aliases: ['db', 'web-db'],
      ),
    },
  ),
);
