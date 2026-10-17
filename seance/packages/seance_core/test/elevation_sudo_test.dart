// Elevation against a real sudo: the contract the strategy table rests on
// (03-ARCHITECTURE.md §8.3 and the "Elevation" row of its test plan; 04
// Appendix A, E8). It needs local accounts with specific sudoers rules, so
// every group is skipped unless its environment variables name them. The
// in-process wire fixture runs each exec as the account, without a tty, the
// way sshd runs an exec request: in a new session through `setsid`, then
// `runuser` when the test runs as root, otherwise `sudo -n -u` (a CI user
// with NOPASSWD sudo). The `start` cases use a peer that starts each exec
// at once and streams stdin to it as it arrives, as sshd does.
//
//   SEANCE_SUDO_TEST_USER           password sudo: `<user> ALL=(ALL) ALL`
//   SEANCE_SUDO_TEST_PASSWORD       the password of the two accounts below
//   SEANCE_SUDO_TEST_NOCACHE_USER   optional, password sudo plus
//                                   `Defaults:<user> timestamp_timeout=0`
//   SEANCE_SUDO_TEST_NOPASSWD_USER  optional, `<user> ALL=(ALL) NOPASSWD: ALL`
@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

final _environment = Platform.environment;
final _password = _environment['SEANCE_SUDO_TEST_PASSWORD'] ?? '';

String? _account(String variable) {
  final value = _environment[variable];
  return value == null || value.isEmpty ? null : value;
}

Object _skipWithout(String variable, {bool needsPassword = true}) {
  if (_account(variable) == null) return '$variable is not set';
  if (needsPassword && _password.isEmpty) {
    return 'SEANCE_SUDO_TEST_PASSWORD is not set';
  }
  return false;
}

/// Any configured account, for checks of the fixture itself.
final _anyAccount =
    _account('SEANCE_SUDO_TEST_USER') ??
    _account('SEANCE_SUDO_TEST_NOCACHE_USER') ??
    _account('SEANCE_SUDO_TEST_NOPASSWD_USER');

