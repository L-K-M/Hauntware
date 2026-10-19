import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/operations_controller.dart';
import '../../l10n/app_localizations.dart';
import '../sortable_table.dart';

/// The Activity page (SAF-11, 03 §8.10): [serverId]'s device audit log,
/// newest first, as a sortable table of time, target, action, tier and
/// result, with each run's redacted steps in a detail sheet and older
/// records a page at a time. The log never holds a secret, since steps
/// are redacted before they are stored, so Copy exports what the table
/// shows; the app has no file save or share yet.
class ActivityPage extends StatefulWidget {
  const ActivityPage({
    super.key,
    required this.operations,
    required this.serverId,
    required this.serverName,
  });

  final OperationsController operations;
  final String serverId;
  final String serverName;

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

enum _Column { time, target, action, tier, result }

class _ActivityPageState extends State<ActivityPage> {
  final List<AuditRecord> _records = [];
  bool _more = false;
  bool _reading = true;
  TableSort? _sort = TableSort(
    _Column.time.name,
    TableSortDirection.descending,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    setState(() => _reading = true);
    final page = await widget.operations.readAudit(
      widget.serverId,
      before: _records.lastOrNull?.endedAt,
    );
    if (!mounted) return;
    setState(() {
      _records.addAll(page.records);
      _more = page.more;
      _reading = false;
    });
  }

  Future<void> _copy() async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    // One record per line, as the engine's own audit files hold them.
    final text = [
      for (final record in _records) jsonEncode(record.toJson()),
    ].join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.activityCopied);
      }
    } on Exception {
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.activityNotCopied);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final localizations = MaterialLocalizations.of(context);
    String time(AuditRecord r) {
      final local = r.endedAt.toLocal();
      return l10n.activityTime(
        localizations.formatShortDate(local),
        localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local)),
      );
    }

    final columns = [
      SortableTableColumn<AuditRecord>(
        id: _Column.time.name,
        label: l10n.activityColumnTime,
        text: time,
        sortKey: (r) => r.endedAt,
        firstDirection: TableSortDirection.descending,
      ),
      SortableTableColumn<AuditRecord>(
        id: _Column.target.name,
        label: l10n.activityColumnTarget,
        text: (r) => r.targetName,
        extent: const FlexColumnExtent(2),
      ),
      SortableTableColumn<AuditRecord>(
        id: _Column.action.name,
        label: l10n.activityColumnAction,
        text: (r) => l10n.activityAction(r.action),
      ),
      SortableTableColumn<AuditRecord>(
        id: _Column.tier.name,
        label: l10n.activityColumnTier,
        text: (r) => l10n.activityTier(r.tier.name),
      ),
      SortableTableColumn<AuditRecord>(
        id: _Column.result.name,
        label: l10n.activityColumnResult,
        text: (r) => l10n.activityResult(r.outcome.name),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.activityTitle(widget.serverName)),
        actions: [
          IconButton(
            tooltip: l10n.activityCopy,
            icon: const Icon(Icons.copy),
            onPressed: _records.isEmpty ? null : _copy,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Text(l10n.activityDetail),
            if (widget.operations.auditInMemory) Text(l10n.activityInMemory),
            Expanded(
              child: SortableTable<AuditRecord>(
                tableId: 'activity',
                columns: columns,
                rows: _records,
                // Records keep their identity across pages.
                rowKey: (r) => r,
                sort: _sort,
                onSort: (sort) => setState(() => _sort = sort),
                onRowActivated: (record) => _showRecord(context, record),
                empty: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _reading ? l10n.activityReading : l10n.activityEmpty,
                  ),
                ),
              ),
            ),
            if (_more)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _reading ? null : _read,
                  child: Text(l10n.activityOlder),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One run's redacted steps and how it ended.
void _showRecord(BuildContext context, AuditRecord record) {
  final l10n = AppLocalizations.of(context);
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Semantics(
                header: true,
                child: Text(
                  record.targetName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(l10n.activityResult(record.outcome.name)),
              if (record.failure case final failure?)
                Text(l10n.activityFailure(failure.name)),
              if (record.exitCode case final code?)
                Text(l10n.activityExitCode(code)),
              if (record.httpStatus case final status?)
                Text(l10n.activityHttpStatus(status)),
              Semantics(
                header: true,
                child: Text(
                  l10n.activitySteps,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final step in record.steps) SelectableText(step),
            ],
          ),
        ),
      ),
    ),
  );
}
