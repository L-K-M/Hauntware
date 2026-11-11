// The SFTP channel `SshLink.openFileSystem` leases, against the in-process
// wire fixture on a fake clock: the lease is held while any call on it runs
// and released after the idle period that follows the last one.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

const _idleRelease = Duration(seconds: 10);

/// Longer than [_idleRelease], shorter than the SFTP adapter's 30 s
/// per-request bound.
const _slowAnswer = Duration(seconds: 25);

/// Fake time that covers the link's bounded teardown (see
/// ssh_link_liveness_test.dart).
const _teardown = Duration(minutes: 1);

void main() {
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
