import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../l10n/app_localizations.dart';
import '../logs/log_query.dart';
import '../logs/logs_panel_controller.dart';

/// The span a chosen range starts with, back from now.
const _defaultChosenSpan = Duration(hours: 1);

/// CTX-03's time range for a container's logs: a menu of LOG-01's spans
/// and a chosen start and end, which reads [panel] anew.
class ContainerLogRangeButton extends StatelessWidget {
  const ContainerLogRangeButton({
    super.key,
    required this.panel,
    this.now = DateTime.now,
  });

  final LogsPanelController panel;

  /// The clock a chosen range's first suggestion counts back from.
  final DateTime Function() now;

  Future<void> _choose(BuildContext context) async {
    final current = panel.range;
    final until = current.until ?? now();
    final chosen = await showDialog<ContainerLogRange>(
      context: context,
      builder: (context) => _RangeDialog(
        since: current.since ?? until.subtract(_defaultChosenSpan),
        until: until,
      ),
    );
    if (chosen != null) panel.setRange(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final range = panel.range;
    final label = range.chosen
        ? l10n.dockerLogsRangeBetween(
            _format(l10n, range.since!),
            _format(l10n, range.until!),
          )
        : l10n.logsPanelTimeRangeOption(range.span.name);

    return MenuAnchor(
      menuChildren: [
        for (final span in LogTimeRange.values)
          MenuItemButton(
            onPressed: () => panel.setRange(ContainerLogRange(span)),
            leadingIcon: Icon(
              !range.chosen && range.span == span
                  ? Icons.check
                  : Icons.schedule,
            ),
            child: Text(l10n.logsPanelTimeRangeOption(span.name)),
          ),
        MenuItemButton(
          onPressed: () => unawaited(_choose(context)),
          leadingIcon: Icon(range.chosen ? Icons.check : Icons.date_range),
          child: Text(l10n.dockerLogsRangeChoose),
        ),
      ],
      builder: (context, menu, _) => OutlinedButton.icon(
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.schedule),
        label: Text(label),
        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }
}

String _format(AppLocalizations l10n, DateTime at) =>
    DateFormat.yMMMd(l10n.localeName).add_Hm().format(at.toLocal());

/// Asks for a range's start and end, each a date and a time.
class _RangeDialog extends StatefulWidget {
  const _RangeDialog({required this.since, required this.until});

  final DateTime since, until;

  @override
  State<_RangeDialog> createState() => _RangeDialogState();
}

class _RangeDialogState extends State<_RangeDialog> {
  late DateTime _since = widget.since.toLocal();
  late DateTime _until = widget.until.toLocal();

  bool get _ordered => _since.isBefore(_until);

  Future<DateTime?> _pick(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.dockerLogsRangeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.dockerLogsRangeFrom),
            subtitle: Text(_format(l10n, _since)),
            trailing: const Icon(Icons.edit_calendar),
            onTap: () async {
              final picked = await _pick(_since);
              if (picked != null) setState(() => _since = picked);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.dockerLogsRangeTo),
            subtitle: Text(_format(l10n, _until)),
            trailing: const Icon(Icons.edit_calendar),
            onTap: () async {
              final picked = await _pick(_until);
              if (picked != null) setState(() => _until = picked);
            },
          ),
          if (!_ordered)
            Text(
              l10n.dockerLogsRangeOrder,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.dockerLogsRangeCancel),
        ),
        FilledButton(
          onPressed: _ordered
              ? () => Navigator.pop(
                  context,
                  ContainerLogRange.between(
                    since: _since.toUtc(),
                    until: _until.toUtc(),
                  ),
                )
              : null,
          child: Text(l10n.dockerLogsRangeApply),
        ),
      ],
    );
  }
}
