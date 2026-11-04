import 'dart:async';
import 'dart:io';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';
import 'support/ssh_peer.dart';

void main() {
  test('a stalled interactive shell open is bounded and typed', () async {
    final socket = SshPeerSocket();
    final peer = SshChannelPeer(socket)..ignoreChannelOpens = true;
    final manager = _manager(socket);

    await expectLater(
      manager.connect(
        config: testLinkConfig,
        credentials: const SshCredentials.password('test-password'),
        engine: HeadlessTerminalEngine(),
        timeout: const Duration(milliseconds: 250),
      ),
      throwsA(
        isA<SshConnectException>().having(
          (error) => error.kind,
          'kind',
          SshConnectFailureKind.timedOut,
        ),
      ),
    );
    expect(peer.channelOpensSeen, 1);
  });

  test('stalled legacy exec and SFTP opens are bounded', () async {
    final socket = SshPeerSocket();
    final peer = SshChannelPeer(socket);
    final session = await _manager(socket).connect(
      config: testLinkConfig,
      credentials: const SshCredentials.password('test-password'),
      engine: HeadlessTerminalEngine(),
      timeout: const Duration(milliseconds: 250),
    );
    addTearDown(session.close);
    peer.ignoreChannelOpens = true;

    await expectLater(
      session.runCommand('stalled'),
      throwsA(isA<RemoteCommandException>()),
    );
    await expectLater(
      session.openRemoteFileSystem(timeout: const Duration(milliseconds: 250)),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.other,
        ),
      ),
    );

    final forward = await session.forwardToLoopback('target.internal', 8080);
    final browser = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forward.port,
    );
    final browserEnded = Completer<void>();
    browser.listen(
      (_) {},
      onError: (Object _) {
        if (!browserEnded.isCompleted) browserEnded.complete();
      },
      onDone: () {
        if (!browserEnded.isCompleted) browserEnded.complete();
      },
    );
    await browserEnded.future.timeout(const Duration(seconds: 1));
    browser.destroy();

    expect(peer.channelOpensSeen, 4);
  });
}

SshSessionManager _manager(SshPeerSocket socket) => SshSessionManager(
  tofu: TofuVerifier(InMemoryHostKeyStore()),
  onHostKey: (_) async => true,
  connect: (_, _, _) async => socket,
);
