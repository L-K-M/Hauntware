// `SshLink`'s exec surface against the in-process wire fixture: `run` is the
// same capture core `SshSession.runCommand` uses, and `start` is the live
// channel form. Assertions are on observed wire traffic, not on mocks.
import 'dart:async';
import 'dart:convert';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

void main() {
  group('SshLink.run', () {
    test('captures stdout and the remote exit code', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final result = await link.link.run('uname -a');

      expect(result.stdout, 'ran:uname -a\n');
      expect(result.stderr, isEmpty);
      expect(result.exitCode, 0);
      expect(result.truncated, isFalse);
      expect(result.succeeded, isTrue);
      expect(link.peer.channels.single.execCommand, 'uname -a');
    });

    test('reports a non-zero exit as data, not as a failure', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = (channel, command) {
        channel
          ..sendStderr(utf8.encode('no such file\n'))
          ..sendExitStatus(127)
          ..sendEof()
          ..sendClose();
      };

      final result = await link.link.run('missing-command');

      expect(result.exitCode, 127);
      expect(result.stderr, 'no such file\n');
      expect(result.succeeded, isFalse);
    });

    test('truncates each stream independently at the cap', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = (channel, command) {
        channel
          ..sendData(utf8.encode('0123456789'))
          ..sendStderr(utf8.encode('abcdefghij'))
          ..sendExitStatus(0)
          ..sendEof()
          ..sendClose();
      };

      final result = await link.link.run('noisy', maxOutputBytes: 4);

      expect(result.stdout, '0123');
      expect(result.stderr, 'abcd');
      expect(result.truncated, isTrue);
    });

    test('keeps draining a stream past the cap so the peer never stalls',
        () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = (channel, command) {
        channel
          ..sendData(List<int>.filled(64 * 1024, 0x61))
          ..sendExitStatus(0)
          ..sendEof()
          ..sendClose();
      };

      final result = await link.link.run('flood', maxOutputBytes: 16);

      expect(result.stdout, 'a' * 16);
      expect(result.truncated, isTrue);
      // The whole payload crossed the wire; only the capture stopped early.
      expect(link.peer.channels.single.bytesSent, greaterThan(16));
    });

    test('writes stdin and seals it with EOF', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = SshChannelPeer.execAnswerOnStdinEof;

      final result = await link.link.run(
        'cat',
        stdin: utf8.encode('payload\n'),
      );

      expect(result.stdout, 'stdin:8');
      expect(result.exitCode, 0);
      final channel = link.peer.channels.single;
      expect(utf8.decode(channel.stdinBytes), 'payload\n');
      expect(channel.eofFromClient, isTrue);
    });

    test('a stalled command aborts at the timeout', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = SshChannelPeer.execQuietFollower;

      await expectLater(
        link.link.run('tail -f', timeout: const Duration(milliseconds: 150)),
        throwsA(
          isA<RemoteCommandException>().having(
            (error) => error.message,
            'message',
            contains('did not finish within'),
          ),
        ),
      );
      // The abort closed the channel's write side instead of leaving the
      // channel open; dartssh2 answers the close only once the peer replies.
      await _eventually(() => link.peer.channels.single.eofFromClient);
    });

    test('a closed link refuses to run', () async {
      final link = await openTestLink();
      await link.link.close();

      await expectLater(
        link.link.run('echo hi'),
        throwsA(
          isA<RemoteCommandException>().having(
            (error) => error.message,
            'message',
            'The SSH link is closed.',
          ),
        ),
      );
    });
  });

  group('SshLink.start', () {
    test('reports the exit status when the command finishes', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final process = await link.link.start('true');
      final exit = await process.exit;

      expect(exit.exitCode, 0);
      expect(exit.exitSignal, isNull);
      expect(
        utf8.decode(await process.stdout.expand((c) => c).toList()),
        'ran:true\n',
      );
    });

    test('reports an exit signal instead of a status', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = (channel, command) {
        channel
          ..sendExitSignal('KILL')
          ..sendEof()
          ..sendClose();
      };

      final process = await link.link.start('boom');
      final exit = await process.exit;

      expect(exit.exitCode, isNull);
      expect(exit.exitSignal, 'KILL');
    });

    test('delivers stderr while stdout is unread', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = (channel, command) {
        channel
          ..sendStderr(utf8.encode('diagnostic\n'))
          ..sendExitStatus(3)
          ..sendEof()
          ..sendClose();
      };

      final process = await link.link.start('noisy');
      final stderr = utf8.decode(await process.stderr.expand((c) => c).toList());
      expect(stderr, 'diagnostic\n');
      expect((await process.exit).exitCode, 3);
    });

    test('requests a PTY with the given dimensions', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final process = await link.link.start(
        'bash',
        pty: const PtyRequest(cols: 132, rows: 43),
      );
      await process.exit;

      expect(link.peer.channels.single.ptyTerm, isNotNull);
      expect(link.peer.channels.single.requestsSeen, contains('pty-req'));
    });

    test('closes stdin with channel EOF while the read side stays open',
        () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = SshChannelPeer.execQuietFollower;

      final process = await link.link.start('cat');
      process.stdin.add(utf8.encode('one line\n'));
      await process.stdin.close();

      await _eventually(() => link.peer.channels.single.eofFromClient);
      expect(utf8.decode(link.peer.channels.single.stdinBytes), 'one line\n');
      // EOF is one direction: the channel is still open for the peer to answer.
      expect(link.peer.channels.single.closeFromClient, isFalse);
    });

    test('signals the process and the peer sees the signal name', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = SshChannelPeer.execQuietFollower;

      final process = await link.link.start('sleep 100');
      process.signal(RemoteSignal.usr1);

      await _eventually(
        () => link.peer.channels.single.signalsSeen.contains('USR1'),
      );
      expect(link.peer.channels.single.signalsSeen, ['USR1']);
    });

    test('signalling a finished process is a no-op', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);

      final process = await link.link.start('true');
      await process.exit;

      expect(() => process.signal(RemoteSignal.term), returnsNormally);
    });

    test('close signals TERM and tears the channel down', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = SshChannelPeer.execQuietFollower;

      final process = await link.link.start('sleep 100');
      await process.close();

      final channel = link.peer.channels.single;
      expect(channel.signalsSeen, ['TERM']);
      await _eventually(() => channel.eofFromClient);
      expect(await process.exit, isA<RemoteExit>());
    });

    test('every signal name reaches the wire unchanged', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = SshChannelPeer.execQuietFollower;

      final process = await link.link.start('sleep 100');
      for (final signal in RemoteSignal.values) {
        process.signal(signal);
      }

      await _eventually(
        () => link.peer.channels.single.signalsSeen.length ==
            RemoteSignal.values.length,
      );
      expect(link.peer.channels.single.signalsSeen, [
        'HUP',
        'INT',
        'QUIT',
        'KILL',
        'TERM',
        'USR1',
        'USR2',
      ]);
    });
  });
}

/// Waits for [condition] to hold; the fixture answers on the same event loop,
/// so a bounded number of turns is enough and no real delay is involved.
Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('The fixture never reported the expected wire traffic.');
}
