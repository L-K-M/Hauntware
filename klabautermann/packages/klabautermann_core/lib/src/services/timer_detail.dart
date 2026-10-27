// JOB-02's timer schedule (03 §7.7, D57): one timer's triggers and
// randomized delay from `systemctl show`, then each `OnCalendar=`
// expression's next runs from `systemd-analyze calendar`, as the login
// user over the link, each read on a channel of its own.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, SshLink, quoteShellWord;

import '../engine/protocol.dart';

/// How many runs of each `OnCalendar=` expression a read lists, as many
/// as a cron line's (`mergeJobs`' default).
const kTimerRunsListed = 5;

/// How long each of the read's commands may run.
const kTimerDetailTimeout = Duration(seconds: 30);

/// The exit status a shell gives a command it cannot find.
const _commandNotFound = 127;

/// Reads [unit]'s triggers on [serverId], in the login user's own manager
/// when [user], with [profile]'s user id, runtime directory and systemd
/// version. An expression whose calendar read fails keeps its triggers
/// without runs. Answers rather than throws.
Future<TimerDetailReport> readTimerDetail(
  String serverId,
  String unit, {
  required String requestId,
  required SshLink link,
  required bool user,
  HostProfile? profile,
}) async {
  TimerDetailReport failed(TimerDetailFailure failure) => TimerDetailReport(
    serverId: serverId,
    requestId: requestId,
    unit: unit,
    user: user,
    failure: failure,
  );

  final manager = user
      ? UnitManager.userFor(
          uid: profile?.uid,
          xdgRuntimeDir: profile?.xdgRuntimeDir,
        )
      : const UnitManager.system();
  final List<String> argv;
  try {
    argv = HostCommands.timerDetail(unit, manager: manager);
  } on HostCommandError {
    return failed(TimerDetailFailure.invalidUnit);
  }

  Future<(int?, String)> run(List<String> argv) async {
    final result = await link.run(
      HostCommands.commandLine(argv, quote: quoteShellWord),
      stdin: const [],
      timeout: kTimerDetailTimeout,
    );
    return (result.exitCode, result.stdout);
  }

  try {
    final (status, stdout) = await run(argv);
    if (status == _commandNotFound) return failed(TimerDetailFailure.missing);
    if (status != 0) return failed(TimerDetailFailure.unreadable);
    final detail = parseTimerDetail(stdout, ParseContext.standard).value;

    final calendars = <String, OnCalendarResult>{};
    final commands = timerCalendarCommands(
      detail,
      runCount: kTimerRunsListed,
      systemdMajor: profile?.systemdVersion,
    );
    for (final MapEntry(key: expression, value: argv) in commands.entries) {
      try {
        final (status, out) = await run(argv);
        if (status == 0) calendars[expression] = parseOnCalendar(out).value;
      } on RemoteCommandException {
        // The triggers are read; this expression lists no runs.
        continue;
      }
    }
    return TimerDetailReport(
      serverId: serverId,
      requestId: requestId,
      unit: unit,
      user: user,
      detail: detail,
      calendars: calendars,
    );
  } on RemoteCommandException {
    return failed(TimerDetailFailure.transport);
  }
}
