import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/docker_actions.dart'
    show StackActionButtons, StackDownButton, StackServiceMenu;
import '../hand_off_actions.dart' show FolderHandOffs, folderHandOffsShown;
import '../panel_kit.dart';
import 'container_badges.dart';
import 'container_details.dart' show openContainerDetails;
import 'containers_view.dart';
import 'docker_notice.dart';
import 'stack_file_view.dart' show openStackFiles;
import 'stack_logs.dart' show openStackLogs;
import 'stacks_view.dart';

/// The name [verdict]'s messages select by.
String verdictName(StackVerdict verdict) => switch (verdict) {
  StackVerifying(waiting: StackWait.channel) => _VerdictKind.waiting,
  StackVerifying() => _VerdictKind.verifying,
  StackVerified() => _VerdictKind.verified,
  StackUnverified() => _VerdictKind.unverified,
  StackSourceNotOnHost() => _VerdictKind.notOnHost,
}.name;

/// The kinds of verdict, whose names [verdict]'s messages select by.
enum _VerdictKind { verifying, waiting, verified, unverified, notOnHost }

/// [verdict] in words, as its chip says it.
String stackVerdictText(AppLocalizations l10n, StackVerdict verdict) =>
    switch (verdict) {
      StackUnverified(:final reason) => l10n.dockerStackUnverified(reason.name),
      StackSourceNotOnHost(deployedBy: final manager?) =>
        l10n.dockerStackNotOnHostDeployedBy(manager.displayName),
      _ => l10n.dockerStackVerdict(verdictName(verdict)),
    };

/// [verdict] as an icon and its words in a tinted pill (STK-01), so
/// colour is never the only cue (A11Y-01).
class StackVerdictChip extends StatelessWidget {
  const StackVerdictChip({super.key, required this.verdict});

