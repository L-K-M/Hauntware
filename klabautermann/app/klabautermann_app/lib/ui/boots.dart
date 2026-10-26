import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'logs/logs_panel.dart' show localTimeText;
import 'system_panel.dart' show PanelSection;
import 'system_view.dart' show uptimeText;

/// The most boots the section lists: the current one and the earlier ones
/// whose ends [BootEndsQuery] reads.
const kBootsListed = kBootEndsRead + 1;

/// One boot of BOOT-02's timeline: when its journal starts and ends, and
/// how it ended; [end] is null for the current boot and for boots older
/// than the ends read.
typedef BootRow = ({JournalBootEntry boot, BootEnd? end});

/// The newest [kBootsListed] of [boots], newest first, each with its end
/// from [ends].
List<BootRow> bootRows(
  List<JournalBootEntry> boots,
  Map<String, BootEnd> ends,
) => [
  for (final boot
      in (boots.toList()..sort((a, b) => b.offset.compareTo(a.offset))).take(
        kBootsListed,
      ))
    (boot: boot, end: boot.offset < 0 ? ends[boot.id] : null),
];

/// BOOT-02 and BOOT-03's section of the System tab: whether the running
/// kernel is the newest installed, and the boots with how long each ran
/// and whether it ended cleanly. It reads when it shows and on request;
/// a server switch reads the new server's.
class BootsSection extends StatefulWidget {
  const BootsSection({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  State<BootsSection> createState() => _BootsSectionState();
}

class _BootsSectionState extends State<BootsSection> {
  HostPayload? _kernels;
  HostPayload? _boots;
  HostPayload? _ends;
  bool _reading = false;
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    _reading = true;
    unawaited(_read());
  }

  @override
  void didUpdateWidget(BootsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.monitoring == widget.monitoring) {
      return;
    }
    _kernels = _boots = _ends = null;
    unawaited(_read());
  }

  /// The three reads one after another, so the section takes one channel
  /// at a time on a server that allows few.
  Future<void> _read() async {
    // A read for an earlier server, or an earlier read, answers late.
    final ticket = ++_ticket;
    if (!_reading) setState(() => _reading = true);
    final serverId = widget.serverId;
    Future<HostPayload?> query(HostQuerySpec spec) async {
      final result = await widget.monitoring.queryHost(serverId, spec);
      return mounted && ticket == _ticket ? result.payload : null;
    }

    final kernels = await query(const KernelsQuery());
    if (kernels == null) return;
    setState(() => _kernels = kernels);
    final boots = await query(const BootsQuery());
    if (boots == null) return;
    setState(() => _boots = boots);
    final ends = await query(const BootEndsQuery());
    if (ends == null) return;
    setState(() {
      _ends = ends;
      _reading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PanelSection(
      title: l10n.systemBootsTitle,
      children: [
        ..._kernelLines(l10n),
        ..._bootLines(context, l10n),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _reading ? null : () => unawaited(_read()),
            child: Text(l10n.systemBootsReadAgain),
          ),
        ),
      ],
    );
  }

  /// BOOT-03: the running kernel and whether a reboot loads another.
  List<Widget> _kernelLines(AppLocalizations l10n) {
    switch (_kernels) {
      case null:
        return [Text(l10n.systemBootsReading)];
      case HostQueryFailed(:final failure):
        return [Text(l10n.systemKernelFailed(failure.name))];
      case Kernels(:final check):
        final pending = switch (check.state) {
          KernelCheckState.newerInstalled ||
          KernelCheckState.runningRemoved => true,
          KernelCheckState.current || KernelCheckState.unknown => false,
        };
        return [
          Text(l10n.systemKernelRunning(check.running)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              if (pending)
                Icon(
                  Icons.restart_alt,
                  size: 20,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              Expanded(
                child: Text(
                  l10n.systemKernelState(
                    check.state.name,
                    check.newest ?? check.running,
                  ),
                ),
              ),
            ],
          ),
        ];
      case _:
        return [Text(l10n.systemKernelFailed(HostQueryFailure.failed.name))];
    }
  }

  /// BOOT-02: the boots newest first, or why they are not listed.
  List<Widget> _bootLines(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final heading = Semantics(
      header: true,
      child: Text(
        l10n.systemBootsTimelineTitle,
        style: theme.textTheme.labelLarge,
      ),
    );
    switch (_boots) {
      case null:
        return _kernels == null
            ? const []
            : [heading, Text(l10n.systemBootsReading)];
      case HostQueryFailed(:final failure):
        return [heading, Text(l10n.logsPanelBootsFailed(failure.name))];
      case JournalBoots(:final boots):
        final ends = switch (_ends) {
          BootEnds(:final ends) => ends,
          _ => const <String, BootEnd>{},
        };
        final rows = bootRows(boots, ends);
        final endsFailed = _ends is HostQueryFailed;
        return [
          heading,
          if (rows.isEmpty) Text(l10n.systemBootsNone),
          for (final row in rows) _BootLine(row: row),
          if (boots.length > rows.length)
            Text(l10n.systemBootsNotListed(boots.length - rows.length)),
          if (endsFailed) Text(l10n.systemBootEndsUnknown),
        ];
      case _:
        return [
          heading,
          Text(l10n.logsPanelBootsFailed(HostQueryFailure.failed.name)),
        ];
    }
  }
}

/// One boot: which, when it started and how long it ran, and how it
/// ended once that is read.
class _BootLine extends StatelessWidget {
  const _BootLine({required this.row});

  final BootRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (:boot, :end) = row;
    final first = boot.firstEntry, last = boot.lastEntry;
    final name = boot.offset == 0
        ? l10n.systemBootsCurrent
        : l10n.logsPanelBootPast(-boot.offset);
    final span = first == null || last == null
        ? null
        : l10n.systemBootsSpan(
            localTimeText(context, l10n, first),
            uptimeText(l10n, last.difference(first)),
          );
    final unclean = end == BootEnd.unclean;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(
            unclean
                ? Icons.warning_amber
                // The running boot has not ended.
                : boot.offset == 0
                ? Icons.play_circle_outline
                : Icons.power_settings_new,
            size: 20,
            color: unclean
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name),
                if (span != null) Text(span, style: theme.textTheme.bodySmall),
                if (end != null)
                  Text(
                    l10n.systemBootEnd(end.name),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: unclean ? theme.colorScheme.error : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
