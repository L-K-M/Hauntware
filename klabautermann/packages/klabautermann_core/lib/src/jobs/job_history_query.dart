// The v1 job history reads (03 §7.7; M5 plan M24): anacron's jobs with
// the day each last ran (JOB-04), a timer's last run (JOB-05) and the
// job starts cron logged (JOB-05). Commands cross masked (03 §8.9), as
// the cron rows' do.
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        AnacronJob,
        HostCommandError,
        HostCommands,
        LoggedCronRun,
        kAnacronMissing,
        parseAnacron,
        parseCronRuns,
        parseJournalLines,
        parseTimerLastRun;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult, SshLink, quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import '../engine/protocol.dart';
import '../sampling/argument_masking.dart'
    show ArgumentMaskingBudget, maskCommandLine;

/// The most of a failure's error text a [JobHistoryFailed] carries.
const int _detailLimit = 500;

/// Runs [query] on [link], through [admin] when admin mode is on; never
/// throws.
Future<JobHistoryResult> runJobHistoryQuery(
  String serverId,
  String requestId,
  JobHistorySpec query, {
  required SshLink link,
  AdminSession? admin,
}) async {
  JobHistoryResult answer(
    JobHistoryPayload payload, [
    List<String> warnings = const [],
  ]) => JobHistoryResult(
    serverId: serverId,
    requestId: requestId,
    payload: payload,
    warnings: warnings,
  );

  Future<RemoteCommandResult> run(List<String> argv) => admin == null
      ? link.run(
          HostCommands.commandLine(argv, quote: quoteShellWord),
          stdin: const [],
        )
      : admin.executor.run(argv, password: admin.password);

  try {
    switch (query) {
      case AnacronQuery():
        final result = await run(HostCommands.anacron());
        if (result.exitCode == kAnacronMissing) {
          return answer(const JobHistoryFailed(JobHistoryFailure.notInstalled));
        }
        if (result.exitCode != 0) return answer(_failed(result));
        final parsed = parseAnacron(result.stdout);
        return answer(
          AnacronPayload(_maskAnacron(parsed.value)),
          parsed.warnings,
        );
      case TimerLastRunQuery(:final timer, :final service):
        final result = await run(HostCommands.timerLastRun(timer, service));
        if (result.exitCode != 0) return answer(_failed(result));
        final parsed = parseTimerLastRun(result.stdout);
        return answer(TimerLastRunPayload(parsed.value), parsed.warnings);
      case CronRunsQuery(:final lines):
        final result = await run(HostCommands.cronRuns(lines: lines));
        if (result.exitCode != 0) return answer(_failed(result));
        final entries = parseJournalLines(result.stdout);
        return answer(
          CronRunsPayload(_maskRuns(parseCronRuns(entries.value))),
          entries.warnings,
        );
    }
  } on HostCommandError {
    return answer(const JobHistoryFailed(JobHistoryFailure.invalidTarget));
  } on RemoteCommandException {
    return answer(const JobHistoryFailed(JobHistoryFailure.noLink));
  } on Object catch (error) {
    // The engine runs this unawaited, as the host queries: an answer must
    // go out whatever else fails, such as a timeout.
    return answer(_failedWith('$error'));
  }
}

JobHistoryFailed _failed(RemoteCommandResult result) =>
    _failedWith(result.stderr.trim());

JobHistoryFailed _failedWith(String detail) => JobHistoryFailed(
  JobHistoryFailure.failed,
  detail: detail.length > _detailLimit
      ? detail.substring(0, _detailLimit)
      : detail,
);

/// [text] masked as one command line, under [budget]. The masker never
/// reads the program's slot as a value, so an empty program stands in
/// front, as for cron lines.
String _mask(String text, ArgumentMaskingBudget budget) =>
    maskCommandLine(['', text], budget: budget)[1].display;

List<AnacronJob> _maskAnacron(List<AnacronJob> jobs) {
  final budget = ArgumentMaskingBudget();
  return [
    for (final job in jobs)
      AnacronJob(
        period: job.period,
        delayMinutes: job.delayMinutes,
        identifier: job.identifier,
        command: _mask(job.command, budget),
        lastRun: job.lastRun,
      ),
  ];
}

List<LoggedCronRun> _maskRuns(List<LoggedCronRun> runs) {
  final budget = ArgumentMaskingBudget();
  return [
    for (final run in runs)
      LoggedCronRun(
        at: run.at,
        user: run.user,
        command: _mask(run.command, budget),
      ),
  ];
}
