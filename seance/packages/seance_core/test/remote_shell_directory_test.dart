import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/local_shells.dart';

/// A runner that answers canned results in order and records each command.
class _FakeRunner {
  final List<String> commands = [];
  final List<Duration?> timeouts = [];
  final List<Object> answers;

  _FakeRunner(this.answers);

  RemoteCommandRunner get call => (command, {timeout}) async {
    commands.add(command);
    timeouts.add(timeout);
    if (answers.isEmpty) {
      throw StateError('No canned answer left for: $command');
    }
    final answer = answers.removeAt(0);
    if (answer is Exception) throw answer;
    return answer as RemoteCommandResult;
  };
}

RemoteCommandResult _exit(int? code, [String stdout = '']) =>
    RemoteCommandResult(stdout: stdout, exitCode: code);

/// What the script prints when it finds the shell in [path].
RemoteCommandResult _answer(String path) => _exit(0, 'seance-cwd\n$path\n');

/// Stands in for an sshd connection process: forks one PTY session leader
/// per entry of `ptys` (each in its directory, like a login shell on a PTY
/// channel; with `shells` false it stays this program, as sshd's child does
/// before it starts the shell), removes the `remove` directories, then runs
/// `argv` without a tty (like an exec channel; in a session of its own
/// unless `setsid` is false, as under Dropbear) and exits with its status.
/// Every child shares this process as its parent, as every channel of one
/// SSH connection shares sshd's.
const _connectionHarness = r'''
import json, os, sys, time
spec = json.loads(sys.argv[1])
shells = []
for cwd in spec['ptys']:
    ready_r, ready_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        report = os.dup(2)
        try:
            master, slave = os.openpty()
            name = os.ttyname(slave)
            os.setsid()
            tty = os.open(name, os.O_RDWR)  # becomes the controlling terminal
            for fd in (0, 1, 2):
                os.dup2(tty, fd)
            os.set_inheritable(master, True)
            os.chdir(cwd)
            if not spec['shells']:
                os.write(ready_w, b'.')
                time.sleep(60)
            # The pipe closes on exec, which is when the child is the shell.
            os.execvp('sleep', ['sleep', '60'])
        except BaseException as error:
            os.write(ready_w, b'!')
            os.write(report, ('PTY child: %r\n' % error).encode())
            os._exit(125)
    os.close(ready_w)
    if os.read(ready_r, 1) == b'!':
        sys.exit('the PTY child failed in %r' % cwd)
    shells.append(pid)
for cwd in spec['remove']:
    os.rmdir(cwd)
probe = os.fork()
if probe == 0:
    if spec['setsid']:
        os.setsid()
    os.execvp(spec['argv'][0], spec['argv'])
_, status = os.waitpid(probe, 0)
for pid in shells:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
sys.exit(-os.WTERMSIG(status) if os.WIFSIGNALED(status)
         else os.WEXITSTATUS(status))
''';

/// A `skip:` value for the real-process tests: they read Linux `/proc` and
/// need python3 for PTYs and sessions.
Object _harnessSkipReason() {
  if (!Platform.isLinux) return 'reads Linux /proc';
  try {
    if (Process.runSync('python3', ['-c', '']).exitCode == 0) return false;
  } on ProcessException {
    // Missing python3 throws rather than exiting non-zero.
  }
  return 'python3 is not available';
}

