// The fixture's Docker host over a real SshLink (03 §5.4, §11.3; M3 D10):
// rank 1, `direct-streamlocal` to dind's socket through
// `SshLink.openUnixStream`, with klabautermann_docker's HTTP client on
// the duplex. It is the repository's first real `forwardLocalUnix` call
// and spike S1's streamlocal evidence; the refusals, `klab-nosock`'s
// included, are docker_refusal_test.dart's. run.sh starts the fixture
// and seeds the engine (seed_docker.sh); without it these skip.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 2))
library;

import 'package:klabautermann_docker/klabautermann_docker.dart' as docker;
import 'package:seance_core/seance_core.dart' show SshLink;
import 'package:test/test.dart';

import 'support/docker_host.dart';
import 'support/fixture.dart';

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the Docker fixture suite', () {}, skip: fixtureSkipReason);
    return;
  }

  Future<SshLink> connect(String user) =>
      connectDockerHost(fixture, FixtureService.dockerHost, user);

  test('the fixture user pings and negotiates with dind over '
      'streamlocal', () async {
    final link = await connect(fixture.user);
    final http = streamlocalClient(link, dockerSocket);

    final probe = docker.DockerClient(
      http,
      apiVersion: docker.clientMaxTestedApiVersion,
    );
    final ping = await probe.ping();
    final version = await probe.version();
    final (_, negotiation) = await docker.negotiateDockerClient(http);

    expect(ping.isPodman, isFalse);
    expect(ping.apiVersion, isNotNull);
    expect(
      version.version,
      '29.9.1',
      reason:
          'the dind image pin in test/integration/docker-compose.yml; '
          'bump both together',
    );
    expect(version.apiVersion, ping.apiVersion);
    final serverMax = version.apiVersion!;
    expect(
      negotiation.negotiated,
      serverMax < docker.clientMaxTestedApiVersion
          ? serverMax
          : docker.clientMaxTestedApiVersion,
    );
    expect(link.seen.forwardingRefused, isFalse);
  });

  test('the seeded containers list with their health, stacks and '
      'managers', () async {
    final link = await connect(fixture.user);
    final (engine, _) = await docker.negotiateDockerClient(
      streamlocalClient(link, dockerSocket),
    );

    final listed = await engine.listContainers();

    expect(listed.warnings, isEmpty);
    final byName = {
      for (final container in listed.value) container.name: container,
    };
    expect(
      byName.keys,
      containsAll([
        'demo-web-1',
        'demo-broken-1',
        'demo-console-1',
        'gone-idle-1',
        'coolify-app',
      ]),
    );
    expect(byName['demo-web-1']!.health, docker.HealthStatus.healthy);
    expect(byName['demo-broken-1']!.health, docker.HealthStatus.unhealthy);
    for (final name in ['demo-web-1', 'demo-broken-1', 'demo-console-1']) {
      expect(
        byName[name]!.labels['com.docker.compose.project']?.display,
        'demo',
        reason: name,
      );
    }
    expect(byName['coolify-app']!.labels['coolify.managed']?.display, 'true');
  });

  test('the second discovery path reaches the same engine', () async {
    final link = await connect(fixture.user);
    final uid = (await link.run('id -u')).stdout.trim();
    final (first, _) = await docker.negotiateDockerClient(
      streamlocalClient(link, dockerSocket),
    );
    final (second, _) = await docker.negotiateDockerClient(
      streamlocalClient(link, '/run/user/$uid/docker.sock'),
    );

    final id = (await first.info())['ID'];
    expect(id, isA<String>());
    expect((await second.info())['ID'], id);
  });
}
