// NET-06's firewall view (03 §7.4): in admin mode, one elevated read of
// ufw, firewalld, nftables and iptables, whichever are installed.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show ElevationException, RemoteCommandException;

import '../engine/protocol.dart';
import 'admin_mode.dart';

/// Reads [serverId]'s firewall rules through [session].
Future<FirewallReport> readFirewall(
  String serverId, {
  required String requestId,
  required AdminSession session,
}) async {
  FirewallReport failed(FirewallReportFailure failure) => FirewallReport(
    serverId: serverId,
    requestId: requestId,
    failure: failure,
  );
  try {
    final result = await session.executor.run(
      HostCommands.firewall(),
      password: session.password,
    );
    final read = parseFirewall(result.stdout);
    // The script exits 0; a failure that printed no tool's section is a
    // read that failed, not a host without a firewall.
    if (read == null || (read.noTool && result.exitCode != 0)) {
      return failed(FirewallReportFailure.unreadable);
    }
    return FirewallReport(serverId: serverId, requestId: requestId, read: read);
  } on ElevationException {
    return failed(FirewallReportFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(FirewallReportFailure.transport);
  }
}
