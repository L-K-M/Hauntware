// `SshLink`'s session-channel budget against the in-process wire fixture:
// opens past the budget queue on the link instead of reaching the server,
// queued opens are served in priority order, and a server that refuses a
// session below the budget teaches the link its real limit. Assertions are
// on the opens the peer actually received.
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

void main() {
  test('the ninth open queues and slots go out in priority order', () async {
    // The fixture never answers EOF on the SFTP channel, so teardown waits
    // out the close bound; keep it short.
    final link = await openTestLink(
      closeTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(link.link.close);
    link.peer.onExec = SshChannelPeer.execQuietFollower;
    final held = [
      for (var index = 0; index < 8; index++)
        await link.link.start('follow $index'),
    ];
    link.peer.onExec = SshChannelPeer.execEchoAndExit;

    // SFTP asks first, then two user actions; all three wait for a slot.
    final fileSystem = await link.link.openFileSystem();
    final sftpCall = fileSystem.canonicalize('/srv');
    final first = link.link.run('first');
    final second = link.link.run('second');
    await pumpEventQueue();

    // Nothing reached the wire: the link queued the ninth open instead of
    // tripping the server's MaxSessions, and queueing is not degradation.
    expect(link.peer.sessionOpenRequests, 8);
    expect(link.link.state, isA<SshLinkReady>());

    // One freed slot passes down the queue as each command finishes: user
    // actions first and in arrival order, SFTP last although it asked first.
    await held.first.close();
    expect((await first).stdout, 'ran:first\n');
    expect((await second).stdout, 'ran:second\n');
    expect(await sftpCall, '/srv');
    expect(
      link.peer.channels.skip(8).map((c) => c.subsystem ?? c.execCommand),
      ['first', 'second', 'sftp'],
    );
  });

  group('a session refusal below the budget', () {
    // OpenSSH has reported MaxSessions refusals in both shapes; either
    // teaches the limit.
    final limitRefusals = <String, PeerRefusal>{
      'connect-failed': (
        reasonCode: peerRefusalConnectFailed,
        description: 'open failed',
      ),
      'administratively-prohibited "open failed"': (
        reasonCode: peerRefusalAdministrativelyProhibited,
        description: 'open failed',
      ),
    };

    for (final MapEntry(key: name, value: refusal) in limitRefusals.entries) {
      test('as $name learns the limit and degrades', () async {
        final link = await openTestLink();
        addTearDown(link.link.close);
        final states = <SshLinkState>[];
        final subscription = link.link.states.listen(states.add);
        addTearDown(subscription.cancel);
        final held = await _holdBehindLimit(link, refusal);

        await expectLater(
          link.link.start('follow 2'),
          throwsA(_refusedAs(ChannelRefusal.sessionLimit)),
        );
        expect(
          link.link.seen,
          const SshLinkSeen(
            learnedSessionLimit: 2,
            serverIdentification: peerIdentification,
          ),
        );
        final degraded = isA<SshLinkDegraded>().having(
          (state) => state.reason,
          'reason',
          SshLinkDegradedReason.sessionLimitLearned,
        );
        expect(link.link.state, degraded);
        await pumpEventQueue();
        expect(states, [isA<SshLinkReady>(), degraded]);

        // Degraded, not failed: the next open waits on the link under the
        // learned limit instead of going out to be refused again, and runs
        // once a slot frees.
        link.peer.onExec = SshChannelPeer.execEchoAndExit;
        final queued = link.link.run('uptime');
        await pumpEventQueue();
        expect(link.peer.sessionOpenRequests, 3);

        await held.first.close();
        expect((await queued).exitCode, 0);
        expect(link.peer.sessionOpensRefused, 1);
      });
    }

    test('that does not read as a limit teaches nothing', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      await _holdBehindLimit(link, (
        reasonCode: peerRefusalAdministrativelyProhibited,
        description: 'session channels disabled by policy',
      ));

      await expectLater(
        link.link.start('follow 2'),
        throwsA(_refusedAs(ChannelRefusal.other)),
      );
      expect(
        link.link.seen,
        const SshLinkSeen(serverIdentification: peerIdentification),
      );
      expect(link.link.state, isA<SshLinkReady>());
    });
  });
}

/// Caps the peer at two session channels refused with [refusal], and holds
/// both with quiet followers.
Future<List<RemoteProcess>> _holdBehindLimit(
  TestLink link,
  PeerRefusal refusal,
) async {
  link.peer
    ..sessionChannelLimit = 2
    ..sessionRefusal = refusal
    ..onExec = SshChannelPeer.execQuietFollower;
  return [await link.link.start('follow 0'), await link.link.start('follow 1')];
}

Matcher _refusedAs(ChannelRefusal refusal) => isA<ChannelOpenException>()
    .having((error) => error.refusal, 'refusal', refusal);
