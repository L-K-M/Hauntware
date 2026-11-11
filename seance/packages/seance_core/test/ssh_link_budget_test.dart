// `SshLink`'s session-channel budget against the in-process wire fixture:
// opens past the budget queue on the link instead of reaching the server,
// queued opens are served in priority order, and a server that refuses a
// session below the budget teaches the link its real limit. Assertions are
// on the opens the peer actually received.
import 'dart:async';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

void main() {
  test('a timed-out SFTP waiter releases a grant that arrives late', () async {
    final link = await openTestLink(
      timeout: const Duration(milliseconds: 30),
      sessionBudget: 1,
    );
    addTearDown(link.link.close);
    link.peer.onExec = SshChannelPeer.execQuietFollower;
    final held = await link.link.start('hold');
    final fileSystem = await link.link.openFileSystem();

    await expectLater(
      fileSystem.canonicalize('/srv'),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.other,
        ),
      ),
    );

    await held.close();
    await pumpEventQueue();
    link.peer.onExec = SshChannelPeer.execEchoAndExit;
    expect(
      (await link.link.run('after timeout')).stdout,
      'ran:after timeout\n',
    );
  });

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

        // The refused open is not the caller's failure: it waits on the link
        // under the learned limit.
        final refused = link.link.start('follow 2');
        await pumpEventQueue();
        expect(link.peer.sessionOpensRefused, 1);
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
        expect(states, [isA<SshLinkReady>(), degraded]);

        // Degraded, not failed: the next open waits on the link too instead
        // of going out to be refused again, and both run, in order, as
        // slots free.
        link.peer.onExec = SshChannelPeer.execEchoAndExit;
        final queued = link.link.run('uptime');
        await pumpEventQueue();
        expect(link.peer.sessionOpenRequests, 3);

        await held.first.close();
        expect((await (await refused).exit).exitCode, 0);
        expect((await queued).exitCode, 0);
        expect(link.peer.sessionOpensRefused, 1);
        expect(link.peer.channels.skip(2).map((c) => c.execCommand), [
          'follow 2',
          'uptime',
        ]);
      });
    }

    test('in a burst learns the count the server held, and the refused '
        'opens queue instead of failing', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer
        ..sessionChannelLimit = 4
        ..onExec = SshChannelPeer.execQuietFollower;

      // Eight opens go out at once against MaxSessions 4: the last four are
      // refused while the first four are still settling on the link.
      final started = <RemoteProcess>[];
      final failures = <Object>[];
      for (var index = 0; index < 8; index++) {
        link.link
            .start('follow $index')
            .then(started.add, onError: failures.add)
            .ignore();
      }
      await pumpEventQueue();

      expect(failures, isEmpty);
      expect(started, hasLength(4));
      expect(link.peer.sessionOpensRefused, 4);
      expect(link.link.seen.learnedSessionLimit, 4);

      // Each refused open waits for a slot and goes out once more.
      for (final process in started.toList()) {
        await process.close();
      }
      await pumpEventQueue();
      expect(failures, isEmpty);
      expect(started, hasLength(8));
      expect(link.peer.sessionOpensRefused, 4);
      for (final process in started.skip(4)) {
        await process.close();
      }
    });

    test('whose slot does not free in time reaches the caller as the '
        'refusal', () async {
      final link = await openTestLink(
        timeout: const Duration(milliseconds: 30),
      );
      addTearDown(link.link.close);
      await _holdBehindLimit(link, (
        reasonCode: peerRefusalConnectFailed,
        description: 'open failed',
      ));

      await expectLater(
        link.link.start('follow 2'),
        throwsA(_refusedAs(ChannelRefusal.sessionLimit)),
      );
      expect(link.peer.sessionOpensRefused, 1);
    });

    test('with nothing open teaches nothing the first time', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.sessionChannelLimit = 0;

      await expectLater(
        link.link.run('uptime'),
        throwsA(_refusedAs(ChannelRefusal.other)),
      );
      expect(link.link.seen.learnedSessionLimit, isNull);
      expect(link.link.state, isA<SshLinkReady>());

      // A second refusal with nothing open is the server's answer: it
      // takes no session channels on this link.
      await expectLater(
        link.link.run('uptime'),
        throwsA(_refusedAs(ChannelRefusal.sessionLimit)),
      );
      expect(link.link.seen.learnedSessionLimit, 0);
      expect(link.link.state, isA<SshLinkDegraded>());
    });

    test('stays degraded when a forwarding refusal follows', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      final held = await _holdBehindLimit(link, (
        reasonCode: peerRefusalConnectFailed,
        description: 'open failed',
      ));
      final refused = link.link.start('follow 2');
      await pumpEventQueue();
      link.peer.streamlocalRefusal = (
        reasonCode: peerRefusalAdministrativelyProhibited,
        description: 'administratively prohibited',
      );

      await expectLater(
        link.link.openUnixStream('/var/run/docker.sock'),
        throwsA(_refusedAs(ChannelRefusal.forwardDisabled)),
      );

      // The new fact is carried by the state the link was in; the learned
      // limit does not disappear behind a Ready.
      const seen = SshLinkSeen(
        learnedSessionLimit: 2,
        forwardingRefused: true,
        serverIdentification: peerIdentification,
      );
      expect(
        link.link.state,
        isA<SshLinkDegraded>()
            .having(
              (state) => state.reason,
              'reason',
              SshLinkDegradedReason.sessionLimitLearned,
            )
            .having((state) => state.seen, 'seen', seen),
      );

      await held.first.close();
      await (await refused).close();
    });

    test('that lands while the link closes leaves it closed', () async {
      final link = await openTestLink(
        closeTimeout: const Duration(milliseconds: 300),
      );
      link.peer.sessionChannelLimit = 1;
      // The fixture never answers EOF on the SFTP channel, so the close
      // waits out its bound on the lease while the refusal arrives.
      final fileSystem = await link.link.openFileSystem();
      expect(await fileSystem.canonicalize('/srv'), '/srv');
      link.peer.channelOpenDelay = const Duration(milliseconds: 50);
      final refused = link.link.start('follow');
      unawaited(refused.then<void>((_) {}, onError: (Object _) {}));
      await pumpEventQueue();

      await link.link.close();

      expect(link.peer.sessionOpensRefused, 1);
      expect(link.link.state, isA<SshLinkClosed>());
    });

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
