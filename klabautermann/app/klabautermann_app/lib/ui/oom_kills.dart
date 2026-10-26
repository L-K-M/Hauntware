import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'logs/log_level.dart';
import 'logs/log_query.dart';
import 'logs/log_view.dart';
import 'logs/logs_panel_controller.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;
import 'system_view.dart' show uptimeText;

/// The kernel log lines of an OOM kill's report, from the `invoked
/// oom-killer` line to the kill itself, which MEM-03 links to.
const String kOomLogPattern = 'oom-kill|out of memory|killed process';

/// MEM-03's section of the System tab: how many processes the kernel's
/// OOM killer ended since boot, and which, linked to their kernel log
/// lines. It reads when it shows and on request; a server switch reads
/// the new server's.
class OomKillsSection extends StatefulWidget {
  const OomKillsSection({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  State<OomKillsSection> createState() => _OomKillsSectionState();
}

class _OomKillsSectionState extends State<OomKillsSection> {
  HostPayload? _read;
  bool _reading = false;

  /// Bumped per read, so only the newest answer lands.
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(OomKillsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.monitoring == widget.monitoring) {
      return;
    }
    _read = null;
    unawaited(_load());
  }

  Future<void> _load() async {
    final ticket = ++_ticket;
    if (mounted) setState(() => _reading = true);
    final result = await widget.monitoring.queryHost(
      widget.serverId,
      const OomKillsQuery(),
    );
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _read = result.payload;
      _reading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final read = switch (_read) {
      OomKills(:final read) => read,
      _ => null,
    };
    return PanelSection(
      title: l10n.systemOomTitle,
      children: [
        ..._lines(l10n),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // The log holds the kills' reports, which only the journal can
            // match; dmesg's lines have no source the log viewer reads.
            if (read != null &&
                read.source == OomLogSource.journal &&
                read.kills.isNotEmpty)
              OutlinedButton(
                onPressed: () => _showReports(context),
                child: Text(l10n.systemOomShowLog),
              ),
            OutlinedButton(
              onPressed: _reading ? null : () => unawaited(_load()),
              child: Text(l10n.systemOomReadAgain),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _lines(AppLocalizations l10n) => switch (_read) {
    null => [
      PanelNotice(icon: Icons.hourglass_empty, text: l10n.systemOomReading),
    ],
    HostQueryFailed(:final failure, :final detail) => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemOomFailed(failure.name),
        detail: detail,
      ),
    ],
    OomKills(:final read) => [
      Text(switch (read.killsSinceBoot) {
        final count? => l10n.systemOomCount(count),
        null => l10n.systemOomCountUnknown,
      }),
      if (!read.logRead)
        PanelNotice(icon: Icons.lock_outline, text: l10n.systemOomLogDenied),
      // The newest first, as the kills that matter now.
      for (final kill in read.kills.reversed) _KillLine(kill: kill),
    ],
    _ => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemOomFailed(HostQueryFailure.failed.name),
      ),
    ],
  };

  void _showReports(BuildContext context) => unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 1,
        builder: (context, _) => _KillReports(
          monitoring: widget.monitoring,
          serverId: widget.serverId,
        ),
      ),
    ),
  );
}

/// One killed process: its command and PID, when, how much memory it
/// held and whether a cgroup's limit ran out, read as one node.
class _KillLine extends StatelessWidget {
  const _KillLine({required this.kill});

  final OomKill kill;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final when = switch ((kill.at, kill.sinceBoot)) {
      (final at?, _) => l10n.systemOomKilledAt(at.toLocal()),
      (null, final sinceBoot?) => l10n.systemOomAfterBoot(
        uptimeText(l10n, sinceBoot),
      ),
      _ => null,
    };
    final memory = kill.anonRssKb;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            l10n.systemOomProcess(kill.command, kill.pid),
            style: theme.textTheme.bodyLarge,
          ),
          if (when != null) Text(when),
          if (memory != null)
            Text(l10n.systemOomMemory(ghostFormatBinarySize(memory * 1024))),
          if (kill.cgroupLimit) Text(l10n.systemOomCgroupLimit),
          if (kill.cgroup case final cgroup?) Text(cgroup, style: muted),
        ],
      ),
    );
  }
}

/// The current boot's OOM reports from the journal's kernel lines,
/// through the Logs panel's reading. Closing the sheet closes the read.
class _KillReports extends StatefulWidget {
  const _KillReports({required this.monitoring, required this.serverId});

  final MonitoringController monitoring;
  final String serverId;

  @override
  State<_KillReports> createState() => _KillReportsState();
}

class _KillReportsState extends State<_KillReports> {
  late final LogsPanelController _reading =
      LogsPanelController(
          streams: widget.monitoring.logs,
          serverId: widget.serverId,
        )
        ..apply(
          LogQuery(
            identifier: 'kernel',
            currentBootOnly: true,
            grep: serverLogPattern(
              kOomLogPattern,
              regex: true,
              caseSensitive: false,
            ),
          ),
        )
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
                    l10n.systemOomLogTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.systemOomLogClose,
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
