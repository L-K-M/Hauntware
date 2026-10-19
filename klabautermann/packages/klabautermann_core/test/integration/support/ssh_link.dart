import 'dart:io';

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

import 'fixture.dart' show Endpoint;

/// A link to [endpoint] as [user] with the key in [identityFile],
/// trusting only a host key in [hostKeys] (SHA256 fingerprints). [id]
/// names it in the link's own messages. The test's teardown closes it;
/// closing it earlier, as a test that ends a session does, is fine.
Future<SshLink> connectLink({
  required String id,
  required Endpoint endpoint,
  required String user,
  required String identityFile,
  required Set<String> hostKeys,
}) async {
  final link = await SshLink.connect(
    config: ServerConfig(
      id: id,
      label: id,
      host: endpoint.host,
      port: endpoint.port,
      username: user,
      authMethod: AuthMethod.privateKey,
      identityFilePath: identityFile,
      createdAt: 0,
      updatedAt: 0,
    ),
    credentials: SshCredentials.privateKey(
      await File(identityFile).readAsString(),
    ),
    tofu: TofuVerifier(InMemoryHostKeyStore()),
    onHostKey: (decision) async =>
        decision.verdict == HostKeyVerdict.firstUse &&
        hostKeys.contains(decision.presented.fingerprintSha256),
  );
  addTearDown(link.close);
  return link;
}
