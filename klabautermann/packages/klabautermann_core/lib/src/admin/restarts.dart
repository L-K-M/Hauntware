// PKG-04's services needing restart (03 §7.8): in admin mode, the first
// of needrestart, needs-restarting and zypper ps run as root through the
// elevation executor, since each reads every process's memory maps.
import 'package:klabautermann_host/klabautermann_host.dart'
    show HostCommands, parseRestartCheck;
import 'package:seance_core/seance_core.dart'
    show ElevationException, RemoteCommandException;

import '../engine/protocol.dart';
import 'admin_mode.dart';

/// Reads [serverId]'s services needing restart through [session].
Future<RestartReport> readRestarts(
  String serverId, {
  required String requestId,
  required AdminSession session,
}) async {
  RestartReport failed(RestartReportFailure failure) =>
      RestartReport(serverId: serverId, requestId: requestId, failure: failure);
  try {
    final result = await session.executor.run(
      HostCommands.restartCheck(),
      password: session.password,
    );
    final check = parseRestartCheck(result.stdout);
    if (check.tool == null) return failed(RestartReportFailure.missing);
    return RestartReport(
      serverId: serverId,
      requestId: requestId,
      check: check,
    );
  } on ElevationException {
    return failed(RestartReportFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(RestartReportFailure.transport);
  }
}
