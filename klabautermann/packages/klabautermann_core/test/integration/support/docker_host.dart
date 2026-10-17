import 'dart:io';

import 'package:klabautermann_core/src/docker/duplex_adapters.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart' as docker;
import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        HostKeyVerdict,
        InMemoryHostKeyStore,
        ServerConfig,
        SshCredentials,
        SshLink,
        TofuVerifier;
import 'package:test/test.dart';

import 'fixture.dart';

/// The engine's first candidate path (03 §5.4), a link to dind's socket
/// on the Docker host and its variants (`sshd/docker-setup.sh`).
const dockerSocket = '/var/run/docker.sock';

/// The Docker host's account outside its `docker` group.
const negativeUser = 'klab-nosock';

/// A link to [service], one of the Docker host's sshd services, as [user]
/// with the key file, trusting only a host key the container really has
/// ([Fixture.hostKeyFingerprints]). The test's teardown closes it.
Future<SshLink> connectDockerHost(
  Fixture fixture,
  FixtureService service,
  String user,
) async {
  final hostKeys = await fixture.hostKeyFingerprints(service);
  final endpoint = await fixture.endpoint(service);
  final link = await SshLink.connect(
    config: ServerConfig(
      id: '${service.composeName}-$user',
      label: service.composeName,
      host: endpoint.host,
      port: endpoint.port,
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
/// [socket] over [link]. The test's teardown closes it.
docker.DockerHttpClient streamlocalClient(SshLink link, String socket) {
  final http = docker.DockerHttpClient(
    () async => SshDuplexAdapter(await link.openUnixStream(socket)),
  );
  addTearDown(http.close);
  return http;
}
