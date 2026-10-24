// Ported from Séance app/seance_app/lib/ui/connection_log_view.dart @
// 035b0d8 (tag v0.9.1); see docs/PORTS.md. Since 2026-10-21 the view is
// ghost_servers' GhostConnectionLogView, shared with Séance.
// Divergence: strings localize through ARB (D20); the copy failure is
// reported through ApplicationErrorReporter rather than dart:developer.
import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart' show GhostConnectionLogView;

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'ghost_servers_adapter.dart' show poltergeistConnectionLogStrings;

/// A collapsible view of a raw SSH connection transcript, with a copy button,
/// in this app's words and face.
///
/// Takes the text rather than a session so both places that show a transcript
/// (a failed terminal tab and the server editor's connection test) read the
/// same. Redaction is the producer's contract: `SshConnectionLog` enforces it
/// at capture, so [text] is shown and copied verbatim.
class ConnectionLogView extends StatelessWidget {
  final String text;
  const ConnectionLogView({super.key, required this.text});

  @override
  Widget build(BuildContext context) => GhostConnectionLogView(
    text: text,
    monoStyle: poltergeistMonoTextStyle,
    strings: poltergeistConnectionLogStrings(AppLocalizations.of(context)),
    onCopyError: ApplicationErrorReporter().report,
  );
}
