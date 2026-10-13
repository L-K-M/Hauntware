// `ByteDuplex` and the forwarding opens behind it: the transport is an
// in-process SSH peer, so window exhaustion, EOF and refusal are observed as
// wire traffic rather than asserted against a mock.
import 'dart:async';
import 'dart:convert';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

void main() {
  group('SshLink.openUnixStream', () {
    test('carries bytes both ways over direct-streamlocal', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final duplex = await link.link.openUnixStream('/var/run/docker.sock');
      final inbound = <int>[];
      final done = duplex.stream.listen(inbound.addAll).asFuture<void>();

      final channel = await _waitForChannel(link.peer);
      expect(channel.type, 'direct-streamlocal@openssh.com');
      channel.sendData(utf8.encode('HTTP/1.1 200 OK\r\n'));

      duplex.sink.add(utf8.encode('GET /health HTTP/1.0\r\n'));
      await _eventually(() => channel.stdinBytes.isNotEmpty);
      expect(utf8.decode(channel.stdinBytes), 'GET /health HTTP/1.0\r\n');

      await _eventually(() => utf8.decode(inbound) == 'HTTP/1.1 200 OK\r\n');
      expect(utf8.decode(inbound), 'HTTP/1.1 200 OK\r\n');

      await duplex.close();
      await done;
    });

    test('a refusal classifies as forwardDisabled and is remembered', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.streamlocalRefusal = (
        reasonCode: peerRefusalAdministrativelyProhibited,
        description: 'administratively prohibited',
      );

      await expectLater(
        link.link.openUnixStream('/var/run/docker.sock'),
        throwsA(
          isA<ChannelOpenException>().having(
            (error) => error.refusal,
            'refusal',
            ChannelRefusal.forwardDisabled,
          ),
        ),
      );
      expect(link.link.seen.forwardingRefused, isTrue);
      // The learned fact re-emits Ready so listeners see it without polling.
      expect(link.link.state, isA<SshLinkReady>());
      expect((link.link.state as SshLinkReady).seen.forwardingRefused, isTrue);
    });

    test(
      'a refused forwarding open releases the link for other work',
      () async {
        final link = await openTestLink();
        addTearDown(link.link.close);
        link.peer.streamlocalRefusal = (
          reasonCode: peerRefusalAdministrativelyProhibited,
          description: 'administratively prohibited',
        );

        await expectLater(
          link.link.openUnixStream('/var/run/docker.sock'),
          throwsA(isA<ChannelOpenException>()),
        );

        expect((await link.link.run('uname')).exitCode, 0);
      },
    );
  });

  group('SshLink.openTcpStream', () {
    test('carries bytes both ways over direct-tcpip', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final duplex = await link.link.openTcpStream('10.0.0.5', 5432);
      final inbound = <int>[];
      duplex.stream.listen(inbound.addAll);

      final channel = await _waitForChannel(link.peer);
      expect(channel.type, 'direct-tcpip');
      channel.sendData(utf8.encode('PING'));

      duplex.sink.add(utf8.encode('PONG'));
      await _eventually(() => channel.stdinBytes.isNotEmpty);

      await _eventually(() => utf8.decode(inbound) == 'PING');
      expect(utf8.decode(channel.stdinBytes), 'PONG');

      await duplex.close();
    });

    test('a tcpip refusal also classifies as forwardDisabled', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.tcpipRefusal = (
        reasonCode: peerRefusalConnectFailed,
        description: 'connect failed',
      );

      await expectLater(
        link.link.openTcpStream('10.0.0.5', 5432),
        throwsA(
          isA<ChannelOpenException>().having(
            (error) => error.refusal,
            'refusal',
            ChannelRefusal.forwardDisabled,
          ),
        ),
      );
    });
  });

  group('ByteDuplex buffering and backpressure', () {
    test('delivers bytes that arrived before the consumer listened', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      // Small enough that the payload fits in the granted window: the test is
      // about replay, not about window credit.
      link.peer.windowSize = 64 * 1024;
      link.peer.onDuplexOpen = (channel) =>
          channel.sendData(utf8.encode('early bytes'));

      final duplex = await link.link.openUnixStream('/run/early.sock');
      // The peer answered the open before anything listened here.
      await _eventually(() => link.peer.channels.isNotEmpty);
      expect(await duplex.stream.first, utf8.encode('early bytes'));

      await duplex.close();
    });

    test('a paused consumer stalls the peer at its window', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final duplex = await link.link.openUnixStream('/run/slow.sock');
      final channel = await _waitForChannel(link.peer);

      // Paused before the peer sends: the client admits exactly its 2 MiB
      // window and grants nothing more while the consumer is paused.
      final subscription = duplex.stream.listen((_) {});
      subscription.pause();
      const window = 2 * 1024 * 1024;
      channel.sendData(List<int>.filled(window + 64 * 1024, 0x61));
      await _eventually(() => channel.sendWindowRemaining == 0);
      final stalledAt = channel.bytesSent;
      expect(stalledAt, window);

      // Pausing the consumer stops the window grants, so the peer's send
      // queue stops draining instead of the link buffering without limit.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(channel.bytesSent, stalledAt);
      expect(channel.sendWindowRemaining, 0);

      subscription.resume();
      await _eventually(() => channel.bytesSent > stalledAt);

      await duplex.close();
    });

    test(
      'sink close sends channel EOF while the read side stays open',
      () async {
        final link = await openTestLink();
        addTearDown(link.link.close);

        final duplex = await link.link.openUnixStream('/run/half.sock');
        final channel = await _waitForChannel(link.peer);
        channel.closeOnStdinEof = false;
        final inbound = <int>[];
        duplex.stream.listen(inbound.addAll);

        duplex.sink.add(utf8.encode('request'));
        await duplex.sink.close();

        // The client's EOF ends only its own write side: the client has not
        // closed the channel, and the peer's bytes still arrive.
        await _eventually(() => channel.eofFromClient);
        expect(channel.closeFromClient, isFalse);
        channel.sendData(utf8.encode('after-eof'));
        await _eventually(() => utf8.decode(inbound) == 'after-eof');

        // The peer finishes its side, as a server does when its target closes.
        channel.sendEof();
        channel.sendClose();
        await duplex.close();
      },
    );

    test('close is idempotent', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final duplex = await link.link.openUnixStream('/run/once.sock');
      await duplex.close();
      await expectLater(duplex.close(), completes);
    });

    test('done completes when the peer closes the channel', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final duplex = await link.link.openUnixStream('/run/done.sock');
      final channel = await _waitForChannel(link.peer);

      channel.sendClose();
      await duplex.done;
    });

    test('the link refuses a duplex once its own bound is reached', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      for (var index = 0; index < 16; index++) {
        await link.link.openUnixStream('/run/socket-$index');
      }

      await expectLater(
        link.link.openUnixStream('/run/one-too-many'),
        throwsA(
          isA<ChannelOpenException>().having(
            (error) => error.message,
            'message',
            contains('16 open streams'),
          ),
        ),
      );
    });

    test('concurrent opens cannot overshoot the bound', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      // Every open passes the bound check before any completes, so the
      // check has to count the opens still in flight.
      final outcomes = await Future.wait([
        for (var index = 0; index < 17; index++)
          link.link
              .openUnixStream('/run/burst-$index')
              .then<Object>((duplex) => duplex, onError: (Object e) => e),
      ]);

      expect(outcomes.whereType<ByteDuplex>(), hasLength(16));
      expect(outcomes.whereType<ChannelOpenException>(), hasLength(1));
    });

    test('duplexes do not consume the session budget', () async {
      final link = await openTestLink(sessionBudget: 1);
      addTearDown(link.link.close);

      for (var index = 0; index < 4; index++) {
        await link.link.openUnixStream('/run/forward-$index');
      }

      expect((await link.link.run('uname')).exitCode, 0);
    });
  });
}

/// Waits for the peer to have opened one channel.
Future<SshPeerChannel> _waitForChannel(SshChannelPeer peer) async {
  for (var attempt = 0; attempt < 200 && peer.channels.isEmpty; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (peer.channels.isEmpty) fail('The peer never opened the channel.');
  return peer.channels.single;
}

/// Waits for [condition] to hold; the fixture answers on the same event loop,
/// so a bounded number of turns is enough and no real delay is involved.
Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 5000; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('The fixture never reported the expected wire traffic.');
}
