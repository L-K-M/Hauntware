// Elevation (F2b) without a real sudo: the D24 prelude's exact bytes, rung
// selection over the probe, the rejection-text classifier, and the executor
// against the in-process wire fixture. The end-to-end group runs what the
// executor sends through local shells with a fake sudo that, like real sudo
// without a tty, keys its cached credential to the parent PID, so the
// prelude's shell semantics (03-ARCHITECTURE.md §8.3; 04 Appendix A, E6 and
// E8) run for real. The real-sudo contract is elevation_sudo_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/ssh/elevation.dart';
import 'package:test/test.dart';

import 'support/local_shells.dart';
import 'support/ssh_channel_peer.dart';

const _sudoVersion = 'Sudo version 1.9.15p5';
const _password = 'correct horse';

const _passwordSudo = ElevationProbe(
  sudoVersionLine: _sudoVersion,
  printfIsBuiltin: true,
);
const _nopasswdSudo = ElevationProbe(
  sudoVersionLine: _sudoVersion,
  sudoNopasswd: true,
  printfIsBuiltin: true,
);

/// sudo 1.9.15p5's stderr for a wrong password through the prelude and for
/// `sudo -n` without a cached credential, as 04 Appendix A, E8 recorded.
const _e8WrongPassword =
    'Sorry, try again.\n'
    'sudo: no password was provided\n'
    'sudo: 1 incorrect password attempt\n';
const _e8PasswordRequired = 'sudo: a password is required\n';

/// Words that must reach the elevated program intact; several would run
/// `touch pwned` if any quoting layer broke.
const _hostileWords = [
  '',
  "'",
  r'\',
  r'$(touch pwned)',
  '`touch pwned`',
  "'; touch pwned; '",
  'line one\nline two',
  'café',
  '-n',
  '--',
];

typedef _Reply = ({int exit, String stdout, String stderr});

/// Answers successive execs with [replies], each once the client sealed its
/// stdin when [afterStdin] (the prelude rungs always send stdin), otherwise
/// at once.
void Function(SshPeerChannel, String) _answers(
  List<_Reply> replies, {
  bool afterStdin = true,
  Duration delay = Duration.zero,
}) {
  var next = 0;
  return (channel, command) {
    final reply = replies[next++];
    void send(SshPeerChannel c) {
      Timer(delay, () {
        if (reply.stdout.isNotEmpty) c.sendData(utf8.encode(reply.stdout));
        if (reply.stderr.isNotEmpty) c.sendStderr(utf8.encode(reply.stderr));
        c
          ..sendExitStatus(reply.exit)
          ..sendEof()
          ..sendClose();
      });
    }

    if (afterStdin) {
      channel.onStdinEof = send;
    } else {
      send(channel);
    }
  };
}

_Reply _reply({int exit = 0, String stdout = '', String stderr = ''}) =>
    (exit: exit, stdout: stdout, stderr: stderr);

/// 03-ARCHITECTURE.md §8.3's prelude as `quoteShellWord` spells it, pinned
/// byte for byte.
final _quotedPrelude = [
  "'IFS= read -r p",
  r"""printf '"'"'%s'"\\"'n'"'"' "$p" | sudo -S -p '"'""'"' -v || exit 125""",
  'p=',
  r'sudo -n -- "$@"',
  r"exit $?'",
].join('\n');

