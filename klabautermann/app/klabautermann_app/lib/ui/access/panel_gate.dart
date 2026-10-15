import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../server_surfaces.dart';
import 'access_panel.dart' show DetectedRuntime;

/// What a server panel's tab shows (03 §10.4).
enum PanelGateKind {
  /// The panel itself, also while the probe has not answered: only a
  /// capability the probe found missing hides a panel.
  open,

  /// What the panel lacks, with a link to the Access tab.
  hidden,

  /// The Docker tab until Docker support arrives (M3), with the detected
  /// runtime (CN-09).
  awaitsDocker,
}

/// [decidePanelGate]'s answer.
@immutable
final class PanelGateDecision {
  const PanelGateDecision(this.kind, [this.blocking = const []]);

  final PanelGateKind kind;

  /// What keeps a [PanelGateKind.hidden] panel from working, in the order
  /// its sources prefer.
  final List<Capability> blocking;
}

const _open = PanelGateDecision(PanelGateKind.open);

/// The host panels (K04's capability declarations) each tab shows: Logs
/// reads the journal, the kernel log or a file (LOG-01, LOG-03, LOG-22),
/// so it works while any one does. Docker's panels follow the transport
/// ladder in M3, and the Access tab needs nothing.
List<HostPanel> _hostPanelsOf(ServerPanel panel) => switch (panel) {
  ServerPanel.overview => const [HostPanel.overview],
  ServerPanel.processes => const [HostPanel.processes],
  ServerPanel.services => const [HostPanel.services],
  ServerPanel.logs => const [
    HostPanel.journal,
    HostPanel.kernelLog,
    HostPanel.fileTail,
  ],
  ServerPanel.jobs => const [HostPanel.jobs],
  ServerPanel.system => const [HostPanel.identity],
  ServerPanel.docker || ServerPanel.access => const [],
};

/// Whether [panel] shows itself on the host [profile] describes (null
/// before the probe answers). A panel is hidden only when every host
/// panel behind it is missing something, so a capability the probe did
/// not report never hides one; its contents show "unknown" instead.
PanelGateDecision decidePanelGate(ServerPanel panel, HostProfile? profile) {
  if (panel == ServerPanel.docker) {
    return const PanelGateDecision(PanelGateKind.awaitsDocker);
  }
  final hostPanels = _hostPanelsOf(panel);
  if (profile == null || hostPanels.isEmpty) return _open;

  final access = evaluateAccess(profile);
  final blocking = <Capability>{};
  for (final hostPanel in hostPanels) {
    final availability = evaluatePanel(hostPanel, profile, access);
    if (availability.status != AccessStatus.missing) return _open;
    blocking.addAll(availability.blocking);
  }
  // Reading the whole journal means nothing without journalctl.
  if (blocking.contains(Capability.journalctl)) {
    blocking.remove(Capability.journalAccess);
  }
  return PanelGateDecision(PanelGateKind.hidden, List.unmodifiable(blocking));
}

/// [child], a server panel, or what stands in for it when the access
/// rules hide it or its milestone has not landed (03 §10.4). A hidden
/// panel's [child] is not built, so nothing it subscribes samples.
class GatedPanel extends StatelessWidget {
  const GatedPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.panel,
    required this.onOpenAccess,
    required this.child,
  });

  final MonitoringController monitoring;
  final String serverId;
  final ServerPanel panel;

  /// Shows the Access tab: the workspace selects it, a phone pushes it.
  final VoidCallback onOpenAccess;

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<HostProfile?>(
    valueListenable: monitoring.profileFor(serverId),
    builder: (context, profile, child) {
      final l10n = AppLocalizations.of(context);
      final gate = decidePanelGate(panel, profile);
      return switch (gate.kind) {
        PanelGateKind.open => child!,
        PanelGateKind.hidden => _GateNotice(
          icon: Icons.visibility_off_outlined,
          title: l10n.accessPanelHiddenTitle(panel.label(l10n)),
          onOpenAccess: onOpenAccess,
          children: [
            for (final capability in gate.blocking)
              Text(_capabilityText(l10n, capability)),
          ],
        ),
        PanelGateKind.awaitsDocker => _GateNotice(
          icon: Icons.inventory_2_outlined,
          title: l10n.accessDockerPendingTitle,
          onOpenAccess: onOpenAccess,
          children: [
            Text(l10n.accessDockerPendingBody),
            const SizedBox(height: 8),
            Semantics(
              header: true,
              child: Text(
                l10n.accessDetectedRuntime,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            DetectedRuntime(profile: profile),
          ],
        ),
      };
    },
    child: child,
  );
}

/// A panel's stand-in: an icon, a title, the lines that explain it and
/// the link to the Access tab, centred and scrolling under large text.
class _GateNotice extends StatelessWidget {
  const _GateNotice({
    required this.icon,
    required this.title,
    required this.onOpenAccess,
    required this.children,
  });

  final IconData icon;
  final String title;
  final VoidCallback onOpenAccess;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: textScaler.scale(520)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              ExcludeSemantics(
                child: Icon(
                  icon,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              ...children,
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: onOpenAccess,
                child: Text(AppLocalizations.of(context).accessOpen),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _capabilityText(AppLocalizations l10n, Capability capability) =>
    switch (capability) {
      Capability.systemd => l10n.accessReasonNotSystemd,
      Capability.journalctl => l10n.accessReasonNoJournal,
      Capability.journalAccess => l10n.accessNeedJournalAccess,
      Capability.dmesg => l10n.accessNeedDmesg,
      Capability.tail => l10n.accessNeedTail,
      Capability.crontab => l10n.accessNeedCrontab,
    };
