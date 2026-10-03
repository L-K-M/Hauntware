// Real-PTY verification for the local shell, runnable under `flutter test`
// whenever `libflutter_pty.so` is on LD_LIBRARY_PATH — see AGENTS.md §4 for
// the one-line build from the locked `flutter_pty` package source.
//
// Unlike `local_shell_test.dart` (and every committed local-shell test,
// which injects a fake `LocalPtyLauncher` and never starts a process), this
// suite goes through the production path — `LocalShellService`'s real
// launcher -> `FlutterPtyLocalPty` -> `Pty.start` -> forkpty(3) -> a real
// shell — with `HeadlessTerminalEngine` standing in for the renderer. It
// exists because a fake cannot answer OS questions: whether `stty` saw a
// resized winsize, whether ^C became SIGINT, whether close() actually
// reaped the child (it did not — the SIGTERM it sent is one interactive
// POSIX shells must ignore).
//
// CI has no native library, so every test self-skips there — the same
// environment-skip pattern seance_core already uses.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/local_shell_service.dart';
import 'package:seance_core/seance_core.dart';

/// Whether the plugin's native library can be opened in this process.
/// `LD_LIBRARY_PATH` is read by the dynamic linker at process start, so the
/// check belongs at test declaration, not inside a test.
final bool _ptyLibraryAvailable = () {
  try {
    DynamicLibrary.open('libflutter_pty.so');
    return true;
  } catch (_) {
    return false;
  }
}();

/// CI sets `SEANCE_NATIVE_PTY_REQUIRED=1` on the job that first builds the
/// release bundle and then runs this file with the bundle's lib/ on
/// LD_LIBRARY_PATH. There a missing or unloadable library is a product
/// defect, not an environment skip — so required mode never skips; the
/// tests fail for real. Locally, without the library, the honest outcome
/// is still the skip.
final bool _ptyRequired =
    Platform.environment['SEANCE_NATIVE_PTY_REQUIRED'] == '1';

final dynamic _ptySkip = _ptyLibraryAvailable || _ptyRequired
    ? false
    : 'libflutter_pty.so not on LD_LIBRARY_PATH (AGENTS.md §4)';

