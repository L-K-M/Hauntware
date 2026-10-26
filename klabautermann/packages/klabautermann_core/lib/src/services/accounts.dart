// ACC-01 and ACC-02's read (03 §7.9): one command as the login user,
// `getent` for the accounts and groups and `who` for the logins.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, SshLink, quoteShellWord;

import '../engine/protocol.dart';

/// Reads [serverId]'s accounts and logins over [link]. A failure answers
/// rather than throws.
Future<AccountsReport> readAccounts(
  String serverId, {
  required String requestId,
  required SshLink link,
}) async {
  AccountsReport failed(AccountsReportFailure failure) => AccountsReport(
    serverId: serverId,
    requestId: requestId,
    failure: failure,
  );

  final String stdout;
  try {
    final result = await link.run(
      HostCommands.commandLine(HostCommands.accounts(), quote: quoteShellWord),
      stdin: const [],
    );
    stdout = result.stdout;
  } on RemoteCommandException {
    return failed(AccountsReportFailure.transport);
  }
  final snapshot = parseAccounts(stdout);
  if (snapshot == null) return failed(AccountsReportFailure.unreadable);
  return AccountsReport(
    serverId: serverId,
    requestId: requestId,
    snapshot: snapshot,
  );
}
