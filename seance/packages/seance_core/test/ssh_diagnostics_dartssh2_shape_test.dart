// The tests that build dartssh2's real userauth messages, apart from the
// rest of the diagnostics suite: they import a `src/` file of the dependency,
// so an internal file move in a dartssh2 release stops *this* file compiling
// and nothing else — the blast radius is exactly the tests that depend on
// the internals, which is what makes that failure a signal.
//
// Pinning the exact toString dartssh2 prints is the point: the barrel does not
// export the message, and asserting against a hand-written copy of it would
// prove the pattern against itself rather than against the dependency. The
// lint is not enabled in this workspace, so the directive below is for
// whenever it is, and has to be the line immediately above the import with
// nothing after the code — prose beside it suppresses nothing.
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_userauth.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('connection-log redaction against the real dartssh2 messages', () {
    test('the real message dartssh2 sends is the shape this recognizes', () {
      // The one assertion that is not written against my reading of dartssh2:
      // it builds the message the client actually sends and redacts its own
      // toString, so an upgrade that changes the format fails here rather
      // than at the fail-closed branch in production.
      final log = SshConnectionLog();
      final raw = '${SSH_Message_Userauth_InfoResponse(responses: const [
        'hunter2',
        'second-answer',
      ])}';
      // The precondition, pinned whole. Through 3.x this read `contains
      // ('hunter2')`: the message printed its answers and the scrubber had
      // to remove them. dartssh2 4.0.0 (#229) prints only how many there
      // are, so the scrub is now a recognition, and the exact string is what
      // keeps this a tripwire rather than a vacuous pass: any change to the
      // shape, the answers coming back included, fails here. A `contains`
      // on the count would let `(responses: 2, values: [hunter2])` through.
      //
      // The secret is checked first and on its own, so a failure's reason
      // says which kind of change it is: the answers back, or only the
      // spelling moved.
      expect(
        raw,
        allOf(isNot(contains('hunter2')), isNot(contains('second-answer'))),
        reason: 'dartssh2 prints keyboard-interactive answers again. Scrub '
            'them at capture in SshConnectionLog before upgrading.',
      );
      expect(
        raw,
        'SSH_Message_Userauth_InfoResponse(responses: 2)',
        reason: 'dartssh2 has changed what SSH_Message_Userauth_InfoResponse '
            'prints. That is a dependency change: re-audit the message/ '
            'toStrings and re-base redactConnectionTrace before upgrading.',
      );
      log.add('-> sock: $raw');
      // Kept as printed, framing and all: the count carries nothing, and the
      // fail-closed branch withholding it instead would mean the recognition
      // no longer matches the real message, which is this test's subject.
      expect(
        log.toString(),
        '-> sock: SSH_Message_Userauth_InfoResponse(responses: 2)',
      );
      expect(log.toString(), isNot(contains('does not recognize')));
      // And the view the transcript widget reads, which has to agree.
      expect(
        log.lines.join('\n'),
        '-> sock: SSH_Message_Userauth_InfoResponse(responses: 2)',
      );
    });

    test('the real password request never carries the password either', () {
      // The *other* secret-bearing message. dartssh2 omits the password from
      // `SSH_Message_Userauth_Request.toString()` today, so nothing has to
      // scrub it — and until now nothing checked that, so an upgrade that
      // started printing it would put a plaintext password into a transcript
      // this feature shows with a Copy button and invites people to paste
      // into bug reports. Built from the real message for the same reason the
      // InfoResponse one is: a hand-written line would pin my reading of
      // dartssh2 rather than dartssh2.
      final raw = '${SSH_Message_Userauth_Request.password(
        user: 'deploy',
        password: 'hunter2',
      )}';
      // The mechanism, asserted on the message itself rather than through the
      // log: the password is absent because dartssh2 omits it, and an upgrade
      // that started printing it fails here. Asserting it as "the log did not
      // scrub" instead — which is how this read until now — pinned the same
      // fact by forbidding a scrub, so adding one later would have failed a
      // test whose subject is the library, not us.
      expect(
        raw,
        isNot(contains('hunter2')),
        reason: 'dartssh2 has started printing the password in '
            'SSH_Message_Userauth_Request.toString(). This is a dependency '
            'change, not a redaction regression: scrub it at capture in '
            'SshConnectionLog, or hold the previous dartssh2, before '
            'upgrading.',
      );

      final log = SshConnectionLog();
      log.add('-> sock: $raw');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('deploy'));
    });

    test('the real password change carries neither password', () {
      // The third secret-bearing message, and the one 3.1.0 touched: its
      // decoder had swapped the old and new password (#207). The client
      // sends it when a server answers a password login with a change
      // request, and it carries two credentials at once. Asserted on the
      // message itself for the same reason as the password request above.
      final raw = '${SSH_Message_Userauth_Request.newPassword(
        user: 'deploy',
        oldPassword: 'old-hunter2',
        newPassword: 'new-hunter3',
      )}';
      expect(
        raw,
        allOf(isNot(contains('old-hunter2')), isNot(contains('new-hunter3'))),
        reason: 'dartssh2 has started printing a password in '
            'SSH_Message_Userauth_Request.toString(). This is a dependency '
            'change, not a redaction regression: scrub it at capture in '
            'SshConnectionLog, or hold the previous dartssh2, before '
            'upgrading.',
      );

      final log = SshConnectionLog();
      log.add('-> sock: $raw');
      expect(log.toString(), isNot(contains('hunter')));
      expect(log.toString(), contains('deploy'));
    });
  });
}
