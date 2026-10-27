// DKE-06's security review and DKE-07's log rotation lint over one
// container.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ContainerConfig, ContainerInspect;
import 'package:klabautermann_core/src/docker/container_review.dart';
import 'package:test/test.dart';

const _summary = ContainerSummary(id: 'c1', names: ['/app']);

/// A container that carries no finding: a pinned image, a user, a health
/// check, a restart policy and rotated logs.
const _clean = ContainerInspect(
  id: 'c1',
  config: ContainerConfig(
    image: 'nginx:1.27',
    user: 'nginx',
    healthcheck: ['CMD', 'true'],
  ),
  hostConfig: ContainerHostConfig(
    restartPolicy: ContainerRestartPolicy(name: 'always'),
    logConfig: LogConfig(type: 'json-file', config: {'max-size': '10m'}),
  ),
);

List<ContainerRisk> _risks(
  ContainerInspect inspect, {
  ContainerSummary summary = _summary,
  bool userMapped = false,
}) => [
  for (final finding in reviewContainer(
    summary,
    inspect,
    userMapped: userMapped,
  ))
    finding.risk,
];

ContainerInspect _with({
  ContainerConfig? config,
  ContainerHostConfig? hostConfig,
  List<ContainerMount> mounts = const [],
}) => ContainerInspect(
  id: 'c1',
  config: config ?? _clean.config,
  hostConfig: hostConfig ?? _clean.hostConfig,
  mounts: mounts,
);

