import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart'
    show GhostConnectionTestReport;
import 'package:seance_core/seance_core.dart';

import '../theme.dart' show SeanceTheme;
import 'ghost_servers_adapter.dart'
    show ghostTestReportOf, logConnectionLogCopyError;

/// What a "Test connection" attempt found, as the server editor shows it:
/// ghost_servers' [GhostConnectionTestReport] in Séance's words and face.
///
/// Public and standalone so a widget test can assert what each outcome reads
/// like without standing up an `AppState`.
class ConnectionTestReport extends StatelessWidget {
  final ConnectionTestResult result;
  const ConnectionTestReport({super.key, required this.result});

  @override
  Widget build(BuildContext context) => GhostConnectionTestReport(
    report: ghostTestReportOf(result),
    monoStyle: SeanceTheme.mono,
    onCopyError: logConnectionLogCopyError,
  );
}
