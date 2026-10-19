// JOB-03's read of other users' crontabs (03 §7.7, M4 plan M14): in
// admin mode, an elevated listing of the spool, then `crontab -l -u` for
// each valid user name in it, each through the elevation executor. The
// lines become jobs rows like the `cron` stream's, commands masked.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show ElevationException, RemoteCommandException, RemoteCommandResult;

import '../engine/protocol.dart';
import '../sampling/cron_zone.dart';
import '../sampling/sample_results.dart'
    show kCronLinesEvaluated, maskedCronJobs;
import 'admin_mode.dart';

/// The most users whose crontabs one read reads, one elevated command
/// each, in listing order [E]. The rest are counted in
/// [UserCrontabs.notRead].
const kUserCrontabsRead = 64;

/// Reads every listed user's crontab on [serverId] through [session],
/// with runs after [now] in the server zone of [profile].
Future<UserCrontabs> readUserCrontabs(
  String serverId, {
  required String requestId,
  required AdminSession session,
  required HostProfile? profile,
  required DateTime now,
}) async {
  UserCrontabs failed(UserCrontabsFailure failure) =>
      UserCrontabs(serverId: serverId, requestId: requestId, failure: failure);
  Future<RemoteCommandResult> elevated(List<String> argv) =>
      session.executor.run(argv, password: session.password);

  try {
    final listing = await elevated(HostCommands.crontabSpoolList());
    if (listing.exitCode == kCrontabSpoolMissing) {
      return failed(UserCrontabsFailure.noSpool);
    }
    if (listing.exitCode == kCrontabSpoolDenied) {
      return failed(UserCrontabsFailure.spoolDenied);
    }
    final spool = listing.exitCode == kCrontabSpoolListed
        ? parseCrontabSpool(listing.stdout)
        : null;
    if (spool == null) return failed(UserCrontabsFailure.unreadable);

    final users = spool.users.take(kUserCrontabsRead).toList();
    final lines = <CronJob>[];
    final unreadable = <String>[];
    for (final user in users) {
      final result = await elevated(HostCommands.crontabList(user));
      if (result.exitCode == 0) {
        lines.addAll(parseUserCrontab(result.stdout, user: user).value);
        continue;
      }
      // Removed since the listing: crontab(1) says "no crontab for".
      if (result.stderr.toLowerCase().contains('no crontab')) continue;
      unreadable.add(user);
    }

    final server = serverCronZone(profile, now);
    final shown = maskedCronJobs(lines);
    return UserCrontabs(
      serverId: serverId,
      requestId: requestId,
      directory: spool.directory,
      jobs: mergeJobs(
        cron: CronSnapshot(jobs: lines),
        nowUtc: now,
        zone: server.zone,
        zoneFor: (name) => cronTzZone(name, now),
        evaluateLimit: kCronLinesEvaluated,
        shownJob: (job) => shown[job]!,
      ),
      unreadable: unreadable,
      skipped: spool.skipped,
      notRead: spool.users.length - users.length,
      zoneName: server.zoneName,
      zoneFallback: server.fallback,
    );
  } on ElevationException {
    return failed(UserCrontabsFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(UserCrontabsFailure.transport);
  }
}
