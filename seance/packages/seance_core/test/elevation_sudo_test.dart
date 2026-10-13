// Elevation against a real sudo: the contract the strategy table rests on
// (03-ARCHITECTURE.md §8.3 and the "Elevation" row of its test plan; 04
// Appendix A, E8). It needs local accounts with specific sudoers rules, so
// every group is skipped unless its environment variables name them. The
// in-process wire fixture runs each exec as the account, without a tty, the
// way sshd runs an exec request: through `runuser` when the test runs as
// root, otherwise through `sudo -n -u` (a CI user with NOPASSWD sudo).
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

void main() {
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

        final result = await executor.run(['id', '-u'], stdin: const []);

        expect(result.stdout, '0\n');
        expect(
          link.peer.channels.single.execCommand,
          "env LC_ALL=C sudo -n -- 'id' '-u'",
        );
      });
    },
    skip: _skipWithout('SEANCE_SUDO_TEST_NOPASSWD_USER', needsPassword: false),
  );
}

/// The command prefix that runs a process as [user] without a tty.
Future<List<String>> _asUser(String user) async {
  final uid = await Process.run('id', ['-u']);
  return (uid.stdout as String).trim() == '0'
      ? ['runuser', '-u', user, '--']
      : ['sudo', '-n', '-u', user, '--'];
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

Future<List<int>> _collect(Stream<List<int>> stream) =>
    stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