Future<void> _waitFor(
  HeadlessTerminalEngine engine,
  String needle, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (engine.receivedText.contains(needle)) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail(
    'timed out waiting for "$needle". '
    'received so far: ${engine.receivedText}',
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('timed out waiting for $what');
}

/// The production spawn path: `LocalShellService` resolves the command and
/// its default launcher is the real `FlutterPtyLocalPty` -> `Pty.start`.
/// The environment is a minimal one for /bin/sh, not the test process's —
/// `Pty.start` does not inherit `Platform.environment`, it starts from a
/// fixed six names plus this map.
Future<LocalShellSession> _spawn(
  HeadlessTerminalEngine engine,
  Directory home,
) {
  // Pinned rather than hostPlatform(): flutter_test forces
  // defaultTargetPlatform to android for widget-test determinism.
  final service = LocalShellService(
    platform: LocalShellPlatform.linux,
    environment: {
      'HOME': home.path,
      'PATH': '/usr/bin:/bin',
      'SHELL': '/bin/sh',
      'LANG': 'C.UTF-8',
    },
  );
  expect(service.supported, isTrue);
  expect(service.command.executable, '/bin/sh');
  return LocalShellSession.start(
    launcher: service.launch,
    command: service.command,
    engine: engine,
  );
}

void main() {
  // Fails loudly (rather than skip-hiding) when CI's required mode finds
  // no library — the release bundle is expected to have produced it.
  test(
    'native pty library is loadable',
    skip: _ptyLibraryAvailable || _ptyRequired
        ? false
        : 'libflutter_pty.so not on LD_LIBRARY_PATH (AGENTS.md §4)',
    () {
      expect(
        _ptyLibraryAvailable,
        isTrue,
        reason: 'SEANCE_NATIVE_PTY_REQUIRED=1 but libflutter_pty.so could '
            'not be opened. LD_LIBRARY_PATH='
            '${Platform.environment['LD_LIBRARY_PATH']}',
      );
    },
  );

  Directory? home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('seance_pty_test_');
  });
  tearDown(() async {
    if (home != null && home!.existsSync()) {
      await home!.delete(recursive: true);
    }
    home = null;
  });

  test(
    'spawns a real /bin/sh on a pty and returns its output',
    skip: _ptySkip,
    () async {
      final engine = HeadlessTerminalEngine();
      final session = await _spawn(engine, home!);
      addTearDown(session.close);

      // The shell echoes the command itself, so only the *evaluated*
      // marker proves a real shell processed input and wrote output back.
      engine.type('echo PTY_ECHO_\$((40+2))\n');
      await _waitFor(engine, 'PTY_ECHO_42');
    },
  );

  test(
    'argv, environment and cwd reach the child intact',
    skip: _ptySkip,
    () async {
      // The plugin hands pty_create borrowed argv/envp/cwd buffers and frees
      // them right after it returns. If the free ran before the child got
      // its copy, the spawned process would see garbage instead of these
      // markers — so an intact readback pins the ownership handoff.
      final engine = HeadlessTerminalEngine();
      final service = LocalShellService(
        platform: LocalShellPlatform.linux,
        environment: {
          'HOME': home!.path,
          'PATH': '/usr/bin:/bin',
          'SHELL': '/bin/sh',
          'LANG': 'C.UTF-8',
        },
      );
      final session = await LocalShellSession.start(
        launcher: service.launch,
        command: LocalShellCommand(
          executable: '/bin/sh',
          arguments: [
            '-c',
            'printf "FWD:%s:%s:%s:%s\\n" "\$0" "\$1" "\$SEANCE_ENV_FWD" "\$PWD"',
            'ARGV0MARK',
            'ARGV1MARK',
          ],
          workingDirectory: home!.path,
          environment: {'SEANCE_ENV_FWD': 'envmark42'},
        ),
        engine: engine,
      );
      addTearDown(session.close);

      await _waitFor(
        engine,
        'FWD:ARGV0MARK:ARGV1MARK:envmark42:'
        '${home!.resolveSymbolicLinksSync()}',
      );
    },
  );

  test(
    'winsize starts 24x80 and resize(132,43) reads back as "43 132"',
    skip: _ptySkip,
    () async {
      final engine = HeadlessTerminalEngine();
      final session = await _spawn(engine, home!);
      addTearDown(session.close);

      engine.type('stty size\n');
      await _waitFor(engine, '24 80');

      // TerminalSize is columns-first; pty.resize is rows-first. The
      // transposition is exactly what this verifies.
      session.resize(const TerminalSize(132, 43));
      expect(engine.size, const TerminalSize(132, 43));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      engine.type('stty size\n');
      await _waitFor(engine, '43 132');
    },
  );

  test(
    'Ctrl+C interrupts a running sleep while the shell survives',
    skip: _ptySkip,
    () async {
      final engine = HeadlessTerminalEngine();
      final session = await _spawn(engine, home!);
      addTearDown(session.close);

      engine.type('sleep 30\n');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      engine.type('\x03');
      // Queued right behind the interrupt: dash exits sleep with 130 and
      // runs this immediately — a real SIGINT through the pty line
      // discipline, not a write error or a dead shell.
      engine.type('echo RC_\$?\n');
      await _waitFor(engine, 'RC_130', timeout: const Duration(seconds: 15));
    },
  );

  test(
    'exit reports status 0 and onClosed fires exactly once',
    skip: _ptySkip,
    () async {
      final engine = HeadlessTerminalEngine();
      final session = await _spawn(engine, home!);
      var closedCount = 0;
      session.onClosed = () => closedCount++;

      engine.type('exit\n');
      await _waitUntil(() => closedCount == 1, what: 'onClosed');
      expect(session.exitCode, 0);
      expect(session.isClosed, isTrue);
      expect(engine.isDisposed, isTrue);

      // Late setter must not double-fire; close after natural exit is a
      // no-op.
      session.onClosed = () => closedCount++;
      await session.close();
      await session.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(closedCount, 1);
    },
  );

  test(
    'close() on a live session terminates and reaps the child',
    skip: _ptySkip,
    () async {
      final engine = HeadlessTerminalEngine();
      final session = await _spawn(engine, home!);

      // The LocalPty seam exposes no pid, so the shell tells us its own.
      engine.type('echo SHELLPID_\$\$\n');
      await _waitFor(engine, 'SHELLPID_');
      final pid = int.parse(
        RegExp('SHELLPID_(\\d+)')
            .firstMatch(engine.receivedText)!
            .group(1)!,
      );

      await session.close();
      expect(session.isClosed, isTrue);
      expect(engine.isDisposed, isTrue);
      // close() is allowed to be called again; nothing should happen.
      await session.close();

      // The regression this test exists for: Pty.kill() defaulted to
      // SIGTERM, which interactive POSIX shells must ignore — the child
      // outlived close(). Now the child must be dead and reaped.
      await _waitUntil(
        () => !File('/proc/$pid/stat').existsSync(),
        what: 'child pid $pid to exit after close()',
      );
      final status = await session.pty.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () => -999);
      expect(status, isNot(-999), reason: 'child never reaped after close()');
    },
  );

  test(
    'close() still reaps a child that traps HUP — SIGKILL backstop',
    skip: _ptySkip,
    () async {
      final engine = HeadlessTerminalEngine();
      final session = await _spawn(engine, home!);

      engine.type('echo TRAP_PID_\$\$\n');
      await _waitFor(engine, 'TRAP_PID_');
      final pid = int.parse(
        RegExp('TRAP_PID_(\\d+)').firstMatch(engine.receivedText)!.group(1)!,
      );

      // Replace the shell with a process that ignores SIGHUP — exec keeps
      // the pid, so close()'s HUP lands but cannot kill it. Only the grace
      // -window SIGKILL can.
      engine.type("trap '' HUP; exec sleep 300\n");
      await Future<void>.delayed(const Duration(milliseconds: 500));

      await session.close();
      await _waitUntil(
        () => !File('/proc/$pid/stat').existsSync(),
        what: 'HUP-ignoring child $pid to be killed',
      );
      final status = await session.pty.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () => -999);
      expect(status, -9, reason: 'expected SIGKILL (9), got $status');
    },
  );

  test(
    "close() also brings down the shell's foreground job",
    skip: _ptySkip,
    () async {
      final engine = HeadlessTerminalEngine();
      final session = await _spawn(engine, home!);

      engine.type('echo SHELLPID_\$\$\n');
      await _waitFor(engine, 'SHELLPID_');
      final shellPid = int.parse(
        RegExp('SHELLPID_(\\d+)')
            .firstMatch(engine.receivedText)!
            .group(1)!,
      );

      // A long-running foreground job: the kernel hangs up on the
      // foreground process group when the session leader dies, which is
      // what 'the terminal closed' must look like to it.
      engine.type('sleep 300\n');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final children = File('/proc/$shellPid/task/$shellPid/children')
          .readAsStringSync()
          .trim();
      expect(children, isNotEmpty, reason: 'sleep never started');
      final sleepPid = int.parse(children.split(RegExp('\\s+')).first);

      await session.close();
      await _waitUntil(
        () => !File('/proc/$shellPid/stat').existsSync(),
        what: 'shell to exit',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        File('/proc/$sleepPid/stat').existsSync(),
        isFalse,
        reason: 'foreground job $sleepPid survived the shell',
      );
    },
  );

  test(
    'repeated spawn/close releases fds, threads and address space',
    skip: _ptySkip,
    () async {
      int fdCount() => Directory('/proc/self/fd').listSync().length;
      int taskCount() => Directory('/proc/self/task').listSync().length;

      Future<void> cycle() async {
        final engine = HeadlessTerminalEngine();
        final session = await _spawn(engine, home!);
        await session.close();
        await session.pty.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () => -999,
        );
      }

      // Warm up lazy native init and VM worker threads first so the
      // baseline isn't polluted by one-time allocations.
      for (var i = 0; i < 3; i++) {
        await cycle();
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final baseFds = fdCount();
      final baseTasks = taskCount();

      for (var i = 0; i < 25; i++) {
        await cycle();
      }
      await Future<void>.delayed(const Duration(seconds: 1));

      // Measured before the vendored lifecycle fix: +2 fds (master + a
      // leaked slave copy) and ~16 MB of thread stacks per session —
      // 25 cycles was +50 fds, +25 tasks, +412 MB VmSize. Anything close
      // to that means teardown is leaking again.
      expect(fdCount() - baseFds, lessThanOrEqualTo(4),
          reason: 'master/slave fd leaked per session');
      expect(taskCount() - baseTasks, lessThanOrEqualTo(4),
          reason: 'reader/waiter threads not reaped');
    },
  );
}
