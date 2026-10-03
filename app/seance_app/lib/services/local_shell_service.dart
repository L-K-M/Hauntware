import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:seance_core/seance_core.dart';

import 'macos_sandbox.dart';

/// Opens local shells for the app: decides whether this platform can host one,
/// resolves which shell to run, and binds `flutter_pty` to `seance_core`'s
/// [LocalPty] seam.
///
/// The launcher is injectable so tests exercise the whole session lifecycle
/// with no plugin and no child process — `flutter test` runs on the host Dart
/// VM, where the plugin's native library does not exist to be opened at all.
class LocalShellService {
  final LocalShellPlatform platform;
  final Map<String, String> environment;
  final LocalPtyLauncher launch;

  LocalShellService({
    LocalShellPlatform? platform,
    Map<String, String>? environment,
    LocalPtyLauncher? launch,
  })  : platform = platform ?? hostPlatform(),
        environment = environment ?? Platform.environment,
        launch = launch ?? _startFlutterPty;

  /// This build's platform, as the core's transport-agnostic enum.
  ///
  /// Reads Flutter's [defaultTargetPlatform] rather than `dart:io`'s
  /// `Platform`, so a test can pin it with `debugDefaultTargetPlatformOverride`
  /// the way the terminal engine's platform detection already is.
  static LocalShellPlatform hostPlatform() {
    if (kIsWeb) return LocalShellPlatform.unknown;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux => LocalShellPlatform.linux,
      TargetPlatform.macOS => LocalShellPlatform.macos,
      TargetPlatform.windows => LocalShellPlatform.windows,
      TargetPlatform.android => LocalShellPlatform.android,
      TargetPlatform.iOS => LocalShellPlatform.ios,
      TargetPlatform.fuchsia => LocalShellPlatform.unknown,
    };
  }

  bool get supported => localShellSupportedOn(platform);

  /// Whether the local shell should be offered at all: the user asked for it
  /// *and* this platform can host one. Both halves are load-bearing — the
  /// settings file is device-local but portable, so a value enabled on a
  /// laptop must never put a row that cannot open into a phone's list.
  bool availableWhen({required bool enabledInSettings}) =>
      enabledInSettings && supported;

  /// One sentence saying why this platform has no local shell, or empty when
  /// it does. Shown in Settings instead of an unexplained disabled switch.
  String get unavailableReason => localShellUnavailableReason(platform);

  /// True when the shell would run inside macOS's App Sandbox — which the
  /// child inherits, so `$HOME` is Séance's container, anything outside it is
  /// unreadable, and the shell cannot take control of the terminal for job
  /// control.
  ///
  /// Normally false: Séance's macOS entitlements drop the sandbox precisely so
  /// this shell is a real one. The detection stays because it is cheap, it is
  /// the honest answer for anyone who puts the entitlement back, and a warning
  /// that only appears when it is true costs nothing when it is not.
  bool get sandboxed => macOsSandboxed(
    environment: environment,
    isMacOS: platform == LocalShellPlatform.macos,
  );

  /// What a fresh local shell should run here.
  ///
  /// Resolved once: a process's environment does not change under it, and
  /// [shellName] is read from the server list's builder on every rebuild —
  /// re-resolving would copy the whole environment map each frame.
  late final LocalShellCommand command = LocalShellCommand.resolve(
    platform: platform,
    environment: environment,
  );

  /// A short label for the shell being run — `zsh`, `bash` — for the tab and
  /// the status bar.
  late final String shellName = _basename(command.executable);

  static String _basename(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    return name.isEmpty ? 'shell' : name;
  }

  /// The banner fed into a sandboxed session's terminal before the shell's
  /// first output, or null when there is nothing to warn about.
  ///
  /// Written into the terminal rather than shown as app chrome because it
  /// describes *this shell*, scrolls away with it, and stays in the scrollback
  /// where the surprising `cd ~` is about to happen.
  String? get sandboxNotice => sandboxed
      ? 'Séance: this shell runs inside the macOS App Sandbox. '
          "\$HOME is Séance's container, files outside it are unreadable, "
          'and job control is unavailable.\r\n'
      : null;

  static Future<LocalPty> _startFlutterPty(
    LocalShellCommand command,
    TerminalSize size,
  ) async =>
      FlutterPtyLocalPty(command, size);
}

