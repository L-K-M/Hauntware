import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// What a process run for a reveal reported: its exit code and what it
/// wrote to stderr, or null when it had not exited within the timeout it
/// was given (it is killed then).
typedef GhostRevealProcessResult = ({int exitCode, String stderr});

/// Runs one reveal step. Injectable so tests never spawn a file manager.
/// Throws [ProcessException] when [executable] cannot start.
typedef GhostRevealProcessRunner =
    Future<GhostRevealProcessResult?> Function(
      String executable,
      List<String> arguments, {
      Duration? timeout,
    });

/// How a reveal ended.
enum GhostRevealOutcome {
  /// A file manager was asked to show the item (or, on Linux without a
  /// freedesktop file manager, its folder was opened).
  shown,

  /// The Linux session bus took the `ShowItems` call and gave no answer
  /// in time. The call may still be answered, so the folder is not opened
  /// as well, which could show it twice.
  unanswered,

  /// Every route failed, or the platform has none.
  failed,
}

/// The result of [GhostFileRevealer.reveal]: the outcome and, for a
/// failed Finder reveal, what `open` wrote to stderr.
final class GhostRevealResult {
  const GhostRevealResult(this.outcome, {this.detail});

  final GhostRevealOutcome outcome;

  /// The failing tool's own words, or null.
  final String? detail;

  bool get shown => outcome == GhostRevealOutcome.shown;
}

/// "Show in Finder / Explorer / File Manager" for a path on this machine:
/// opens the platform file manager with the item selected. Every launch
/// passes its arguments as a list, never through a shell.
///
/// - macOS: `/usr/bin/open -R` (Finder reveal).
/// - Windows: `explorer.exe /select,"<path>"`; Explorer's exit code is 1
///   even on success, so any launch counts.
/// - Linux: the freedesktop `org.freedesktop.FileManager1.ShowItems`
///   D-Bus call (Nautilus, Dolphin, Nemo, Thunar implement it), bounded
///   by [busTimeout]; when no file manager takes it or `dbus-send` is
///   missing, the item's folder opens with `xdg-open`, then `gio open`.
final class GhostFileRevealer {
  const GhostFileRevealer({
    GhostRevealProcessRunner? run,
    String? operatingSystem,
  }) : _run = run ?? runGhostRevealProcess,
       _os = operatingSystem;

  /// How long the session bus may take to answer `ShowItems`: a bus that
  /// accepts the call and never replies (after a resume, a wedged file
  /// manager) must not hang the action.
  static const busTimeout = Duration(seconds: 5);

  static const _macOS = 'macos';
  static const _windows = 'windows';
  static const _linux = 'linux';

  final GhostRevealProcessRunner _run;
  final String? _os;

  String get _platform => _os ?? Platform.operatingSystem;

  /// Whether this platform can reveal at all.
  bool get supported => const {_macOS, _windows, _linux}.contains(_platform);

  /// Reveals [path], which the caller has checked is an absolute path on
  /// this machine.
  Future<GhostRevealResult> reveal(String path) async {
    switch (_platform) {
      case _macOS:
        return _finder(path);
      case _windows:
        // Explorer parses its own command line and splits the /select
        // target on commas unless it is quoted. Dart escapes a quote
        // inside an argument for the C runtime (\"), which Explorer does
        // not understand, but it passes the executable string to
        // CreateProcessW verbatim once that string contains a quote, so
        // the whole line rides there. Windows file names cannot contain
        // `"`, so the quoting is always sound.
        return await _launches('explorer.exe /select,"$path"')
            ? const GhostRevealResult(GhostRevealOutcome.shown)
            : const GhostRevealResult(GhostRevealOutcome.failed);
      case _linux:
        return _freedesktop(path);
    }
    return const GhostRevealResult(GhostRevealOutcome.failed);
  }

  Future<GhostRevealResult> _finder(String path) async {
    final GhostRevealProcessResult? result;
    try {
      result = await _run('/usr/bin/open', ['-R', path]);
    } on ProcessException catch (error) {
      return GhostRevealResult(
        GhostRevealOutcome.failed,
        detail: error.message,
      );
    }
    if (result != null && result.exitCode == 0) {
      return const GhostRevealResult(GhostRevealOutcome.shown);
    }
    final detail = result?.stderr.trim() ?? '';
    return GhostRevealResult(
      GhostRevealOutcome.failed,
      detail: detail.isEmpty ? null : detail,
    );
  }

  Future<GhostRevealResult> _freedesktop(String path) async {
    switch (await _showItems(path)) {
      case GhostRevealOutcome.shown:
        return const GhostRevealResult(GhostRevealOutcome.shown);
      case GhostRevealOutcome.unanswered:
        return const GhostRevealResult(GhostRevealOutcome.unanswered);
      case GhostRevealOutcome.failed:
        break;
    }
    final folder = File(path).parent.path;
    if (await _exitsCleanly('xdg-open', [folder]) ||
        await _exitsCleanly('gio', ['open', folder])) {
      return const GhostRevealResult(GhostRevealOutcome.shown);
    }
    return const GhostRevealResult(GhostRevealOutcome.failed);
  }

  Future<GhostRevealOutcome> _showItems(String path) async {
    // dbus-send splits `array:string:` values on commas and has no
    // escape, so a comma in the name is percent-encoded: the same file
    // URI, and one item instead of two that do not exist.
    final uri = Uri.file(path).toString().replaceAll(',', '%2C');
    final GhostRevealProcessResult? result;
    try {
      result = await _run('dbus-send', [
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.FileManager1',
        '--type=method_call',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        'array:string:$uri',
        'string:',
      ], timeout: busTimeout);
    } on ProcessException {
      return GhostRevealOutcome.failed;
    }
    if (result == null) return GhostRevealOutcome.unanswered;
    return result.exitCode == 0
        ? GhostRevealOutcome.shown
        : GhostRevealOutcome.failed;
  }

  /// Whether [executable] ran and exited 0; a missing tool is a failed
  /// step, never the end of the fallback chain.
  Future<bool> _exitsCleanly(String executable, List<String> arguments) async {
    try {
      return (await _run(executable, arguments))?.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Whether [executable] started at all, whatever it exits with.
  Future<bool> _launches(String executable) async {
    try {
      await _run(executable, const []);
      return true;
    } on ProcessException {
      return false;
    }
  }
}

/// The real [GhostRevealProcessRunner]: [Process.run] without a timeout;
/// with one, a process still running when it passes is killed.
@visibleForTesting
Future<GhostRevealProcessResult?> runGhostRevealProcess(
  String executable,
  List<String> arguments, {
  Duration? timeout,
}) async {
  if (timeout == null) {
    final result = await Process.run(executable, arguments);
    return (exitCode: result.exitCode, stderr: '${result.stderr}');
  }
  final process = await Process.start(executable, arguments);
  final stderr = StringBuffer();
  unawaited(process.stdout.drain<void>());
  final errors = process.stderr
      .transform(systemEncoding.decoder)
      .forEach(stderr.write);
  try {
    final exitCode = await process.exitCode.timeout(timeout);
    await errors;
    return (exitCode: exitCode, stderr: '$stderr');
  } on TimeoutException {
    process.kill();
    return null;
  }
}