/// A runner that executes the probe through [shell] -c beside PTY shells
/// sitting in [ptys], the way sshd runs an exec request.
RemoteCommandRunner _besidePtyShells(
  String shell, {
  List<String> ptys = const [],
  List<String> remove = const [],
  bool shells = true,
  bool setsid = true,
  String Function(String command)? rewrite,
}) => (command, {timeout}) async {
  final spec = {
    'ptys': ptys,
    'remove': remove,
    'shells': shells,
    'setsid': setsid,
    'argv': [shell, ...localShells[shell]!, rewrite?.call(command) ?? command],
  };
  final result = await Process.run(
    'python3',
    ['-c', _connectionHarness, jsonEncode(spec)],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final stderr = result.stderr as String;
  if (stderr.isNotEmpty) printOnFailure('harness stderr: $stderr');
  return RemoteCommandResult(
    stdout: result.stdout as String,
    stderr: stderr,
    exitCode: result.exitCode,
  );
};

void main() {
  final harnessSkip = _harnessSkipReason();

  group('RemoteShellDirectory with a fake runner', () {
    test('sends one quoted sh script that every login shell keeps', () async {
      final runner = _FakeRunner([_answer('/srv')]);

      await RemoteShellDirectory(runner.call).read();

      final command = runner.commands.single;
      expect(command, startsWith("exec sh -c '"));
      expect(command, endsWith("'"));
      final script = command.substring(
        "exec sh -c '".length,
        command.length - 1,
      );
      // csh and tcsh reject a newline in quotes and expand `!`; `'` and
      // `\` would need fish-specific quoting.
      for (final unsafe in ["'", r'\', '!', '\n']) {
        expect(script, isNot(contains(unsafe)), reason: unsafe);
      }
      expect(runner.timeouts.single, isNotNull);
    });

    test('returns the printed directory', () async {
      final runner = _FakeRunner([_answer('/mnt/tank/media files')]);

      expect(
        await RemoteShellDirectory(runner.call).read(),
        '/mnt/tank/media files',
      );
    });

    test("finds the answer after a startup file's output", () async {
      final runner = _FakeRunner([
        _exit(0, 'Welcome to TrueNAS\n/etc/motd\nseance-cwd\n/mnt/tank\n'),
      ]);

      expect(await RemoteShellDirectory(runner.call).read(), '/mnt/tank');
    });

    test('does not follow a removed directory or one it cannot name', () async {
      final runner = _FakeRunner([
        _answer('/srv/old (deleted)'),
        _answer('/a\n/b'),
        _answer('/a\u001b]0;x'),
        _answer('/caf\ufffd'),
        _answer('/srv'),
      ]);
      final directory = RemoteShellDirectory(runner.call);

      for (var i = 0; i < 4; i++) {
        expect(await directory.read(), isNull);
      }
      expect(await directory.read(), '/srv');
    });

    test('asks again after a read with no answer', () async {
      final runner = _FakeRunner([_exit(4), _exit(4), _answer('/tmp')]);
      final directory = RemoteShellDirectory(runner.call);

      expect(await directory.read(), isNull);
      expect(await directory.read(), isNull);
      expect(await directory.read(), '/tmp');
      expect(runner.commands, hasLength(3));
    });

    test('stops asking a server that cannot answer', () async {
      // No /proc, no sh, and a forced command or a login shell that is not
      // one answering instead of the script.
      final answers = [_exit(3), _exit(126), _exit(127), _exit(0, '/srv\n')];
      for (final answer in answers) {
        final runner = _FakeRunner([answer]);
        final directory = RemoteShellDirectory(runner.call);

        expect(await directory.read(), isNull);
        expect(directory.available, isFalse);
        expect(await directory.read(), isNull);
        expect(runner.commands, hasLength(1), reason: '${answer.exitCode}');
      }
    });

    test('stops asking after three failures in a row', () async {
      const dropped = RemoteCommandException('channel closed');
      // Exit 2 is dash failing to fork under a process limit.
      final runner = _FakeRunner([
        const ChannelOpenException(ChannelRefusal.other, 'refused'),
        _exit(2),
        _answer('/srv'),
        dropped,
        const RemoteCommandException('timed out'),
        _exit(null),
      ]);
      final directory = RemoteShellDirectory(runner.call);

      // An answer in between resets the count.
      expect(await directory.read(), isNull);
      expect(await directory.read(), isNull);
      expect(await directory.read(), '/srv');
      expect(await directory.read(), isNull);
      expect(await directory.read(), isNull);
      expect(directory.available, isTrue);
      for (var i = 0; i < 3; i++) {
        expect(await directory.read(), isNull);
      }
      expect(directory.available, isFalse);
      expect(runner.commands, hasLength(6));
    });
  });

  group('RemoteShellDirectory on real processes', () {
    late Directory sandbox;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('shell_directory_test');
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    /// A directory whose name needs quoting and contains the `) ` that ends
    /// a command name in `/proc/<pid>/stat`.
    String awkwardDirectory() {
      final directory = Directory('${sandbox.path}/media ) files')
        ..createSync();
      return directory.resolveSymbolicLinksSync();
    }

    for (final shell in localShells.keys) {
      test("reads the PTY shell's directory through $shell", () async {
        final cwd = awkwardDirectory();

        final directory = RemoteShellDirectory(
          _besidePtyShells(shell, ptys: [cwd]),
        );

        expect(await directory.read(), cwd);
      }, skip: harnessSkip == false ? shellSkipReason(shell) : harnessSkip);
    }

    test('scans /proc when the kernel has no children file', () async {
      final cwd = awkwardDirectory();

      final directory = RemoteShellDirectory(
        _besidePtyShells(
          'sh',
          ptys: [cwd],
          rewrite: (command) =>
              command.replaceAll('/children', '/no-children-file'),
        ),
      );

      expect(await directory.read(), cwd);
    }, skip: harnessSkip);

    test(
      'has no answer, and asks again, when two PTY shells share it',
      () async {
        var reads = 0;
        final run = _besidePtyShells('sh', ptys: ['/', sandbox.path]);
        final directory = RemoteShellDirectory((command, {timeout}) {
          reads++;
          return run(command, timeout: timeout);
        });

        expect(await directory.read(), isNull);
        expect(await directory.read(), isNull);
        expect(reads, 2);
      },
      skip: harnessSkip,
    );

    test(
      'finds the shell when exec channels share its session, as on Dropbear',
      () async {
        final cwd = awkwardDirectory();

        final directory = RemoteShellDirectory(
          _besidePtyShells('sh', ptys: [cwd], setsid: false),
        );

        expect(await directory.read(), cwd);
      },
      skip: harnessSkip,
    );

    test('has no answer before the PTY child has become the shell', () async {
      // sshd hands its child the terminal before it changes into the
      // home directory and starts the shell.
      final directory = RemoteShellDirectory(
        _besidePtyShells('sh', ptys: [sandbox.path], shells: false),
      );

      expect(await directory.read(), isNull);
    }, skip: harnessSkip);

    test(
      'does not follow a name ending in a newline to its namesake',
      () async {
        final namesake = Directory('${sandbox.path}/data')..createSync();
        final trailing = Directory('${namesake.path}\n')..createSync();

        final directory = RemoteShellDirectory(
          _besidePtyShells('sh', ptys: [trailing.path]),
        );

        expect(await directory.read(), isNull);
      },
      skip: harnessSkip,
    );

    test('has no answer without a PTY shell', () async {
      expect(await RemoteShellDirectory(_besidePtyShells('sh')).read(), isNull);
    }, skip: harnessSkip);

    test("has no answer when the shell's directory is gone", () async {
      final gone = Directory('${sandbox.path}/gone')..createSync();

      final directory = RemoteShellDirectory(
        _besidePtyShells('sh', ptys: [gone.path], remove: [gone.path]),
      );

      expect(await directory.read(), isNull);
    }, skip: harnessSkip);
  });
}
