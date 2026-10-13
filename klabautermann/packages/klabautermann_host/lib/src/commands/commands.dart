/// Command builders for the interactive views (03 §8.8). Every builder
/// validates its arguments with [ArgValidators] and returns an argv list;
/// quoting is deliberately left to the caller, which joins the words with
/// the injected `quoteShellWord` (03 §8.8 "nothing is quoted here").
library;

import '../hws/collector.dart' show ArgValidators;

/// A command refused before building: an argument failed its validator
/// (03 §8.8).
final class HostCommandError implements Exception {
  const HostCommandError(this.reason, {this.argument});

  /// Why the argument was refused.
  final String reason;

  /// The offending argument, when relevant.
  final String? argument;

  @override
  String toString() {
    final a = argument == null ? '' : ' (argument: $argument)';
    return 'HostCommandError: $reason$a';
  }
}

/// The `systemctl` verbs the unit view may run (03 §7.5).
enum SystemctlVerb {
  show,
  status,
  start,
  stop,
  restart,
  reload,
  enable,
  disable,
}

/// Validated command builders (03 §8.8).
abstract final class HostCommands {
  /// `systemctl --no-ask-password <verb> -- <unit>` (03 §7.5).
  /// `--no-ask-password` fails fast where a polkit prompt would block.
  static List<String> systemctl(SystemctlVerb verb, String unit) {
    _check(ArgValidators.unitName, unit);
    return ['systemctl', '--no-ask-password', verb.name, '--', unit];
  }

  /// `journalctl -o json` with the log view's filters (03 §7.6): unit,
  /// priority floor, since expression, resume cursor, line cap and a
  /// grep pattern. Every supplied filter is validated.
  static List<String> journalctl({
    String? unit,
    String? priority,
    String? since,
    String? cursor,
    int? lines,
    String? grep,
  }) {
    if (unit != null) _check(ArgValidators.unitName, unit);
    if (priority != null) _check(ArgValidators.journalPriority, priority);
    if (since != null) _check(ArgValidators.journalSince, since);
    if (cursor != null) _check(ArgValidators.journalCursor, cursor);
    if (grep != null) _check(ArgValidators.journalGrep, grep);
    if (lines != null && lines < 0) {
      throw const HostCommandError('negative line count');
    }
    return [
      'journalctl',
      '-o',
      'json',
      '--no-pager',
      if (unit != null) ...['-u', unit],
      if (priority != null) ...['-p', priority],
      if (since != null) ...['--since', since],
      if (cursor != null) '--after-cursor=$cursor',
      if (lines != null) ...['-n', '$lines'],
      if (grep != null) ...['-g', grep],
    ];
  }

  /// `crontab -l -u <user>` for the jobs view's user switch (03 §7.7).
  static List<String> crontabList(String user) {
    _check(ArgValidators.userName, user);
    return ['crontab', '-l', '-u', user];
  }

  /// `df -PT -B1 [<path>]` for one mount's numbers, or `df -Pi` for inode
  /// pressure (03 §7.3). The path is validated but `df` flags are fixed.
  static List<String> df({String? path, bool inodes = false}) {
    if (path != null) _check(ArgValidators.absolutePath, path);
    return [
      'df',
      if (inodes) '-Pi' else ...['-PT', '-B1'],
      if (path != null) path,
    ];
  }

  /// `ss -tulpn` for the listening-ports list (03 §7.4).
  static List<String> ss() => const ['ss', '-tulpn'];

  /// `(unset TZ; systemd-analyze calendar --iterations=N '<expr>')` for
  /// the OnCalendar preview (03 §7.7): the subshell clears a session TZ
  /// so the expression resolves in the server zone. Below systemd 242
  /// `--iterations` does not exist and is left off ([systemdMajor] null
  /// keeps it: unknown versions get the modern flag).
  static List<String> onCalendar(
    String expression, {
    required int iterations,
    int? systemdMajor,
  }) {
    _check(ArgValidators.calendarExpression, expression);
    if (iterations <= 0) {
      throw const HostCommandError('iterations must be positive');
    }
    final it = systemdMajor != null && systemdMajor < 242
        ? ''
        : ' --iterations=$iterations';
    return [
      'sh',
      '-c',
      '(unset TZ; systemd-analyze calendar$it "\$1")',
      'hws-cal',
      expression,
    ];
  }

  static void _check(String? Function(String) validator, String value) {
    final reason = validator(value);
    if (reason != null) {
      throw HostCommandError(reason, argument: value);
    }
  }
}
