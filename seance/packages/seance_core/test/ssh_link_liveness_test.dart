// `SshLink`'s own liveness clock against the in-process wire fixture, on a
// fake clock: the peer's key exchange and replies run on microtasks alone,
// so minutes of link time pass in milliseconds and every tick is exact.
// Pings are counted where the peer receives them, not inside the link.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

/// The production idle interval and response deadline (transport design
/// §4.2), passed through the seams so a default change cannot move them.
const _interval = Duration(seconds: 15);
const _deadline = Duration(seconds: 30);

/// Fake time that covers the link's bounded teardown. Close steps that await
/// a stream cancel resolve on the root zone, which a fake clock never drains,
/// so here they wait out their 5 s bounds instead of finishing at once.
const _teardown = Duration(minutes: 1);

/// One byte from the peer: proof of life without being asked.
const _byte = [0x2e];

void main() {
  test('a silent peer closes the link as pingTimeout at the deadline', () {
    fakeAsync((async) {
      final link = _connect(async);
      final states = <SshLinkState>[];
      link.link.states.listen(states.add);
      var hungUp = false;
      unawaited(link.socket.done.then((_) => hungUp = true));
      link.peer.silent = true;

      async.elapse(_interval);
      expect(link.peer.pingRequestsSeen, 1);

      // The deadline runs from the ping. One second short the link is still
      // ready, and the tick in between did not stack a second ping.
      async.elapse(_deadline - const Duration(seconds: 1));
      expect(link.link.state, isA<SshLinkReady>());
      expect(link.peer.pingRequestsSeen, 1);

      async.elapse(const Duration(seconds: 1));
      expect(states, [isA<SshLinkReady>(), _closedBy(.pingTimeout)]);
      expect(hungUp, isTrue);

      // The clock stopped with the link: nothing more reaches the wire.
      expect(async.periodicTimerCount, 0);
      async.elapse(_interval * 4);
      expect(link.peer.pingRequestsSeen, 1);
    });
  });

  group('pings are skipped only while bytes arrive', () {
    // Each source hands back a function that sends one byte from the peer.
    final sources = <String, void Function() Function(FakeAsync, TestLink)>{
      'process stdout': (async, link) {
        _startFollower(async, link);
        final channel = link.peer.channels.last;
        return () => channel.sendData(_byte);
      },
      'process stderr': (async, link) {
        _startFollower(async, link);
        final channel = link.peer.channels.last;
        return () => channel.sendStderr(_byte);
      },
      'forwarded stream': (async, link) {
        _settle(async, link.link.openUnixStream('/run/app.sock'));
        final channel = link.peer.channels.last;
        return () => channel.sendData(_byte);
      },
    };

    for (final MapEntry(key: name, value: open) in sources.entries) {
      test('on $name', () {
        fakeAsync((async) {
          final link = _connect(async);
          final sendByte = open(async, link);

          // A byte every third of an interval for four intervals: every
          // tick finds fresh inbound bytes and asks nothing.
          for (var step = 0; step < 12; step++) {
            sendByte();
            async.elapse(_interval ~/ 3);
          }
          expect(link.peer.pingRequestsSeen, 0);

          // The first tick without fresh bytes pings, and so does each
          // tick after it.
          async.elapse(_interval);
          expect(link.peer.pingRequestsSeen, 1);
          async.elapse(_interval);
          expect(link.peer.pingRequestsSeen, 2);
          expect(link.link.state, isA<SshLinkReady>());

          _close(async, link);
        });
      });
    }
  });

  test('a quiet follower channel does not suppress pings', () {
    fakeAsync((async) {
      final link = _connect(async);
      final follower = _startFollower(async, link);
      var followerEnded = false;
      unawaited(
        follower.exit.then<void>(
          (_) => followerEnded = true,
          onError: (Object _) => followerEnded = true,
        ),
      );
      var hungUp = false;
      unawaited(link.socket.done.then((_) => hungUp = true));

      // Ten minutes with an open channel that says nothing: an open channel
      // is not proof of life, so every tick still asks.
      async.elapse(const Duration(minutes: 10));
      expect(link.peer.pingRequestsSeen, 40);
      expect(link.link.state, isA<SshLinkReady>());

      // The path drops silently while the follower runs; the next ping goes
      // unanswered and the link closes instead of idling behind it.
      link.peer.silent = true;
      async.elapse(_interval + _deadline);
      expect(link.link.state, _closedBy(.pingTimeout));
      expect(link.peer.pingRequestsSeen, 41);

      // The close tore the follower down with the transport.
      async.elapse(_teardown);
      expect(followerEnded, isTrue);
      expect(hungUp, isTrue);
    });
  });
}

/// Connects a link inside the fake zone with the liveness seams set.
TestLink _connect(FakeAsync async) => _settle(
  async,
  openTestLink(idlePingInterval: _interval, pingTimeout: _deadline),
);

/// Starts a command the peer accepts and then never answers.
RemoteProcess _startFollower(FakeAsync async, TestLink link) {
  link.peer.onExec = SshChannelPeer.execQuietFollower;
  return _settle(async, link.link.start('tail -f /var/log/syslog'));
}

/// Closes the link inside the fake zone, so its ping clock never outlives the
/// test, and checks that the clock stopped.
void _close(FakeAsync async, TestLink link) {
  var closed = false;
  unawaited(link.link.close().then((_) => closed = true));
  async.elapse(_teardown);
  expect(closed, isTrue);
  expect(link.link.state, _closedBy(.closedByOwner));
  expect(async.periodicTimerCount, 0);
}

/// Completes [future] on microtasks alone: the in-memory peer answers without
/// timers, so no fake time passes while the fixture talks.
T _settle<T>(FakeAsync async, Future<T> future) {
  late final T value;
  var completed = false;
  Object? error;
  StackTrace? stackTrace;
  unawaited(
    future.then(
      (result) {
        value = result;
        completed = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stackTrace = s;
      },
    ),
  );
  async.flushMicrotasks();
  if (error case final error?) Error.throwWithStackTrace(error, stackTrace!);
  if (!completed) fail('The fixture did not answer on microtasks alone.');
  return value;
}

Matcher _closedBy(SshLinkClosedReason reason) =>
    isA<SshLinkClosed>().having((state) => state.reason, 'reason', reason);
