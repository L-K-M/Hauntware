import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'read_section.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;

/// Draws a label over its value as the System tab's other facts do; a
/// null value shows as unknown, with [note] saying why.
typedef ProcessorFact =
    Widget Function(String label, String? value, {String? note});

/// CPU-07's section of the System tab: the processor's model and how many
/// sockets, cores and threads it has. It reads when it shows and on
/// request; a server switch reads the new server's. Inside a container
/// ([inContainer]) the socket, core and logical CPU counts are the host
/// machine's, so they show as unknown with D50's reason; threads per core,
/// a property of each core, and the usable CPUs stay.
class ProcessorSection extends StatefulWidget implements HostReadSection {
  const ProcessorSection({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.inContainer,
    required this.fact,
  });

  @override
  final MonitoringController monitoring;

  @override
  final String serverId;
  final bool inContainer;
  final ProcessorFact fact;

  @override
  State<ProcessorSection> createState() => _ProcessorSectionState();
}

class _ProcessorSectionState extends State<ProcessorSection>
    with HostReadSectionState<ProcessorSection> {
  @override
  HostQuerySpec get hostQuery => const CpuTopologyQuery();

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
            onPressed: hostReading ? null : () => unawaited(readHost()),
            child: Text(l10n.systemProcessorReadAgain),
          ),
        ),
      ],
    );
  }

  List<Widget> _lines(AppLocalizations l10n) => switch (hostRead) {
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