void main() {
  group('elevationPrelude', () {
    test('is 03 §8.3 verbatim', () {
      expect(
        elevationPrelude,
        'IFS= read -r p\n'
        "printf '%s\\n' \"\$p\" | sudo -S -p '' -v || exit 125\n"
        'p=\n'
        'sudo -n -- "\$@"\n'
        'exit \$?',
      );
    });

    test('carries none of the rejected D24 variants', () {
      expect(elevationPrelude, isNot(contains('exec')));
      expect(elevationPrelude, isNot(contains('2>')));
      expect(elevationPrelude, isNot(contains('<<')));
      expect(elevationPrelude.trimRight(), endsWith(r'exit $?'));
    });
  });

  group('buildElevatedCommand', () {
    test('spells every rung exactly', () {
      const argv = ['crontab', '-'];
      final cases = <ElevationStrategy, String>{
        ElevationStrategy.root: "env LC_ALL=C 'crontab' '-'",
        ElevationStrategy.sudoNopasswd: "env LC_ALL=C sudo -n -- 'crontab' '-'",
        ElevationStrategy.doasNopasswd: "env LC_ALL=C doas -n -- 'crontab' '-'",
        ElevationStrategy.sudoPrelude:
            "env LC_ALL=C sh -c $_quotedPrelude elevate 'crontab' '-'",
        ElevationStrategy.sudoStdin:
            "env LC_ALL=C sudo -S -p '' -- 'crontab' '-'",
        ElevationStrategy.run0:
            "env LC_ALL=C run0 --no-ask-password -- 'crontab' '-'",
      };
      cases.forEach((strategy, command) {
        expect(
          buildElevatedCommand(strategy, argv),
          command,
          reason: strategy.name,
        );
      });
    });

    test('puts --no-ask-password right after systemctl', () {
      expect(
        buildElevatedCommand(ElevationStrategy.polkitSystemctl, [
          'systemctl',
          'restart',
          'nginx.service',
        ]),
        "env LC_ALL=C 'systemctl' --no-ask-password 'restart' 'nginx.service'",
      );
      expect(
        buildElevatedCommand(ElevationStrategy.polkitSystemctl, [
          '/usr/bin/systemctl',
        ]),
        "env LC_ALL=C '/usr/bin/systemctl' --no-ask-password",
      );
    });

    test('quotes every argv element with quoteShellWord', () {
      final argv = ['printf', '%s', ..._hostileWords];
      final tail = argv.map(quoteShellWord).join(' ');
      for (final strategy in ElevationStrategy.values) {
        if (strategy == ElevationStrategy.polkitSystemctl) continue;
        expect(
          buildElevatedCommand(strategy, argv),
          endsWith(' $tail'),
          reason: strategy.name,
        );
      }
    });

    test('never discards stderr', () {
      for (final strategy in ElevationStrategy.values) {
        expect(
          buildElevatedCommand(strategy, ['systemctl', 'status']),
          isNot(contains('2>')),
          reason: strategy.name,
        );
      }
    });
  });

  group('selectElevationStrategy', () {
    const sudoAbsentDoas = ElevationProbe(
      doasPresent: true,
      doasNopasswd: true,
      printfIsBuiltin: true,
    );
    final cases = <(String, ElevationProbe, List<String>, Object)>[
      (
        'root login needs no elevation',
        const ElevationProbe(
          isRoot: true,
          sudoVersionLine: _sudoVersion,
          sudoNopasswd: true,
          printfIsBuiltin: true,
        ),
        ['id'],
        ElevationStrategy.root,
      ),
      ('NOPASSWD sudo', _nopasswdSudo, ['id'], ElevationStrategy.sudoNopasswd),
      (
        'NOPASSWD doas when sudo is absent',
        sudoAbsentDoas,
        ['id'],
        ElevationStrategy.doasNopasswd,
      ),
      (
        'password sudo outranks NOPASSWD doas',
        const ElevationProbe(
          sudoVersionLine: _sudoVersion,
          doasPresent: true,
          doasNopasswd: true,
          printfIsBuiltin: true,
        ),
        ['id'],
        ElevationStrategy.sudoPrelude,
      ),
      ('password sudo', _passwordSudo, ['id'], ElevationStrategy.sudoPrelude),
      (
        'password sudo-rs',
        const ElevationProbe(
          sudoVersionLine: 'sudo-rs 0.2.13',
          sudoIsRs: true,
          printfIsBuiltin: true,
        ),
        ['id'],
        ElevationStrategy.sudoPrelude,
      ),
      (
        'no builtin printf skips the prelude and falls to run0',
        const ElevationProbe(
          sudoVersionLine: _sudoVersion,
          run0Present: true,
          run0Nopasswd: true,
        ),
        ['id'],
        ElevationStrategy.run0,
      ),
      (
        'no builtin printf and nothing else is unavailable',
        const ElevationProbe(sudoVersionLine: _sudoVersion),
        ['id'],
        ElevationFailureKind.unavailable,
      ),
      (
        'run0 that needs a password is not used',
        const ElevationProbe(run0Present: true),
        ['id'],
        ElevationFailureKind.unavailable,
      ),
      (
        'systemctl under polkit as the last rung',
        const ElevationProbe(run0Present: true),
        ['systemctl', 'restart', 'nginx.service'],
        ElevationStrategy.polkitSystemctl,
      ),
      (
        'systemctl by path under polkit',
        const ElevationProbe(),
        ['/usr/bin/systemctl', 'restart', 'nginx.service'],
        ElevationStrategy.polkitSystemctl,
      ),
      (
        'doas with a password needs the PTY rung (S3)',
        const ElevationProbe(doasPresent: true, printfIsBuiltin: true),
        ['id'],
        ElevationFailureKind.ttyRequired,
      ),
      (
        'doas with a password still reaches polkit for systemctl',
        const ElevationProbe(doasPresent: true),
        ['systemctl', 'restart', 'nginx.service'],
        ElevationStrategy.polkitSystemctl,
      ),
      (
        'nothing at all',
        const ElevationProbe(printfIsBuiltin: true),
        ['id'],
        ElevationFailureKind.unavailable,
      ),
    ];

    for (final (description, probe, argv, expected) in cases) {
      test(description, () {
        if (expected is ElevationStrategy) {
          expect(selectElevationStrategy(probe, argv), expected);
          return;
        }
        expect(
          () => selectElevationStrategy(probe, argv),
          throwsA(
            isA<ElevationException>()
                .having((e) => e.kind, 'kind', expected)
                .having((e) => e.stderr, 'stderr', isEmpty),
          ),
        );
      });
    }
  });

  group('classifyElevationStderr', () {
    test('recognises the E8 recordings', () {
      expect(
        classifyElevationStderr(_e8WrongPassword, ElevationTool.sudo),
        ElevationFailureKind.wrongPassword,
      );
      expect(
        classifyElevationStderr(_e8PasswordRequired, ElevationTool.sudo),
        ElevationFailureKind.passwordRequired,
      );
    });

    test('recognises sudo policy, tty and attempt-count texts', () {
      final cases = <String, ElevationFailureKind>{
        'lukas is not in the sudoers file.  This incident will be reported.':
            ElevationFailureKind.notInSudoers,
        'sudo: lukas is not in the sudoers file.':
            ElevationFailureKind.notInSudoers,
        'Sorry, user lukas may not run sudo on web1.':
            ElevationFailureKind.notInSudoers,
        "Sorry, user lukas is not allowed to execute '/usr/bin/id' as root "
                'on web1.':
            ElevationFailureKind.notInSudoers,
        'sudo: sorry, you must have a tty to run sudo':
            ElevationFailureKind.ttyRequired,
        'sudo: 3 incorrect password attempts':
            ElevationFailureKind.wrongPassword,
      };
      cases.forEach((stderr, kind) {
        expect(
          classifyElevationStderr(stderr, ElevationTool.sudo),
          kind,
          reason: stderr,
        );
      });
    });

    test('adds the sudo-rs texts only for sudo-rs', () {
      final cases = <String, ElevationFailureKind>{
        'sudo-rs: Authentication failed, try again.':
            ElevationFailureKind.wrongPassword,
        'sudo-rs: Maximum 3 incorrect authentication attempts':
            ElevationFailureKind.wrongPassword,
        "sudo-rs: I'm sorry lukas. I'm afraid I can't do that":
            ElevationFailureKind.notInSudoers,
        'sudo: interactive authentication is required':
            ElevationFailureKind.passwordRequired,
      };
      cases.forEach((stderr, kind) {
        expect(
          classifyElevationStderr(stderr, ElevationTool.sudoRs),
          kind,
          reason: stderr,
        );
        expect(
          classifyElevationStderr(stderr, ElevationTool.sudo),
          isNull,
          reason: 'classic sudo never prints $stderr',
        );
      });
      // sudo's own spellings still count under sudo-rs.
      expect(
        classifyElevationStderr(_e8WrongPassword, ElevationTool.sudoRs),
        ElevationFailureKind.wrongPassword,
      );
    });

    test('anchors doas and polkit texts to whole lines', () {
      expect(
        classifyElevationStderr(
          'doas: Authorization required',
          ElevationTool.doas,
        ),
        ElevationFailureKind.passwordRequired,
      );
      expect(
        classifyElevationStderr(
          'doas: Operation not permitted',
          ElevationTool.doas,
        ),
        ElevationFailureKind.notInSudoers,
      );
      expect(
        classifyElevationStderr(
          "chown: changing ownership of '/x': Operation not permitted",
          ElevationTool.doas,
        ),
        isNull,
      );
      expect(
        classifyElevationStderr(
          'Failed to restart nginx.service: Interactive authentication '
          'required.\n'
          "See system logs and 'systemctl status nginx.service' for details.",
          ElevationTool.polkit,
        ),
        ElevationFailureKind.unavailable,
      );
      expect(
        classifyElevationStderr(
          'Failed to restart nginx.service: Unit nginx.service not found.',
          ElevationTool.polkit,
        ),
        isNull,
      );
    });

    test('prefers the most decisive kind and tolerates CRLF', () {
      expect(
        classifyElevationStderr(
          'Sorry, try again.\r\nlukas is not in the sudoers file.\r\n',
          ElevationTool.sudo,
        ),
        ElevationFailureKind.notInSudoers,
      );
    });

    test('returns null for unrelated or empty stderr', () {
      for (final stderr in ['', '\n', 'crontab: installing new crontab']) {
        expect(classifyElevationStderr(stderr, ElevationTool.sudo), isNull);
      }
    });
  });

  group('ElevatedExecutor against the wire fixture', () {
    test(
      'a root login runs the argv as it is and never sends the password',
      () async {
        final link = await openTestLink();
        addTearDown(link.link.close);
        link.peer.onExec = _answers([_reply(stdout: '0\n')], afterStdin: false);
        final executor = ElevatedExecutor(
          link.link,
          const ElevationProbe(isRoot: true),
        );

        final result = await executor.run(['id', '-u'], password: _password);

        expect(result.stdout, '0\n');
        final channel = link.peer.channels.single;
        expect(channel.execCommand, "env LC_ALL=C 'id' '-u'");
        expect(channel.stdinBytes, isEmpty);
      },
    );

    test(
      'NOPASSWD sudo passes stdin through without a password line',
      () async {
        final link = await openTestLink();
        addTearDown(link.link.close);
        link.peer.onExec = _answers([_reply()]);
        final executor = ElevatedExecutor(link.link, _nopasswdSudo);

        await executor.run(
          ['crontab', '-'],
          password: _password,
          stdin: utf8.encode('0 3 * * * true\n'),
        );

        final channel = link.peer.channels.single;
        expect(channel.execCommand, "env LC_ALL=C sudo -n -- 'crontab' '-'");
        expect(utf8.decode(channel.stdinBytes), '0 3 * * * true\n');
      },
    );

    test('NOPASSWD that no longer applies is a typed refusal', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(exit: 1, stderr: _e8PasswordRequired),
      ], afterStdin: false);
      final executor = ElevatedExecutor(link.link, _nopasswdSudo);

      await expectLater(
        executor.run(['id']),
        throwsA(
          isA<ElevationException>()
              .having(
                (e) => e.kind,
                'kind',
                ElevationFailureKind.passwordRequired,
              )
              .having((e) => e.stderr, 'stderr', _e8PasswordRequired),
        ),
      );
      expect(link.peer.channels, hasLength(1));
    });

    test(
      'a command failing on its own is returned, not reclassified',
      () async {
        final link = await openTestLink();
        addTearDown(link.link.close);
        link.peer.onExec = _answers([
          _reply(exit: 1, stderr: 'Unit nginx.service not found.\n'),
        ], afterStdin: false);
        final executor = ElevatedExecutor(link.link, _nopasswdSudo);

        final result = await executor.run(['systemctl', 'restart', 'nginx']);

        expect(result.exitCode, 1);
        expect(result.stderr, 'Unit nginx.service not found.\n');
      },
    );

    test('the prelude frames the password as the first stdin line', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([_reply(stdout: 'installed\n')]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      final result = await executor.run(
        ['crontab', '-'],
        password: _password,
        stdin: utf8.encode('0 3 * * * true\n'),
      );

      expect(result.stdout, 'installed\n');
      final channel = link.peer.channels.single;
      expect(
        channel.execCommand,
        "env LC_ALL=C sh -c $_quotedPrelude elevate 'crontab' '-'",
      );
      expect(utf8.decode(channel.stdinBytes), '$_password\n0 3 * * * true\n');
      expect(channel.eofFromClient, isTrue);
      expect(channel.execCommand, isNot(contains(_password)));
    });

    test('the prelude without stdin still seals the password line', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([_reply()]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      await executor.run(['true'], password: _password);

      final channel = link.peer.channels.single;
      expect(utf8.decode(channel.stdinBytes), '$_password\n');
      expect(channel.eofFromClient, isTrue);
    });

    test('exit 125 with the E8 texts is a wrong password', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(
          exit: ElevatedExecutor.passwordRejectedExit,
          stderr: _e8WrongPassword,
        ),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      await expectLater(
        executor.run(['id'], password: 'wrong'),
        throwsA(
          isA<ElevationException>()
              .having((e) => e.kind, 'kind', ElevationFailureKind.wrongPassword)
              .having((e) => e.stderr, 'stderr', _e8WrongPassword),
        ),
      );
      expect(link.peer.channels, hasLength(1));
    });

    test('exit 125 without a sudo text is the command\'s own status', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(exit: 125, stderr: 'docker: error during connect\n'),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      final result = await executor.run(['docker', 'ps'], password: _password);

      expect(result.exitCode, 125);
      expect(result.stderr, 'docker: error during connect\n');
    });

    test('exit 125 after stdout is the command\'s own status', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(exit: 125, stdout: 'partial\n', stderr: 'Sorry, try again.\n'),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      final result = await executor.run(['tool'], password: _password);

      expect(result.exitCode, 125);
      expect(result.stdout, 'partial\n');
    });

    test('requiretty is reported as ttyRequired', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(
          exit: ElevatedExecutor.passwordRejectedExit,
          stderr: 'sudo: sorry, you must have a tty to run sudo\n',
        ),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      await expectLater(
        executor.run(['id'], password: _password),
        throwsA(
          isA<ElevationException>().having(
            (e) => e.kind,
            'kind',
            ElevationFailureKind.ttyRequired,
          ),
        ),
      );
    });

    test('a policy refusal of the command is notInSudoers', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(
          exit: 1,
          stderr:
              "Sorry, user lukas is not allowed to execute '/usr/bin/id' as "
              'root on web1.\n',
        ),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      await expectLater(
        executor.run(['id'], password: _password),
        throwsA(
          isA<ElevationException>().having(
            (e) => e.kind,
            'kind',
            ElevationFailureKind.notInSudoers,
          ),
        ),
      );
      expect(link.peer.channels, hasLength(1));
    });

    test('rung 4 retries once with sudo -S when nothing is cached', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(
          exit: 1,
          stderr:
              'sudo: unable to resolve host web1: Name or service not known\n'
              '$_e8PasswordRequired',
        ),
        _reply(stdout: 'done\n'),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      final result = await executor.run(
        ['tee', '/etc/motd'],
        password: _password,
        stdin: utf8.encode('hello\n'),
      );

      expect(result.stdout, 'done\n');
      final [first, retry] = link.peer.channels;
      expect(first.execCommand, contains('sh -c '));
      expect(
        retry.execCommand,
        "env LC_ALL=C sudo -S -p '' -- 'tee' '/etc/motd'",
      );
      expect(utf8.decode(retry.stdinBytes), '$_password\nhello\n');
      expect(retry.execCommand, isNot(contains(_password)));
    });

    test('rung 4 reports a second refusal instead of retrying again', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(exit: 1, stderr: _e8PasswordRequired),
        _reply(exit: 1, stderr: _e8WrongPassword),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      await expectLater(
        executor.run(['id'], password: _password),
        throwsA(
          isA<ElevationException>().having(
            (e) => e.kind,
            'kind',
            ElevationFailureKind.wrongPassword,
          ),
        ),
      );
      expect(link.peer.channels, hasLength(2));
    });

    test('mixed stderr does not trigger the retry', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(exit: 1, stderr: 'backup: starting\n$_e8PasswordRequired'),
      ]);
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      await expectLater(
        executor.run(['backup'], password: _password),
        throwsA(
          isA<ElevationException>().having(
            (e) => e.kind,
            'kind',
            ElevationFailureKind.passwordRequired,
          ),
        ),
      );
      // The retry would run the command a second time; it never opened.
      expect(link.peer.channels, hasLength(1));
    });

    test('one deadline bounds the first attempt and the retry', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      var execs = 0;
      final answerFirst = _answers([
        _reply(exit: 1, stderr: _e8PasswordRequired),
      ], delay: const Duration(milliseconds: 500));
      link.peer.onExec = (channel, command) {
        // The retry stalls; only the remaining budget may bound it.
        if (execs++ == 0) answerFirst(channel, command);
      };
      final executor = ElevatedExecutor(link.link, _passwordSudo);

      final stopwatch = Stopwatch()..start();
      await expectLater(
        executor.run(
          ['id'],
          password: _password,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<RemoteCommandException>()),
      );
      expect(execs, 2);
      // A fresh full timeout for the retry would take at least 1.5 s.
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1400)));
    });

    test(
      'password sudo without a password refuses before any channel',
      () async {
        final link = await openTestLink();
        addTearDown(link.link.close);
        final executor = ElevatedExecutor(link.link, _passwordSudo);

        await expectLater(
          executor.run(['id']),
          throwsA(
            isA<ElevationException>()
                .having(
                  (e) => e.kind,
                  'kind',
                  ElevationFailureKind.passwordRequired,
                )
                .having((e) => e.stderr, 'stderr', isEmpty),
          ),
        );
        expect(link.peer.channels, isEmpty);
      },
    );

    test('no applicable rung refuses before any channel', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      final executor = ElevatedExecutor(link.link, const ElevationProbe());

      await expectLater(
        executor.run(['id'], password: _password),
        throwsA(
          isA<ElevationException>().having(
            (e) => e.kind,
            'kind',
            ElevationFailureKind.unavailable,
          ),
        ),
      );
      expect(link.peer.channels, isEmpty);
    });

    test('polkit refusing systemctl is unavailable', () async {
      final link = await openTestLink();
      addTearDown(link.link.close);
      link.peer.onExec = _answers([
        _reply(
          exit: 1,
          stderr:
              'Failed to restart nginx.service: Interactive authentication '
              'required.\n',
        ),
      ], afterStdin: false);
      final executor = ElevatedExecutor(link.link, const ElevationProbe());

      await expectLater(
        executor.run(['systemctl', 'restart', 'nginx.service']),
        throwsA(
          isA<ElevationException>().having(
            (e) => e.kind,
            'kind',
            ElevationFailureKind.unavailable,
          ),
        ),
      );
      expect(
        link.peer.channels.single.execCommand,
        "env LC_ALL=C 'systemctl' --no-ask-password 'restart' 'nginx.service'",
      );
    });

    test(
      'rejects input that cannot be sent safely, before any channel',
      () async {
        final link = await openTestLink();
        addTearDown(link.link.close);
        final executor = ElevatedExecutor(link.link, _passwordSudo);

        for (final argv in [
          <String>[],
          [''],
          ['FOO=bar', 'id'],
          ['id', 'a\u0000b'],
        ]) {
          await expectLater(
            executor.run(argv, password: _password),
            throwsArgumentError,
            reason: '$argv',
          );
        }
        for (final password in [
          'two\nlines',
          'carriage\rreturn',
          'nul\u0000',
        ]) {
          await expectLater(
            executor.run(['id'], password: password),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.toString(),
                'message',
                isNot(contains(password)),
              ),
            ),
          );
        }
        expect(link.peer.channels, isEmpty);
      },
    );
  });

  group('end to end through local shells and a fake sudo', () {
    late Directory root;
    late String fakeBin;
    late String bashAsSh;

    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('seance-elevation-');
      fakeBin = '${root.path}/bin';
      await Directory(fakeBin).create();
      await File('$fakeBin/sudo').writeAsString(_fakeSudo);
      final chmod = await Process.run('chmod', ['755', '$fakeBin/sudo']);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
      bashAsSh = '${root.path}/bash-as-sh';
      await Directory(bashAsSh).create();
      final bash = _which('bash');
      if (bash != null) await Link('$bashAsSh/sh').create(bash);
    });

    tearDownAll(() => root.delete(recursive: true));

    for (final loginShell in localShells.keys) {
      for (final innerSh in const ['sh', 'bash']) {
        final label = 'login shell $loginShell, /bin/sh as $innerSh';
        final skip = _firstSkip([
          shellSkipReason(loginShell),
          shellSkipReason(innerSh),
        ]);

        Future<({TestLink link, Directory work})> open({
          bool noCache = false,
        }) async {
          final work = await root.createTemp('work-');
          final state = await root.createTemp('state-');
          final link = await openTestLink();
          addTearDown(link.link.close);
          link.peer.onExec = _execLocally(
            _which(loginShell)!,
            localShells[loginShell]!,
            workingDirectory: work.path,
            environment: {
              'PATH': [
                fakeBin,
                if (innerSh == 'bash') bashAsSh,
                Platform.environment['PATH'] ?? '',
              ].join(':'),
              'FAKE_SUDO_STATE': state.path,
              'FAKE_SUDO_PASSWORD': _password,
              if (noCache) 'FAKE_SUDO_NO_CACHE': '1',
            },
          );
          return (link: link, work: work);
        }

        const script =
            r'printf "[%s]" "$@"; printf "\n%s\n" "$ELEVATED_BY"; cat';
        final argv = ['sh', '-c', script, 'elevated', ..._hostileWords];
        final expectedArgs = _hostileWords.map((w) => '[$w]').join();

        test('$label: the prelude elevates and the command reads the rest '
            'of stdin', () async {
          final (:link, :work) = await open();
          final executor = ElevatedExecutor(link.link, _passwordSudo);

          final result = await executor.run(
            argv,
            password: _password,
            stdin: utf8.encode('first\nsecond\n'),
          );

          expect(result.stderr, isEmpty);
          expect(result.exitCode, 0);
          expect(result.stdout, '$expectedArgs\nfake-sudo\nfirst\nsecond\n');
          expect(link.peer.channels, hasLength(1));
          expect(work.listSync(), isEmpty, reason: 'a quoted word ran');
        }, skip: skip);

        test('$label: a wrong password exits 125 with the E8 texts', () async {
          final (:link, work: _) = await open();
          final executor = ElevatedExecutor(link.link, _passwordSudo);

          await expectLater(
            executor.run(argv, password: 'wrong', stdin: utf8.encode('x\n')),
            throwsA(
              isA<ElevationException>()
                  .having(
                    (e) => e.kind,
                    'kind',
                    ElevationFailureKind.wrongPassword,
                  )
                  .having((e) => e.stderr, 'stderr', _e8WrongPassword),
            ),
          );
        }, skip: skip);

        test('$label: without a cached credential rung 4 runs the command '
            'once', () async {
          final (:link, work: _) = await open(noCache: true);
          final executor = ElevatedExecutor(link.link, _passwordSudo);

          final result = await executor.run(
            argv,
            password: _password,
            stdin: utf8.encode('first\nsecond\n'),
          );

          expect(result.stdout, '$expectedArgs\nfake-sudo\nfirst\nsecond\n');
          final [prelude, retry] = link.peer.channels;
          expect(prelude.execCommand, contains('sh -c '));
          expect(retry.execCommand, contains("sudo -S -p '' -- "));
        }, skip: skip);
      }
    }

    // The fake is only worth the tests above if it fails the way E6 and E8
    // saw real sudo fail.
    test('the fake sudo reproduces E8: bash execs a last sudo -n', () async {
      final noExit = elevationPrelude.replaceFirst('\nexit \$?', '');
      final result = await _runWithFakeSudo(root, fakeBin, [
        'bash',
        '-c',
        noExit,
        'elevate',
        'cat',
      ]);
      expect(result.exitCode, 1);
      expect(result.stderr, _e8PasswordRequired);
    }, skip: shellSkipReason('bash'));

    test(
      'the fake sudo reproduces E8: exec sudo -n loses the credential',
      () async {
        final exec = elevationPrelude.replaceFirst(
          'sudo -n --',
          'exec sudo -n --',
        );
        final result = await _runWithFakeSudo(root, fakeBin, [
          'sh',
          '-c',
          exec,
          'elevate',
          'cat',
        ]);
        expect(result.exitCode, 1);
        expect(result.stderr, _e8PasswordRequired);
      },
      skip: shellSkipReason('sh'),
    );
  });
}

