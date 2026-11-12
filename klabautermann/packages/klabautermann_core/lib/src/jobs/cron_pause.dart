// Pausing and resuming a cron line (03 §7.7, JOB-07; M5 plan M27c): the
// line becomes the pause comment, or the comment the line it held, and
// the crontab is written through the edit pipeline (03 §8.5), so the
// preview, the hash check, the backup and the audit are an edit's.
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CronJob,
        CrontabDocument,
        CrontabLineKind,
        kOwnCrontabSource,
        parseCrontabText,
        userCrontabSource;

import '../engine/protocol.dart' show CrontabTarget;
import '../sampling/sample_results.dart' show maskedCronJobs;

/// The crontab that holds [job], which Pause and Resume rewrite, or null
/// for a line they leave alone: one in `/etc/crontab` or `/etc/cron.d`,
/// or one another manager owns (JOB-09).
CrontabTarget? cronPauseTarget(CronJob job) {
  if (job.managedBy != null) return null;
  if (job.source == kOwnCrontabSource) return const CrontabTarget();
  final user = job.user;
  if (user != null && job.source == userCrontabSource(user)) {
    return CrontabTarget(user: user);
  }
  return null;
}

/// The crontab [text] with [job] paused at [at], or resumed when it is
/// paused, or null when [text] no longer holds the line: the crontab
/// changed since the Jobs view read it. [job] is a Jobs view row, whose
/// line is masked (8.9), so [text]'s lines are matched as the view shows
/// them, as the run-now planner matches them; two different lines that
/// show alike are ambiguous, and answer null too. Of two identical lines
/// the first is the one changed.
String? togglePausedCronJob(String text, CronJob job, {required DateTime at}) {
  final document = CrontabDocument.parse(text);
  final kind = job.paused ? CrontabLineKind.pausedJob : CrontabLineKind.job;
  final shown = maskedCronJobs(
    parseCrontabText(
      text,
      source: job.source,
      systemTable: false,
      user: job.user,
    ),
  );
  final raws = {
    for (final MapEntry(key: line, value: masked) in shown.entries)
      if (masked.paused == job.paused &&
          _withoutCr(masked.raw) == _withoutCr(job.raw))
        _withoutCr(line.raw),
  };
  if (raws.length != 1) return null;
  final raw = raws.single;
  final index = document.lines.indexWhere(
    (line) => line.kind == kind && _withoutCr(line.text) == raw,
  );
  if (index < 0) return null;
  final edited = job.paused
      ? document.resume(index)
      : document.pause(index, at: at);
  return edited.text;
}

/// [line] without the `\r` a CRLF crontab ends it with, which the parser
/// may keep in a job's raw text or not.
String _withoutCr(String line) =>
    line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
