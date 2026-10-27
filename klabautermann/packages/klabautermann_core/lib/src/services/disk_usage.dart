// DSK-07's folder read (03 §7.3): one `du` over a folder, as the login
// user over the link or, in admin mode, as root through the elevation
// executor, so the sizes take in what the login user may not read.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show
        ElevationException,
        RemoteCommandException,
        RemoteCommandResult,
        SshLink,
        quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import '../engine/protocol.dart';
import '../logs/host_queries.dart' show kHostQueryMaxOutputBytes;

/// How long one folder read may run: `du` walks every file under the
/// folder, which takes minutes on a large tree.
const kDiskUsageTimeout = Duration(minutes: 3);

/// Reads [path] on [serverId]: through [session] when given, else as the
/// login user over [link]. Answers rather than throws.
Future<DiskUsageReport> readDiskUsage(
  String serverId,
  String path, {
  required String requestId,
  required SshLink link,
  AdminSession? session,
  Duration timeout = kDiskUsageTimeout,
}) async {
  DiskUsageReport failed(DiskUsageReportFailure failure) => DiskUsageReport(
    serverId: serverId,
    requestId: requestId,
    path: path,
    failure: failure,
  );

  final List<String> argv;
  try {
    argv = HostCommands.diskUsage(path);
  } on HostCommandError {
    return failed(DiskUsageReportFailure.invalidPath);
  }

  final RemoteCommandResult result;
  try {
    result = switch (session) {
      final session? => await session.executor.run(
        argv,
        password: session.password,
        timeout: timeout,
      ),
      null => await link.run(
        HostCommands.commandLine(argv, quote: quoteShellWord),
        stdin: const [],
        timeout: timeout,
        maxOutputBytes: kHostQueryMaxOutputBytes,
      ),
    };
  } on ElevationException {
    return failed(DiskUsageReportFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(DiskUsageReportFailure.transport);
  }

  final parse = parseDiskUsage(result.stdout, path);
  if (parse.listing case final listing?) {
    return DiskUsageReport(
      serverId: serverId,
      requestId: requestId,
      path: path,
      listing: listing,
    );
  }
  return failed(switch (parse.problem!) {
    DiskUsageProblem.notFound => DiskUsageReportFailure.notFound,
    DiskUsageProblem.denied => DiskUsageReportFailure.denied,
    DiskUsageProblem.unreadable => DiskUsageReportFailure.unreadable,
  });
}
