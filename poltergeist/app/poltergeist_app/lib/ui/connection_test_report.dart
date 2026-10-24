// Ported from Séance app/seance_app/lib/ui/connection_test_report.dart @
// 035b0d8 (tag v0.9.1); see docs/PORTS.md. Since 2026-10-21 the report is
// ghost_servers' GhostConnectionTestReport, shared with Séance.
// Divergence: strings localize through ARB (D20).
import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart'
    show GhostConnectionTestReport;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'ghost_servers_adapter.dart'
    show
        ghostTestReportOf,
        poltergeistConnectionLogStrings,
        poltergeistConnectionTestStrings;

/// What a "Test connection" attempt found, as the server editor shows it, in
/// this app's words and face.
///
/// Public and standalone so a widget test can assert what each outcome reads
/// like without standing up the delegate.
class ConnectionTestReport extends StatelessWidget {
  final ConnectionTestResult result;
  const ConnectionTestReport({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GhostConnectionTestReport(
      report: ghostTestReportOf(result),
      monoStyle: poltergeistMonoTextStyle,
      strings: poltergeistConnectionTestStrings(l10n),
      logStrings: poltergeistConnectionLogStrings(l10n),
      onCopyError: ApplicationErrorReporter().report,
    );
  }
}
