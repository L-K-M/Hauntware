import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// ACC-01 and ACC-02's reads (03 §7.9): each [read] asks the engine for a
/// server's accounts and logins and completes with its [AccountsReport].
/// A concern of its own for one engine run, beside the monitoring
/// controller. A stopped engine, or one that stops before it answers,
/// answers [AccountsReportFailure.noLink].
final class AccountReads {
  AccountReads(EngineClient engine)
    : _reads = EngineReads(
        engine,
        (event) => switch (event) {
          AccountsReport(:final requestId) => (requestId, event),
          _ => null,
        },
      );

  final EngineReads<AccountsReport> _reads;
  var _count = 0;

  /// [serverId]'s accounts and logins as they are now.
  Future<AccountsReport> read(String serverId) {
    final requestId = 'accounts-${_count++}';
    return _reads.read(
      requestId,
      ReadAccounts(serverId, requestId: requestId),
      () => AccountsReport(
        serverId: serverId,
        requestId: requestId,
        failure: AccountsReportFailure.noLink,
      ),
    );
  }

  void dispose() => _reads.dispose();
}