void main() {
  group('the wire fixture', () {
    // Without this, a run from a terminal lets sudo key its cached
    // credential to that terminal instead of the parent PID, which hides
    // what the prelude exists for and lets a wrong password pass.
    test('runs each exec without a controlling terminal', () async {
      final (link: link, exits: _) = await _openAs(_anyAccount!);

      final result = await link.link.run(
        'if (exec 3</dev/tty) 2>/dev/null; then echo tty; else echo none; fi',
        stdin: const [],
      );

      expect(result.stdout, 'none\n');
    });
  }, skip: _anyAccount == null ? 'no SEANCE_SUDO_TEST_*_USER is set' : false);

  group('password sudo', () {
    test('the probe sees password sudo and a builtin printf', () async {
      final probe = await _probe(_account('SEANCE_SUDO_TEST_USER')!);

      expect(probe.sudoVersionLine, isNotNull);
      expect(probe.sudoNopasswd, isFalse);
      expect(probe.printfIsBuiltin, isTrue);
    });

    test(
      'the prelude elevates and the command reads the rest of stdin',
      () async {
        final user = _account('SEANCE_SUDO_TEST_USER')!;
        final (link: link, exits: exits) = await _openAs(user);
        final executor = ElevatedExecutor(link.link, await _probe(user));

        final result = await executor.run(
          ['sh', '-c', 'id -u; cat'],
          password: _password,
          stdin: utf8.encode('first\nsecond\n'),
        );

        expect(result.stdout, '0\nfirst\nsecond\n');
        expect(result.exitCode, 0);
        expect(exits, [0]);
        expect(link.peer.channels.single.execCommand, contains('sh -c '));
      },
    );

    test('a wrong password exits 125 with the recorded texts', () async {
      final user = _account('SEANCE_SUDO_TEST_USER')!;
      final (link: link, exits: exits) = await _openAs(user);
      final executor = ElevatedExecutor(link.link, await _probe(user));

      await expectLater(
        executor.run(
          ['id', '-u'],
          password: '$_password-wrong',
          stdin: const [],
        ),
        throwsA(
          isA<ElevationException>()
              .having((e) => e.kind, 'kind', ElevationFailureKind.wrongPassword)
              .having(
                (e) => e.stderr,
                'stderr',
                allOf(
                  contains('Sorry, try again.'),
                  contains('incorrect password attempt'),
                ),
              ),
        ),
      );
      expect(exits, [ElevatedExecutor.passwordRejectedExit]);
    });

    test(
      'start: the prelude streams stdin to the command as it arrives',
      () async {
        final user = _account('SEANCE_SUDO_TEST_USER')!;
        final (link: link, exits: exits) = await _streamAs(user);
        final executor = ElevatedExecutor(link.link, await _probe(user));

        final process = await executor.start([
          'sh',
          '-c',
          _echoLines,
        ], password: _password);
        final output = _Output(process);

        await output.waitFor('0\n');
        expect(await process.refusal, isNull);
        // The command answers each line while its stdin is still open.
        process.stdin.add(utf8.encode('one\n'));
        await output.waitFor('0\ngot one\n');
        process.stdin.add(utf8.encode('two\n'));
        await output.waitFor('0\ngot one\ngot two\n');
        await process.stdin.close();

        expect((await process.exit).exitCode, 0);
        expect(exits, [0]);
        expect(link.peer.channels.single.execCommand, contains('sh -c '));
      },
    );

    test(
      'start: a wrong password is a refusal with the recorded texts',
      () async {
        final user = _account('SEANCE_SUDO_TEST_USER')!;
        final (link: link, exits: exits) = await _streamAs(user);
        final executor = ElevatedExecutor(link.link, await _probe(user));

        final process = await executor.start([
          'id',
          '-u',
        ], password: '$_password-wrong');

        expect(
          await process.refusal,
          isA<ElevationException>()
              .having((e) => e.kind, 'kind', ElevationFailureKind.wrongPassword)
              .having(
                (e) => e.stderr,
                'stderr',
                contains('incorrect password attempt'),
              ),
        );
        expect(
          (await process.exit).exitCode,
          ElevatedExecutor.passwordRejectedExit,
        );
        expect(exits, [ElevatedExecutor.passwordRejectedExit]);
      },
    );

    test('start nopasswdFirst: sudo -n asks for a password, the prelude '
        'follows and gets the stdin sudo -n never read', () async {
      final user = _account('SEANCE_SUDO_TEST_USER')!;
      final (link: link, exits: exits) = await _streamAs(user);
      final executor = ElevatedExecutor(link.link, await _probe(user));

      final process = await executor.start(
        ['sh', '-c', _echoLines],
        password: _password,
        attempt: ElevationAttempt.nopasswdFirst,
      );
      final output = _Output(process);
      process.stdin.add(utf8.encode('early\n'));

      await output.waitFor('0\ngot early\n');
      expect(await process.refusal, isNull);
      process.stdin.add(utf8.encode('late\n'));
      await output.waitFor('0\ngot early\ngot late\n');
      await process.stdin.close();

      expect((await process.exit).exitCode, 0);
      expect(exits, [1, 0]);
      final [sudoN, prelude] = link.peer.channels;
      expect(sudoN.execCommand, startsWith('env LC_ALL=C sudo -n -- '));
      expect(prelude.execCommand, contains('sh -c '));
      // sudo -n's refusal was answered by the prelude, not reported.
      expect(output.stderr, isEmpty);
    });
  }, skip: _skipWithout('SEANCE_SUDO_TEST_USER'));

  group('timestamp_timeout=0', () {
    test('rung 4 runs the command once after the prelude', () async {
      final user = _account('SEANCE_SUDO_TEST_NOCACHE_USER')!;
      final (link: link, exits: exits) = await _openAs(user);
      final executor = ElevatedExecutor(link.link, await _probe(user));

      final result = await executor.run(
        ['sh', '-c', 'id -u; cat'],
        password: _password,
        stdin: utf8.encode('first\nsecond\n'),
      );

      expect(result.stdout, '0\nfirst\nsecond\n');
      expect(exits, [1, 0]);
      expect(
        link.peer.channels.last.execCommand,
        contains("sudo -S -p '' -- "),
      );
    });

    test('start: rung 4 follows the prelude and streams stdin', () async {
      final user = _account('SEANCE_SUDO_TEST_NOCACHE_USER')!;
      final (link: link, exits: exits) = await _streamAs(user);
      final executor = ElevatedExecutor(link.link, await _probe(user));

      final process = await executor.start([
        'sh',
        '-c',
        _echoLines,
      ], password: _password);
      final output = _Output(process);
      process.stdin.add(utf8.encode('early\n'));

      await output.waitFor('0\ngot early\n');
      expect(await process.refusal, isNull);
      process.stdin.add(utf8.encode('late\n'));
      await output.waitFor('0\ngot early\ngot late\n');
      await process.stdin.close();

      expect((await process.exit).exitCode, 0);
      expect(exits, [1, 0]);
      expect(
        link.peer.channels.last.execCommand,
        contains("sudo -S -p '' -- "),
      );
      expect(output.stderr, isEmpty);
    });
  }, skip: _skipWithout('SEANCE_SUDO_TEST_NOCACHE_USER'));

  group(
    'NOPASSWD sudo',
    () {
      test('runs sudo -n without a prelude', () async {
        final user = _account('SEANCE_SUDO_TEST_NOPASSWD_USER')!;
        final probe = await _probe(user);
        expect(probe.sudoNopasswd, isTrue);
        final (link: link, exits: _) = await _openAs(user);
        final executor = ElevatedExecutor(link.link, probe);

        final result = await executor.run(['id', '-u']);

        expect(result.stdout, '0\n');
        expect(
          link.peer.channels.single.execCommand,
          "env LC_ALL=C sudo -n -- 'id' '-u'",
        );
      });

      test('start: sudo -n streams stdin without a password line', () async {
        final user = _account('SEANCE_SUDO_TEST_NOPASSWD_USER')!;
        final (link: link, exits: exits) = await _streamAs(user);
        final executor = ElevatedExecutor(link.link, await _probe(user));

        final process = await executor.start([
          'sh',
          '-c',
          _echoLines,
        ], attempt: ElevationAttempt.nopasswdFirst);
        final output = _Output(process);

        await output.waitFor('0\n');
        expect(await process.refusal, isNull);
        process.stdin.add(utf8.encode('one\n'));
        await output.waitFor('0\ngot one\n');
        await process.stdin.close();

        expect((await process.exit).exitCode, 0);
        expect(exits, [0]);
        final channel = link.peer.channels.single;
        expect(channel.execCommand, startsWith('env LC_ALL=C sudo -n -- '));
        expect(utf8.decode(channel.stdinBytes), 'one\n');
      });
    },
    skip: _skipWithout('SEANCE_SUDO_TEST_NOPASSWD_USER', needsPassword: false),
  );
}