/// [LocalPty] over `flutter_pty`.
class FlutterPtyLocalPty implements LocalPty {
  final Pty _pty;
  bool _killed = false;
  bool _exited = false;

  /// `Pty.start` is a synchronous constructor that throws [StateError] when
  /// the fork fails; [LocalShellSession.start] turns that into a
  /// [LocalShellException] carrying a user-facing line.
  FlutterPtyLocalPty(LocalShellCommand command, TerminalSize size)
      : _pty = Pty.start(
          command.executable,
          arguments: command.arguments,
          workingDirectory: command.workingDirectory,
          // Passed whole, not as a delta — the plugin builds the child's
          // environment from a fixed six names plus this map, so anything
          // omitted here simply would not exist in the shell.
          environment: command.environment,
          rows: size.rows,
          columns: size.cols,
        ) {
    // Exit observation is registered at spawn, not at kill time: by the
    // time close() runs, a child that already died has been reaped and its
    // pid is recyclable — signalling then could hit an unrelated process.
    // A failed exit future means "not proven dead", so onError deliberately
    // leaves _exited false and the watchdog still escalates.
    _pty.exitCode.then((_) => _exited = true, onError: (_) {});
  }

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  void write(Uint8List data) => _pty.write(data);

  /// The plugin takes rows first; [TerminalSize] is columns-first. Going
  /// through the seam is what keeps that transposition in one place.
  @override
  void resize(TerminalSize size) => _pty.resize(size.rows, size.cols);

  @override
  void kill() {
    // Signalling a process that has already exited throws on some platforms,
    // and close() is allowed to run after the shell died on its own.
    if (_killed) return;
    _killed = true;
    PtyTermination(
      hasExited: () => _exited,
      // The pid was captured at spawn; killPid reaches the child even after
      // close() has released the native handle.
      send: (signal) => Process.killPid(_pty.pid, signal),
      hangup: _pty.close,
    ).run();
  }
}

/// The teardown sequence that actually ends the child behind a pty and
/// releases its native side.
///
/// Two facts drive the shape. First, the plugin's signal-only `kill`
/// (SIGTERM by default) cannot end an interactive POSIX shell — they are
/// required to ignore SIGTERM, and the pid verifiably outlived
/// `LocalShellSession.close()`. The authentic teardown is [hangup]:
/// closing the master fd makes the kernel SIGHUP the foreground process
/// group of the child's session — terminal semantics, not a synthetic
/// signal. Second, upstream leaked the master fd, the reader thread and
/// the handle on every session, so [hangup] runs even when the child is
/// already dead — releasing the native side is the other half of "close".
///
/// A child that survives the hangup (trapped HUP, or a non-shell
/// executable) still must not leak: if [hasExited] stays false for
/// [grace], the watchdog escalates to SIGKILL, which cannot be caught.
/// [hasExited] is backed by an observation registered at spawn, so a child
/// that already exited suppresses all signalling — its pid may have been
/// recycled. An observer that fails or never fires reads as *not dead*,
/// and escalation proceeds — fail closed.
@visibleForTesting
class PtyTermination {
  PtyTermination({
    required this.hasExited,
    required this.send,
    required this.hangup,
    this.grace = const Duration(milliseconds: 500),
  });

  /// True once the child has been observed reaped.
  final bool Function() hasExited;

  /// Sends one signal to the child's pid.
  final bool Function(ProcessSignal signal) send;

  /// Closes the pty master, hanging up the child's session and releasing
  /// the native handle, fd and reader thread.
  final void Function() hangup;

  /// How long to wait for the child to die before escalating to SIGKILL.
  final Duration grace;

  bool _started = false;

  /// Idempotent: repeated calls do not repeat the sequence.
  void run() {
    if (_started) return;
    _started = true;
    hangup();
    if (hasExited()) return;
    Timer(grace, () {
      if (!hasExited()) _signal(ProcessSignal.sigkill);
    });
  }

  void _signal(ProcessSignal signal) {
    try {
      if (!send(signal)) {
        debugPrint('Local shell: $signal was not delivered to the child');
      }
    } catch (error) {
      debugPrint('Local shell: sending $signal to the child failed: $error');
    }
  }
}