/// A stand-in for sudo 1.9 without a tty: `-S` reads exactly one password
/// line; a successful validation leaves a credential keyed to the parent
/// PID, which `-n` then needs; refusals print the E8 texts. The command runs
/// unprivileged with `ELEVATED_BY=fake-sudo` so tests can see it went
/// through here. `FAKE_SUDO_NO_CACHE=1` plays `timestamp_timeout=0`.
const _fakeSudo = r'''#!/bin/sh
stdin_password=0; validate=0
while [ $# -gt 0 ]; do
  case $1 in
    -S) stdin_password=1 ;;
    -p) shift ;;
    -v) validate=1 ;;
    -n) ;;
    --) shift; break ;;
    *) break ;;
  esac
  shift
done
record="$FAKE_SUDO_STATE/ts.$PPID"
if [ "$stdin_password" = 1 ]; then
  IFS= read -r given || given=
  if [ "$given" != "$FAKE_SUDO_PASSWORD" ]; then
    echo 'Sorry, try again.' >&2
    echo 'sudo: no password was provided' >&2
    echo 'sudo: 1 incorrect password attempt' >&2
    exit 1
  fi
  [ "$FAKE_SUDO_NO_CACHE" = 1 ] || : > "$record"
  [ "$validate" = 1 ] && exit 0
elif [ ! -e "$record" ]; then
  echo 'sudo: a password is required' >&2
  exit 1
fi
export ELEVATED_BY=fake-sudo
exec "$@"
''';

