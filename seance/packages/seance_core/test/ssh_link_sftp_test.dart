// The SFTP channel `SshLink.openFileSystem` leases, against the in-process
// wire fixture on a fake clock: the lease is held while any call on it runs
// and released after the idle period that follows the last one.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

const _idleRelease = Duration(seconds: 10);

/// The production open bound.
const _openTimeout = Duration(seconds: 15);

/// Longer than [_idleRelease], shorter than the SFTP adapter's 30 s
/// per-request bound.
const _slowAnswer = Duration(seconds: 25);

/// Fake time that covers the link's bounded teardown (see
/// ssh_link_liveness_test.dart).
const _teardown = Duration(minutes: 1);

void main() {
  test('a server without an SFTP subsystem fails fast as unsupported', () {
    fakeAsync((async) {
      final link = _settle(async, openTestLink(timeout: _openTimeout));
      link.peer.refuseSftpSubsystem = true;
      final fileSystem = _settle(async, link.link.openFileSystem());

      Object? error;
      unawaited(
        fileSystem
            .canonicalize('/srv')
            .then<void>((_) {}, onError: (Object e) => error = e),
      );
      // The refusal never reaches the link (dartssh2 drops the subsystem
      // reply), so a short handshake bound stands in for it, well inside
      // the open bound, and the link itself is fine.
      async.elapse(const Duration(seconds: 5));
      expect(
        error,
        isA<RemoteFileException>().having(
          (e) => e.kind,
          'kind',
          RemoteFileErrorKind.unsupported,
        ),
      );
      expect(link.link.state, isA<SshLinkReady>());

      _close(async, link);
    });
  });

  test('a session-limit refusal of the SFTP channel queues and opens once a '
      'slot frees', () async {
    final link = await openTestLink();
    addTearDown(link.link.close);
    link.peer
      ..sessionChannelLimit = 1
      ..onExec = SshChannelPeer.execQuietFollower;
    final held = await link.link.start('follow');
    final fileSystem = await link.link.openFileSystem();

    final resolved = fileSystem.canonicalize('/srv');
    await pumpEventQueue();
    expect(link.peer.sessionOpensRefused, 1);
    expect(link.link.seen.learnedSessionLimit, 1);

    await held.close();
    expect(await resolved, '/srv');
  });

  test('a lease whose SFTP channel died is replaced', () async {
    final link = await openTestLink(sessionBudget: 1);
    addTearDown(link.link.close);
    final fileSystem = await link.link.openFileSystem();
    expect(await fileSystem.canonicalize('/srv'), '/srv');

    // The server ends the SFTP channel under an idle lease.
    link.peer.channels.single
      ..sendEof()
      ..sendClose();
    await pumpEventQueue();

    await expectLater(
      fileSystem.canonicalize('/srv'),
      throwsA(isA<RemoteFileException>()),
    );
    // The dead lease gave back its slot: the next call opens a new channel
    // although the budget holds only one.
    expect(await fileSystem.canonicalize('/srv'), '/srv');
    expect(
      link.peer.channels.where((c) => c.subsystem == 'sftp'),
      hasLength(2),
    );
  });

  test('a short call ending under a long one does not release the lease', () {
    fakeAsync((async) {
      final link = _settle(async, openTestLink(sftpIdleRelease: _idleRelease));
      link.peer.realpathDelays['/slow'] = _slowAnswer;
      final fileSystem = _settle(async, link.link.openFileSystem());

      String? slow;
      Object? slowError;
      unawaited(
        fileSystem
            .canonicalize('/slow')
            .then(
              (value) => slow = value,
              onError: (Object e) => slowError = e,
            ),
      );
      async.flushMicrotasks();
      expect(_settle(async, fileSystem.canonicalize('/fast')), '/fast');

      // The short call's end is past the idle period long before the slow
      // call answers; the lease stays because the slow call still runs.
      async.elapse(_slowAnswer);
      expect(slowError, isNull);
      expect(slow, '/slow');
      final sftp = link.peer.channels.singleWhere((c) => c.subsystem == 'sftp');
      expect(sftp.eofFromClient, isFalse);

      // The idle period runs from the end of the last call; a release
      // starts with EOF on the channel.
      async.elapse(_idleRelease - const Duration(seconds: 1));
      expect(sftp.eofFromClient, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(sftp.eofFromClient, isTrue);

      _close(async, link);
    });
  });
}

/// Closes the link inside the fake zone so no timer outlives the test.
void _close(FakeAsync async, TestLink link) {
  unawaited(link.link.close());
  async.elapse(_teardown);
  expect(link.link.state, isA<SshLinkClosed>());
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