/// The command prefix that runs a process as [user] without a tty. `setsid`
/// drops the controlling terminal a run from a terminal would otherwise
/// pass on: `runuser` keeps it, and the outer sudo would open a pty.
Future<List<String>> _asUser(String user) async {
  final uid = await Process.run('id', ['-u']);
  return [
    'setsid',
    '-w',
    ...(uid.stdout as String).trim() == '0'
        ? ['runuser', '-u', user, '--']
        : ['sudo', '-n', '-u', user, '--'],
  ];
}

/// The elevation facts of the host probe (03 §6.1), gathered as [user].
Future<ElevationProbe> _probe(String user) async {
  final prefix = await _asUser(user);
  Future<ProcessResult> run(String script) => Process.run(prefix.first, [
    ...prefix.skip(1),
    'sh',
    '-c',
    script,
  ], workingDirectory: '/');

  final version = await run('sudo -V');
  final versionLine = const LineSplitter()
      .convert(version.stdout as String)
      .firstOrNull;
  final nopasswd = await run('sudo -n true');
  final printf = await run('command -V printf');
  return ElevationProbe(
    sudoVersionLine: versionLine,
    sudoIsRs: versionLine?.startsWith('sudo-rs') ?? false,
    sudoNopasswd: versionLine != null && nopasswd.exitCode == 0,
    printfIsBuiltin: (printf.stdout as String).contains('builtin'),
  );
}

