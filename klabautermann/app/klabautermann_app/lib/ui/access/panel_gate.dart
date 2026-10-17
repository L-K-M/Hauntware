import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../docker/docker_endpoint.dart' show dockerFailureText;
import '../docker/docker_endpoint_picker.dart';
import '../server_surfaces.dart';

/// What a server panel's tab shows (03 §10.4).
enum PanelGateKind {
  /// The panel itself, also while the probe has not answered: only a
  /// capability the probe found missing hides a panel.
  open,

  /// What the panel lacks, with a link to the Access tab.
  hidden,
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
/// so it works while any one does. The Docker tab follows its endpoint
/// instead (03 §5.9; [GatedPanel]), and the Access tab needs nothing.
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
/// rules hide it (03 §10.4). The Docker tab follows its server's endpoint
/// rather than the probe (03 §5.9): progress while the engine waits for
/// the link or looks for a route, the exact reason with a link to Access
/// and CN-09's socket picker when none works, and the panel once the
/// endpoint is ready. A panel that does not show is not built, so nothing
/// it subscribes or reads runs.
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
  Widget build(BuildContext context) {
    if (panel == ServerPanel.docker) return _buildDocker(context);

    return ValueListenableBuilder<HostProfile?>(
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
        };
      },
      child: child,
    );
  }

  // Re-read on every build, as the header does: a server that left the
  // fleet and came back has a new endpoint listenable (SYN-08).
  Widget _buildDocker(BuildContext context) =>
      ValueListenableBuilder<DockerEndpointState?>(
        valueListenable: monitoring.docker.endpointFor(serverId),
        builder: (context, state, child) {
          final l10n = AppLocalizations.of(context);
          return switch (state) {
            DockerEndpointState(phase: DockerEndpointPhase.ready) => child!,
            DockerEndpointState(phase: DockerEndpointPhase.resolving) =>
              _GateNotice(
                icon: Icons.travel_explore,
                title: l10n.dockerGateResolvingTitle,
                children: [Text(l10n.dockerGateResolvingBody)],
              ),
            // The socket picker too: a socket the engine did not find, or
            // a chosen one that fails, is changed here (CN-09).
            DockerEndpointState(phase: DockerEndpointPhase.failed) =>
              _GateNotice(
                icon: Icons.visibility_off_outlined,
                title: l10n.accessPanelHiddenTitle(panel.label(l10n)),
                onOpenAccess: onOpenAccess,
                onRetry: () => monitoring.docker.retry(serverId),
                children: [
                  Text(dockerFailureText(l10n, state)),
                  DockerEndpointPicker(
                    docker: monitoring.docker,
                    profile: monitoring.profileFor(serverId),
                    serverId: serverId,
                  ),
                ],
              ),
            // Until the engine says anything this run, which it does once
            // the server's link is up.
            DockerEndpointState(phase: DockerEndpointPhase.waiting) ||
            null => _GateNotice(
              icon: Icons.hourglass_empty,
              title: l10n.dockerGateWaitingTitle,
              children: [Text(l10n.dockerGateWaitingBody)],
            ),
          };
        },
        child: child,
      );
}

/// A panel's stand-in: an icon, a title, the lines that explain it and
/// the link to the Access tab, centred and scrolling under large text.
/// A notice without [onOpenAccess] has no link, and [onRetry] adds a
/// button that asks again.
class _GateNotice extends StatelessWidget {
  const _GateNotice({
    required this.icon,
    required this.title,
    this.onOpenAccess,
    this.onRetry,
    required this.children,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onOpenAccess;
  final VoidCallback? onRetry;
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
              if (onOpenAccess != null || onRetry != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onOpenAccess case final onOpenAccess?)
                      FilledButton.tonal(
                        onPressed: onOpenAccess,
                        child: Text(AppLocalizations.of(context).accessOpen),
                      ),
                    if (onRetry case final onRetry?)
                      TextButton(
                        onPressed: onRetry,
                        child: Text(AppLocalizations.of(context).dockerRetry),
                      ),
                  ],
                ),
              ],
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
