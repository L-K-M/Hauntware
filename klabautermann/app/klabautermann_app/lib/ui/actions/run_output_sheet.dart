import 'package:flutter/material.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../logs/log_level.dart';
import '../logs/log_query.dart';
import '../logs/log_view.dart';
import '../logs/logs_panel_controller.dart';

/// JOB-08's output (03 §7.7): [unit]'s journal on [serverId], followed
/// live in a bottom sheet from shortly before the run, through the Logs
/// panel's reading. Closing the sheet closes the follow.
Future<void> showRunOutput(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required String unit,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 1,
    builder: (context, _) =>
        _RunOutput(monitoring: monitoring, serverId: serverId, unit: unit),
  ),
);

class _RunOutput extends StatefulWidget {
  const _RunOutput({
    required this.monitoring,
    required this.serverId,
    required this.unit,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String unit;

  @override
  State<_RunOutput> createState() => _RunOutputState();
}

class _RunOutputState extends State<_RunOutput> {
  // The last quarter hour holds the run's start, which the engine reports
  // only once the run ends; a follow reads on from the newest record.
  late final LogsPanelController _reading =
      LogsPanelController(
          streams: widget.monitoring.logs,
          serverId: widget.serverId,
        )
        ..apply(LogQuery(unit: widget.unit, range: LogTimeRange.last15Minutes))
        ..setLive(true)
        ..setVisible(true);

  @override
  void dispose() {
    _reading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.jobsRunOutputTitle(widget.unit),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.jobsRunOutputClose,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Expanded(
            child: LogView(
              controller: _reading.logs,
              levelOf: LogLevel.ofJournalLine,
            ),
          ),
        ],
      ),
    );
  }
}