  final StackVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (icon, background, foreground) = switch (verdict) {
      StackVerified() => (
        Icons.verified_outlined,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      StackUnverified() => (
        Icons.help_outline,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      StackSourceNotOnHost() => (
        Icons.cloud_off_outlined,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      StackVerifying() => (
        Icons.hourglass_empty,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return _Pill(
      icon: icon,
      text: stackVerdictText(l10n, verdict),
      background: background,
      foreground: foreground,
    );
  }
}

/// STK-10's badge: the manager that owns the stack, which is therefore
/// read-only (03 §8.7).
class StackManagedByBadge extends StatelessWidget {
  const StackManagedByBadge({super.key, required this.marker});

  final OwnershipMarker marker;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Pill(
      icon: Icons.lock_outline,
      text: AppLocalizations.of(
        context,
      ).dockerStackManagedBy(marker.manager.displayName),
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
    );
  }
}

/// An icon and its words in a tinted pill; the words wrap rather than
/// clip in a narrow list.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Icon(icon, size: 14, color: foreground),
            Flexible(
              child: Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A stack's overview on a page of its own, as a phone pushes it (03
/// §10.5), under an app bar that names it. The Stacks sub-tab under it
/// keeps the watch.
class StackOverviewPage extends StatelessWidget {
  const StackOverviewPage({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.project,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String project;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(project)),
    body: SafeArea(
      child: StackOverview(
        monitoring: monitoring,
        serverId: serverId,
        project: project,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      ),
    ),
  );
}

/// One stack's overview (03 §7.16 STK-01, STK-02, STK-10): its verdict
/// and what it means, the managed-by badge naming the label that marks
/// it, where its files are as its labels record them, and its services
/// with their images, containers, states, health and ports. A container
/// opens its details ([openContainerDetails]): in the desktop inspector,
/// or on a page of its own. A verified stack opens its files
/// ([openStackFiles], STK-04); any other says they show only once it is.
///
/// It follows the server's stack list, which the Stacks sub-tab's watch
/// keeps current, and says so once the stack leaves it.
class StackOverview extends StatelessWidget {
  const StackOverview({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.project,
    this.showTitle = false,
    this.padding = EdgeInsets.zero,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The compose project's name.
  final String project;

  /// Whether the stack's name heads the overview, where nothing above it
  /// names the stack.
  final bool showTitle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // a new list (SYN-08).
    final list = monitoring.docker.stacksFor(serverId);
    return ListenableBuilder(
      listenable: list,
      builder: (context, _) => _build(context, list.value.stacks),
    );
  }

  Widget _build(BuildContext context, DockerStacksPayload? stacks) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final found = stackNamed(stacks, project);
    final children = <Widget>[
      if (showTitle)
        Semantics(
          header: true,
          child: Text(project, style: theme.textTheme.titleMedium),
        ),
      if (stacks == null)
        DockerNotice(
          icon: Icons.hourglass_empty,
          text: l10n.dockerStacksReading,
        )
      else if (found == null)
        DockerNotice(icon: Icons.delete_outline, text: l10n.dockerStackGone)
      else
        ..._sections(context, found, stackVerdictOf(stacks, project)),
    ];
    return ListView(
      padding: padding,
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(bottom: 16), child: child),
      ],
    );
  }

  List<Widget> _sections(
    BuildContext context,
    ComposeProject project,
    StackVerdict verdict,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final marker = project.ownership.primary;
    final none = l10n.dockerStackNoneRecorded;
    return [
      MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            StackVerdictChip(verdict: verdict),
            Text(
              l10n.dockerStackVerdictNote(verdictName(verdict)),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      if (marker != null) _ManagedByNote(marker: marker),
      if (actionsAllowedAt(context, serverId, ActionEntryPoint.stackVerb))
        StackActionButtons(serverId: serverId, project: project.name),
      // STK-23's compose operations run on a verified source only.
      if (verdict is StackVerified)
        StackDownButton(serverId: serverId, project: project.name),
      TitledGroup(
        title: l10n.dockerStackSource,
        children: [
          _Fact(
            label: l10n.dockerStackWorkingDir,
            values: [project.workingDir ?? none],
          ),
          // X-04: the folder in Séance and in Poltergeist.
          if (project.workingDir case final folder?
              when folderHandOffsShown(
                context,
                serverId: serverId,
                folder: folder,
              ))
            FolderHandOffs(serverId: serverId, folder: folder),
          _Fact(
            label: l10n.dockerStackConfigFiles,
            values: project.configFiles.isEmpty ? [none] : project.configFiles,
          ),
          if (project.environmentFiles.isNotEmpty)
            _Fact(
              label: l10n.dockerStackEnvFiles,
              values: project.environmentFiles,
            ),
          if (project.version case final version?)
            _Fact(label: l10n.dockerStackComposeVersion, values: [version]),
          if (verdict is StackVerified)
            _Profiles(
              monitoring: monitoring,
              serverId: serverId,
              project: project.name,
            ),
          // STK-04: verified sources only.
          if (verdict is StackVerified)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => openStackFiles(
                  context,
                  monitoring: monitoring,
                  serverId: serverId,
                  project: project,
                ),
                icon: const Icon(Icons.description_outlined),
                label: Text(l10n.dockerStackFilesView),
              ),
            )
          else
            Text(
              l10n.dockerStackFilesUnverified,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      TitledGroup(
        title: l10n.dockerStackServicesHeading,
        children: [
          // CTX-04: every service's logs, merged by time.
          if (project.services.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => openStackLogs(
                  context,
                  monitoring: monitoring,
                  serverId: serverId,
                  project: project,
                ),
                icon: const Icon(Icons.subject),
                label: Text(l10n.dockerStackLogsOpen),
              ),
            ),
          for (final service in project.services)
            _ServiceCard(
              service: service,
              menu: service.oneOff || verdict is! StackVerified
                  ? null
                  : StackServiceMenu(
                      serverId: serverId,
                      project: project.name,
                      service: service.name,
                      replicas: service.containers.length,
                    ),
              onOpen: (container) => openContainerDetails(
                context,
                monitoring: monitoring,
                serverId: serverId,
                container: container,
              ),
            ),
        ],
      ),
    ];
  }
}

/// The managed-by badge over what it means and the label that marks it.
class _ManagedByNote extends StatelessWidget {
  const _ManagedByNote({required this.marker});

  final OwnershipMarker marker;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          StackManagedByBadge(marker: marker),
          Text(
            l10n.dockerStackManagedByNote(
              marker.manager.displayName,
              marker.label,
            ),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The profiles a verified stack's files name (STK-09), read once as
/// the overview opens: STK-23's `--profile` choices.
class _Profiles extends StatefulWidget {
  const _Profiles({
    required this.monitoring,
    required this.serverId,
    required this.project,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String project;

  @override
  State<_Profiles> createState() => _ProfilesState();
}

class _ProfilesState extends State<_Profiles> {
  late final Future<DockerPayload> _read = widget.monitoring.docker
      .readStackProfiles(widget.serverId, project: widget.project);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder(
      future: _read,
      builder: (context, snapshot) => _Fact(
        label: l10n.dockerStackProfiles,
        values: switch (snapshot.data) {
          null => [l10n.dockerStackProfilesReading],
          DockerStackProfilesPayload(:final profiles) when profiles.isEmpty => [
            l10n.dockerStackNoneRecorded,
          ],
          DockerStackProfilesPayload(:final profiles) => profiles,
          _ => [l10n.dockerStackProfilesFailed],
        },
      ),
    );
  }
}

/// A label over its values, one per line, read as one node.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.values});

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          for (final value in values)
            Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// One compose service: its name, a one-off mark, its image, and its
/// containers, each of which opens its details through [onOpen].
class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.service, required this.onOpen, this.menu});

  final ComposeService service;
  final ValueChanged<ContainerSummary> onOpen;

  /// The service's actions (STK-23), beside its name.
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: 12,
                end: menu == null ? 12 : 0,
              ),
              child: Row(
                children: [
                  Expanded(child: _serviceHeader(context)),
                  ?menu,
                ],
              ),
            ),
            for (final container in service.containers)
              _ContainerRow(
                container: container,
                onTap: () => onOpen(container),
              ),
          ],
        ),
      ),
    );
  }

  Widget _serviceHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final image = service.image;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                service.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (service.oneOff)
                Text(
                  l10n.dockerStackOneOff,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
            ],
          ),
          if (image != null && image.isNotEmpty)
            Text(
              image,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
        ],
      ),
    );
  }
}

/// One container of a service: its name, state, health, the engine's
/// status text and its ports, read as one button.
class _ContainerRow extends StatelessWidget {
  const _ContainerRow({required this.container, required this.onTap});

  final ContainerSummary container;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final health = container.health;
    final status = containerStatusText(container);
    final ports = containerPortsText(container);
    return MergeSemantics(
      child: Semantics(
        button: true,
        hint: l10n.dockerStackOpenContainerHint,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            // A touch needs a 48 dp target (A11Y-01); a pointer, the line.
            constraints: BoxConstraints(
              minHeight: ghostIsDesktopPlatform(theme.platform)
                  ? 40
                  : kMinInteractiveDimension,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          containerNameOf(container),
                          style: theme.textTheme.bodyMedium,
                        ),
                        ContainerStateBadge(
                          container: container,
                          style: theme.textTheme.bodySmall,
                        ),
                        if (health != null && health != HealthStatus.none)
                          ContainerHealthBadge(health: health),
                        if (status != null)
                          Text(
                            status,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        if (ports.isNotEmpty)
                          Text(
                            l10n.dockerStackPorts(ports),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: muted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
