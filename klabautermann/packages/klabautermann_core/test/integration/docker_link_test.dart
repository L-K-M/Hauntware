// The fixture's Docker host over a real SshLink (03 §5.4, §11.3; M3 D10):
// rank 1, `direct-streamlocal` to dind's socket through
// `SshLink.openUnixStream`, with klabautermann_docker's HTTP client on
// the duplex. It is the repository's first real `forwardLocalUnix` call
// and spike S1's streamlocal evidence. run.sh starts the fixture and
// seeds the engine (seed_docker.sh); without it these skip.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:klabautermann_docker/klabautermann_docker.dart' as docker;
import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        ByteDuplex,
        ChannelOpenException,
        HostKeyVerdict,
        InMemoryHostKeyStore,
        ServerConfig,
        SshCredentials,
        SshLink,
        TofuVerifier;
import 'package:test/test.dart';

import 'support/fixture.dart';

/// The engine's first candidate path (03 §5.4), a link to dind's socket
/// on the Docker host (`sshd/docker-setup.sh`).
const _socket = '/var/run/docker.sock';

/// The Docker host's account outside its `docker` group.
const _negativeUser = 'klab-nosock';

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the Docker fixture suite', () {}, skip: fixtureSkipReason);
    return;
  }

  late Set<String> hostKeys;
  setUpAll(
    () async =>
        hostKeys = await fixture.hostKeyFingerprints(FixtureService.dockerHost),
  );

  /// A link to the Docker host as [user], trusting only a host key the
  /// container really has.
  Future<SshLink> connect(String user) async {
    final link = await SshLink.connect(
      config: ServerConfig(
        id: 'docker-host-$user',
        label: 'docker host',
        host: fixture.dockerHost.host,
        port: fixture.dockerHost.port,
        username: user,
        authMethod: AuthMethod.privateKey,
        identityFilePath: fixture.identityFile,
        createdAt: 0,
        updatedAt: 0,
      ),
      credentials: SshCredentials.privateKey(
        await File(fixture.identityFile).readAsString(),
      ),
      tofu: TofuVerifier(InMemoryHostKeyStore()),
      onHostKey: (decision) async =>
          decision.verdict == HostKeyVerdict.firstUse &&
          hostKeys.contains(decision.presented.fingerprintSha256),
    );
    addTearDown(link.close);
    return link;
  }

  /// An HTTP client whose every connection is a new streamlocal duplex to
  /// [socket] over [link].
  docker.DockerHttpClient client(SshLink link, String socket) {
    final http = docker.DockerHttpClient(
      () async => _StreamlocalDuplex(await link.openUnixStream(socket)),
    );
    addTearDown(http.close);
    return http;
  }

  test('the fixture user pings and negotiates with dind over '
      'streamlocal', () async {
    final link = await connect(fixture.user);
    final http = client(link, _socket);

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
      client(link, _socket),
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
      client(link, _socket),
    );
    final (second, _) = await docker.negotiateDockerClient(
      client(link, '/run/user/$uid/docker.sock'),
    );

    final id = (await first.info())['ID'];
    expect(id, isA<String>());
    expect((await second.info())['ID'], id);
  });

  test('a user outside the docker group cannot open the socket', () async {
    final link = await connect(_negativeUser);

    // The socket is there and refuses this account (EACCES), so sshd
    // refuses the open.
    expect((await link.run('test -S $_socket')).exitCode, 0);
    expect((await link.run('test -w $_socket')).exitCode, isNot(0));
    await expectLater(
      link.openUnixStream(_socket),
      throwsA(isA<ChannelOpenException>()),
    );
  });
}

/// seance_core's duplex as klabautermann_docker's seam, its half-close
/// the sink's close (channel EOF with the read side open). The engine's
/// own adapter comes with M3's transport PR (D04); this one serves the
/// smoke test until then.
final class _StreamlocalDuplex implements docker.ByteDuplex {
  _StreamlocalDuplex(this._channel);

  final ByteDuplex _channel;

  @override
  Stream<List<int>> get stream => _channel.stream;

  @override
  StreamSink<List<int>> get sink => _channel.sink;

  @override
  Future<void> closeWrite() => _channel.sink.close();

  @override
  Future<void> close() => _channel.close();

  @override
  Future<void> get done => _channel.done;
}