void main() {
  test('a container configured with care carries no finding', () {
    expect(_risks(_clean), isEmpty);
  });

  test('every risk at once comes most severe first, with what it names', () {
    final findings = reviewContainer(
      const ContainerSummary(
        id: 'c1',
        names: ['/app'],
        ports: [
          ContainerPort(
            ip: '::',
            privatePort: 6379,
            publicPort: 6380,
            type: 'tcp',
          ),
        ],
      ),
      const ContainerInspect(
        id: 'c1',
        config: ContainerConfig(image: 'redis'),
        hostConfig: ContainerHostConfig(
          privileged: true,
          networkMode: 'host',
          pidMode: 'host',
          capAdd: ['NET_ADMIN', 'SYS_TIME'],
          logConfig: LogConfig(type: 'json-file'),
        ),
        mounts: [
          ContainerMount(
            type: 'bind',
            source: '/var/run/docker.sock',
            destination: '/var/run/docker.sock',
          ),
        ],
      ),
      userMapped: false,
    );
    expect(findings, const [
      ContainerFinding(ContainerRisk.privileged),
      ContainerFinding(
        ContainerRisk.socketMount,
        detail: '/var/run/docker.sock',
      ),
      ContainerFinding(ContainerRisk.hostNetwork),
      ContainerFinding(ContainerRisk.hostPid),
      ContainerFinding(
        ContainerRisk.addedCapabilities,
        detail: 'NET_ADMIN, SYS_TIME',
      ),
      ContainerFinding(
        ContainerRisk.databasePublished,
        detail: ':::6380->6379/tcp',
      ),
      ContainerFinding(ContainerRisk.rootUser),
      ContainerFinding(ContainerRisk.logsUnrotated),
      ContainerFinding(ContainerRisk.latestTag, detail: 'redis'),
      ContainerFinding(ContainerRisk.noHealthcheck),
      ContainerFinding(ContainerRisk.noRestartPolicy),
    ]);
    expect({
      for (final finding in findings) finding.risk.level,
    }, ContainerRiskLevel.values.toSet());
  });

  test('root is read from the user, with a group or by uid, and an engine '
      'that maps users leaves it out', () {
    for (final user in ['', 'root', '0', '0:0', 'root:staff']) {
      expect(
        _risks(
          _with(
            config: ContainerConfig(user: user, image: 'a:1'),
          ),
        ),
        contains(ContainerRisk.rootUser),
        reason: user,
      );
    }
    for (final user in ['1000', 'app', '1000:0', 'rooted']) {
      expect(
        _risks(
          _with(
            config: ContainerConfig(user: user, image: 'a:1'),
          ),
        ),
        isNot(contains(ContainerRisk.rootUser)),
        reason: user,
      );
    }
    expect(
      _risks(
        _with(config: const ContainerConfig(image: 'a:1')),
        userMapped: true,
      ),
      isNot(contains(ContainerRisk.rootUser)),
    );
  });

  test('a tag floats without one or as latest; a digest, an image id or a '
      'registry port with a tag pins it', () {
    String? floating(String image) {
      final findings = reviewContainer(
        _summary,
        _with(
          config: ContainerConfig(
            image: image,
            user: 'app',
            healthcheck: const ['CMD', 'true'],
          ),
        ),
        userMapped: false,
      );
      return findings
          .where((f) => f.risk == ContainerRisk.latestTag)
          .firstOrNull
          ?.detail;
    }

    expect(floating('nginx'), 'nginx');
    expect(floating('nginx:latest'), 'nginx:latest');
    expect(floating('registry:5000/team/app'), 'registry:5000/team/app');
    expect(floating('registry:5000/team/app:2.1'), isNull);
    expect(floating('nginx@sha256:${'a' * 64}'), isNull);
    expect(floating('sha256:${'b' * 64}'), isNull);
    expect(floating('0123456789ab'), isNull);
  });

  test('only a database port on every address is flagged', () {
    List<ContainerRisk> published(ContainerPort port) => _risks(
      _clean,
      summary: ContainerSummary(id: 'c1', names: const ['/app'], ports: [port]),
    );

    expect(
      published(
        const ContainerPort(ip: '0.0.0.0', privatePort: 5432, publicPort: 1),
      ),
      [ContainerRisk.databasePublished],
    );
    expect(
      published(
        const ContainerPort(ip: '127.0.0.1', privatePort: 5432, publicPort: 1),
      ),
      isEmpty,
    );
    expect(published(const ContainerPort(privatePort: 5432)), isEmpty);
    expect(
      published(
        const ContainerPort(ip: '0.0.0.0', privatePort: 8080, publicPort: 1),
      ),
      isEmpty,
    );
  });

  test('logs rotate under a max-size or another driver; a health check '
      'turned off counts as none', () {
    expect(
      _risks(
        _with(
          hostConfig: const ContainerHostConfig(
            restartPolicy: ContainerRestartPolicy(name: 'always'),
            logConfig: LogConfig(type: 'local'),
          ),
        ),
      ),
      isEmpty,
    );
    expect(
      _risks(
        _with(
          config: const ContainerConfig(
            image: 'a:1',
            user: 'app',
            healthcheck: ['NONE'],
          ),
        ),
      ),
      [ContainerRisk.noHealthcheck],
    );
  });

  test(
    'a socket is named by its file or a folder that holds it; a volume named like one is not',
    () {
      List<ContainerRisk> mounted(ContainerMount mount) =>
          _risks(_with(mounts: [mount]));

      expect(
        mounted(
          const ContainerMount(
            type: 'bind',
            source: '/run/user/1000/podman/podman.sock',
          ),
        ),
        [ContainerRisk.socketMount],
      );
      for (final folder in ['/', '/run', '/var/run', '/run/', '/var/run//']) {
        expect(mounted(ContainerMount(type: 'bind', source: folder)), [
          ContainerRisk.socketMount,
        ], reason: '$folder holds the sockets');
      }
      expect(
        mounted(const ContainerMount(type: 'bind', source: '/run/lock')),
        isEmpty,
      );
      expect(
        mounted(const ContainerMount(type: 'volume', source: 'docker.sock')),
        isEmpty,
      );
      expect(
        mounted(
          const ContainerMount(type: 'bind', source: '/srv/docker.socks'),
        ),
        isEmpty,
      );
    },
  );

  test('no restart policy is fine when the container goes when it stops or '
      'is a compose one-off run', () {
    const none = ContainerHostConfig(
      restartPolicy: ContainerRestartPolicy(name: 'no'),
      logConfig: LogConfig(type: 'local'),
    );
    expect(_risks(_with(hostConfig: none)), [ContainerRisk.noRestartPolicy]);
    expect(
      _risks(
        _with(
          hostConfig: const ContainerHostConfig(
            autoRemove: true,
            logConfig: LogConfig(type: 'local'),
          ),
        ),
      ),
      isEmpty,
    );
    expect(
      _risks(
        _with(hostConfig: none),
        summary: ContainerSummary(
          id: 'c1',
          names: const ['/app'],
          labels: {
            'com.docker.compose.project': MaskedValue.plain('shop'),
            'com.docker.compose.oneoff': MaskedValue.plain('True'),
          },
        ),
      ),
      isEmpty,
    );
  });

  test('other tools are known by their image, agents too (DKE-17)', () {
    HostTool? tool(String image) =>
        hostToolOf(ContainerSummary(id: 'c1', names: const [], image: image));

    expect(tool('portainer/portainer-ce:2.21.4'), HostTool.portainer);
    expect(tool('portainer/agent:2.21.4'), HostTool.portainer);
    expect(tool('amir20/dozzle:latest'), HostTool.dozzle);
    expect(tool('ghcr.io/henrygd/beszel/beszel-agent'), HostTool.beszel);
    expect(tool('louislam/uptime-kuma:1'), HostTool.uptimeKuma);
    expect(tool('louislam/dockge:1'), HostTool.dockge);
    expect(tool('netdata/netdata@sha256:${'a' * 64}'), HostTool.netdata);
    expect(tool('getwud/wud:8'), HostTool.wud);
    expect(tool('fmartinou/whats-up-docker'), HostTool.wud);
    expect(tool('registry:5000/team/dockhand:1.0'), HostTool.dockhand);
    expect(tool('jenkins/agent'), isNull);
    expect(tool('myportainer/agent'), isNull);
    expect(tool('registry.example.com/portainer/agent:2'), HostTool.portainer);
    expect(tool('nginx:1.27'), isNull);
    expect(tool(''), isNull);
  });
}
