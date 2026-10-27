import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        DiagnosticBundle,
        DiagnosticBundleQuery,
        HostQueryFailed,
        HostQueryFailure;

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'logs/log_export.dart';

/// [bundle] as the lines of a text file (CN-18, 03 §6.5): a header with
/// when it was read, then each section under a line of `###`, its
/// collector and its status, as a fixture's files hold it, so a report
/// becomes a fixture; the collectors that gave no answer close it.
List<String> diagnosticBundleLines(DiagnosticBundle bundle, DateTime at) => [
  '# Klabautermann diagnostic bundle (HWS/1), read ${at.toUtc().toIso8601String()}',
  for (final section in bundle.sections) ...[
    '### ${section.collector} ${section.status}',
    ...section.text.split('\n'),
  ],
  if (bundle.missing.isNotEmpty) '# no answer: ${bundle.missing.join(' ')}',
];

/// Reads [serverId]'s diagnostic bundle and offers it for export through
/// LOG-10's sheet, redacted unless the user includes secrets (SAF-07).
Future<void> showDiagnosticBundle(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required String serverName,
}) {
  final host = LogExportScope.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SingleChildScrollView(
          child: _DiagnosticBundleSheet(
            monitoring: monitoring,
            host: host,
            serverId: serverId,
            serverName: serverName,
          ),
        ),
      ),
    ),
  );
}

class _DiagnosticBundleSheet extends StatefulWidget {
  const _DiagnosticBundleSheet({
    required this.monitoring,
    required this.host,
    required this.serverId,
    required this.serverName,
  });

  final MonitoringController monitoring;
  final LogExportHost host;
  final String serverId;
  final String serverName;

  @override
  State<_DiagnosticBundleSheet> createState() => _DiagnosticBundleSheetState();
}

class _DiagnosticBundleSheetState extends State<_DiagnosticBundleSheet> {
  late final _read = widget.monitoring.queryHost(
    widget.serverId,
    const DiagnosticBundleQuery(),
  );
  final _at = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return FutureBuilder(
      future: _read,
      builder: (context, snapshot) {
        final payload = snapshot.data?.payload;
        if (payload == null) {
          return Row(
            spacing: 12,
            children: [
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              Expanded(child: Text(l10n.diagnosticsReading)),
            ],
          );
        }

        if (payload is! DiagnosticBundle) {
          final failure = payload is HostQueryFailed
              ? payload.failure
              : HostQueryFailure.failed;
          return Text(
            l10n.diagnosticsFailed(failure.name),
            style: TextStyle(color: theme.colorScheme.error),
          );
        }

        return LogExportSheet(
          monitoring: widget.monitoring,
          host: widget.host,
          lines: diagnosticBundleLines(payload, _at),
          fileName: l10n.diagnosticsFileName,
          title: l10n.diagnosticsTitle(
            widget.serverName,
            payload.sections.length,
          ),
          note: [
            l10n.diagnosticsHint,
            if (payload.missing.isNotEmpty)
              l10n.diagnosticsMissing(payload.missing.join(', ')),
          ].join('\n\n'),
        );
      },
    );
  }
}