/// Answers an exec the way sshd does: once the client sealed its stdin, the
/// command line goes to [loginShell] `-c` with the bytes the client sent,
/// and its output and status go back over the channel.
void Function(SshPeerChannel, String) _execLocally(
  String loginShell,
  List<String> loginShellFlags, {
  required String workingDirectory,
  required Map<String, String> environment,
}) {
  return (channel, command) {
    channel.onStdinEof = (c) => unawaited(() async {
      final process = await Process.start(
        loginShell,
        [...loginShellFlags, command],
        workingDirectory: workingDirectory,
        environment: environment,
      );
      final stdout = _collect(process.stdout);
      final stderr = _collect(process.stderr);
      process.stdin.done.ignore();
      process.stdin.add(c.stdinBytes);
      try {
        await process.stdin.close();
      } on Object {
        // A refused prelude exits before reading the rest of its stdin.
      }
      final exitCode = await process.exitCode;
      final out = await stdout;
      final err = await stderr;
      if (out.isNotEmpty) c.sendData(out);
      if (err.isNotEmpty) c.sendStderr(err);
      c
        ..sendExitStatus(exitCode)
        ..sendEof()
        ..sendClose();
    }());
  };
}

/// Runs [argv] locally with the fake sudo first on PATH, feeding it a
/// correct password line.
Future<ProcessResult> _runWithFakeSudo(
  Directory root,
  String fakeBin,
  List<String> argv,
) async {
  final state = await root.createTemp('state-');
  final process = await Process.start(
    argv.first,
    argv.skip(1).toList(),
    environment: {
      'PATH': '$fakeBin:${Platform.environment['PATH'] ?? ''}',
      'FAKE_SUDO_STATE': state.path,
      'FAKE_SUDO_PASSWORD': _password,
    },
  );
  final stdout = _collect(process.stdout);
  final stderr = _collect(process.stderr);
  process.stdin.done.ignore();
  process.stdin.add(utf8.encode('$_password\nrest\n'));
  try {
    await process.stdin.close();
  } on Object {
    // The failing variants exit before reading all of stdin.
  }
  final exitCode = await process.exitCode;
  return ProcessResult(
    process.pid,
    exitCode,
    utf8.decode(await stdout),
    utf8.decode(await stderr),
  );
}

Future<List<int>> _collect(Stream<List<int>> stream) =>
    stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));

String? _which(String program) {
  for (final directory in (Platform.environment['PATH'] ?? '').split(':')) {
    if (directory.isEmpty) continue;
    final candidate = '$directory/$program';
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

Object _firstSkip(List<Object> reasons) =>
    reasons.firstWhere((reason) => reason != false, orElse: () => false);
