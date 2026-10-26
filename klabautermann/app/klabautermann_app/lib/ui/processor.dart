import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;

/// Draws a label over its value as the System tab's other facts do; a
/// null value shows as unknown, with [note] saying why.
typedef ProcessorFact =
    Widget Function(String label, String? value, {String? note});

/// CPU-07's section of the System tab: the processor's model and how many
/// sockets, cores and threads it has. It reads when it shows and on
/// request; a server switch reads the new server's. Inside a container
/// ([inContainer]) the counts other than the usable CPUs are the host
/// machine's, so they show as unknown with D50's reason.
class ProcessorSection extends StatefulWidget {
  const ProcessorSection({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.inContainer,
    required this.fact,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool inContainer;
  final ProcessorFact fact;

  @override
  State<ProcessorSection> createState() => _ProcessorSectionState();
}

class _ProcessorSectionState extends State<ProcessorSection> {
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
  void didUpdateWidget(ProcessorSection oldWidget) {
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
      const CpuTopologyQuery(),
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
    return PanelSection(
      title: l10n.systemProcessorTitle,
      children: [
        ..._lines(l10n),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _reading ? null : () => unawaited(_load()),
            child: Text(l10n.systemProcessorReadAgain),
          ),
        ),
      ],
    );
  }

  List<Widget> _lines(AppLocalizations l10n) => switch (_read) {
    null => [
      PanelNotice(
        icon: Icons.hourglass_empty,
        text: l10n.systemProcessorReading,
      ),
    ],
    HostQueryFailed(:final failure, :final detail) => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemProcessorFailed(failure.name),
        detail: detail,
      ),
    ],
    CpuTopologyRead(:final topology) => _facts(l10n, topology),
    _ => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemProcessorFailed(HostQueryFailure.failed.name),
      ),
    ],
  };

  List<Widget> _facts(AppLocalizations l10n, CpuTopology cpu) {
    final fact = widget.fact;
    final model = cpu.models.isEmpty ? cpu.vendor : cpu.models.join('\n');
    // A figure of the host machine's rather than the container's.
    Widget hostCount(String label, int? count) => widget.inContainer
        ? fact(label, null, note: l10n.systemUnknownContainer)
        : fact(label, count?.toString());
    return [
      fact(
        l10n.systemProcessorModel,
        model,
        note: model == null ? l10n.systemProcessorNoModel : null,
      ),
      hostCount(l10n.systemProcessorSockets, cpu.sockets),
      hostCount(l10n.systemProcessorCores, cpu.cores),
      fact(l10n.systemProcessorThreadsPerCore, cpu.threadsPerCore?.toString()),
      hostCount(l10n.systemProcessorLogical, cpu.logicalCpus),
      fact(l10n.systemProcessorUsable, cpu.usableCpus?.toString()),
    ];
  }
}