/// A link whose peer runs every exec as [user] through `sh -c`, recording
/// each exit status.
Future<({TestLink link, List<int> exits})> _openAs(String user) async {
  final prefix = await _asUser(user);
  final link = await openTestLink(timeout: const Duration(seconds: 30));
  addTearDown(link.link.close);
  final exits = <int>[];
  link.peer.onExec = (channel, command) {
    channel.onStdinEof = (c) => unawaited(() async {
      final process = await Process.start(prefix.first, [
        ...prefix.skip(1),
        'sh',
        '-c',
        command,
      ], workingDirectory: '/');
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
      exits.add(exitCode);
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
  return (link: link, exits: exits);
}

/// A link whose peer starts every exec as [user] at once and streams both
/// ways, recording each exit status: stdin goes to the process as it
/// arrives, its output comes back as it is written.
Future<({TestLink link, List<int> exits})> _streamAs(String user) async {
  final prefix = await _asUser(user);
  final link = await openTestLink(timeout: const Duration(seconds: 30));
  addTearDown(link.link.close);
  final exits = <int>[];
  link.peer.onExec = (channel, command) {
    Process? process;
    final early = <int>[];
    var eof = false;
    void write(List<int> data) {
      try {
        process!.stdin.add(data);
      } on Object {
        // A refusing sudo exits before reading its stdin.
      }
    }

    channel
      ..onStdin = (_, data) {
        if (process == null) {
          early.addAll(data);
        } else {
          write(data);
        }
      }
      ..onStdinEof = (_) {
        eof = true;
        process?.stdin.close().ignore();
      };
    unawaited(() async {
      final started = await Process.start(prefix.first, [
        ...prefix.skip(1),
        'sh',
        '-c',
        command,
      ], workingDirectory: '/');
      process = started;
      started.stdin.done.ignore();
      if (early.isNotEmpty) write(early);
      if (eof) started.stdin.close().ignore();
      final stdout = started.stdout.listen(channel.sendData).asFuture<void>();
      final stderr = started.stderr.listen(channel.sendStderr).asFuture<void>();
      final exitCode = await started.exitCode;
      await Future.wait([stdout, stderr]);
      exits.add(exitCode);
      channel
        ..sendExitStatus(exitCode)
        ..sendEof()
        ..sendClose();
    }());
  };
  return (link: link, exits: exits);
}

/// Prints the uid, then answers each stdin line as it arrives.
const _echoLines = r'id -u; while IFS= read -r line; do echo "got $line"; done';

/// What an [ElevatedProcess] printed so far.
final class _Output {
  _Output(ElevatedProcess process) {
    process.stdout.listen(_stdout.addAll);
    process.stderr.listen(_stderr.addAll);
  }

  final _stdout = <int>[];
  final _stderr = <int>[];

  String get stderr => utf8.decode(_stderr);

  /// Waits, in real time since a real sudo answers, for stdout to read
  /// [expected].
  Future<void> waitFor(String expected) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (utf8.decode(_stdout, allowMalformed: true) != expected) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'stdout read ${jsonEncode(utf8.decode(_stdout))}, not '
          '${jsonEncode(expected)}; stderr ${jsonEncode(stderr)}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

Future<List<int>> _collect(Stream<List<int>> stream) =>
    stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
