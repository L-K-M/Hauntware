import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/docker_actions.dart'
    show StackActionButtons, StackDownButton, StackServiceMenu;
import '../hand_off_actions.dart' show FolderHandOffs, folderHandOffsShown;
import 'container_details.dart' show openContainerDetails;
import 'containers_panel.dart'
    show ContainerHealthBadge, ContainerStateBadge, DockerNotice;
import 'containers_view.dart';
import 'stack_file_view.dart' show openStackFiles;
import 'stacks_view.dart';
import 'unlisted_stacks.dart';
import 'stack_logs.dart' show openStackLogs;

/// The panel width from which the stacks show as a list beside the
/// selected one's overview; narrower, as on a phone, the list shows alone
/// and a stack opens its overview on a page of its own. It grows with the
/// text scale, as the other sub-tabs' do; a 1280 px desktop window's
/// panel (about 720 px) takes both.
const double _twoPaneWidth = 640;

/// The list's width beside the overview.
const double _listWidth = 280;

/// The share of its height the header takes before it scrolls, so large
/// text never pushes the list out of sight.
const double _headerShare = 0.4;

/// A stack the command palette asked to open (PLT-07); [serial] tells
/// two requests for the same stack apart.
typedef StackRequest = ({String project, int serial});

/// The Stacks sub-tab (03 §7.16 STK-01, STK-02, STK-05, STK-10): every
/// compose project the engine groups the containers into, each with its
/// source verdict ("verified source", "unverified source" with why, or
/// "source not on host", naming the manager that deployed it), the
/// managed-by badge of an owned stack, which is read-only, and its
/// counts; the compose CLIs found, the standalone one read-only; and the
/// selected stack's overview ([StackOverview]).
///
/// While [visible], it holds the server's stack watch
/// ([DockerController.watchStacks]), which starts the engine's source
/// checks on the host; hidden, it lets the watch go, so nothing runs
/// compose for a sub-tab nobody sees. A failed read keeps the last list
/// under why it failed.
class StacksPanel extends StatefulWidget {
  const StacksPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
    this.request,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  /// The stack last asked for, which the panel selects, or opens on a
  /// page of its own in the narrow layout, when it arrives.
  final StackRequest? request;

  @override
  State<StacksPanel> createState() => _StacksPanelState();
}

class _StacksPanelState extends State<StacksPanel> {
  /// The server whose stack watch this panel holds, if any.
  String? _held;

  /// The stack the wide layout's overview shows, by name; the first one
  /// when unset or gone. It outlives sub-tab switches.
  String? _selected;

  /// The stack asked for, whose page the narrow layout has yet to open.
  String? _pendingPage;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _sync();
    _follow(widget.request);
  }

  @override
  void didUpdateWidget(StacksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId) {
      // Another server's stacks.
      _release();
      _selected = null;
      _pendingPage = null;
    }
    _sync();
    if (widget.request != oldWidget.request) _follow(widget.request);
  }

  void _follow(StackRequest? request) {
    if (request == null) return;
    _selected = request.project;
    _pendingPage = request.project;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    _docker.watchStacks(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.unwatchStacks(held);
  }

  void _openPage(String project) => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => StackOverviewPage(
          monitoring: widget.monitoring,
          serverId: widget.serverId,
          project: project,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final stacks = _docker.stacksFor(widget.serverId);
    final endpoint = _docker.endpointFor(widget.serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([stacks, endpoint]),
      builder: (context, _) => _build(context, stacks.value, endpoint.value),
    );
  }

  Widget _build(
    BuildContext context,
    DockerStackList list,
    DockerEndpointState? endpoint,
  ) {
    final l10n = AppLocalizations.of(context);
    final stacks = list.stacks;
    final failure = list.failure;
    final cli = stacks?.composeCli;

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >=
            MediaQuery.textScalerOf(context).scale(_twoPaneWidth);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            // On the socket forward the events stream costs no session,
            // so low-session mode changes nothing the list shows.
            if ((endpoint?.lowSession ?? false) &&
                endpoint?.route?.rank != DockerRank.streamlocal)
              DockerNotice(
                icon: Icons.speed_outlined,
                text: l10n.dockerStacksLowSessionRelay,
              ),
            if (failure != null) ...[
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerStacksFailed(failure.failure.name),
                detail: failure.detail,
                action: TextButton(
                  onPressed: () => _docker.retryStacks(widget.serverId),
                  child: Text(l10n.dockerRetry),
                ),
              ),
              if (stacks != null)
                DockerNotice(icon: Icons.history, text: l10n.dockerStacksKept),
            ] else if (stacks == null)
              DockerNotice(
                icon: Icons.hourglass_empty,
                text: l10n.dockerStacksReading,
              ),
            if (cli != null) StackCliLine(cli: cli),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (stacks == null) {
          return SingleChildScrollView(padding: padding, child: header);
        }

        return Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * _headerShare,
                  ),
                  child: SingleChildScrollView(child: header),
                ),
                const SizedBox(height: 12),
                Expanded(child: _body(context, stacks, wide: wide)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    DockerStacksPayload stacks, {
    required bool wide,
  }) {
    final l10n = AppLocalizations.of(context);
    final projects = stacks.grouping.projects;
    if (projects.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.dockerStacksEmpty),
          ),
          _unlisted(projects),
        ],
      );
    }

    if (!wide) {
      // A requested stack opens on its page once the list shows.
      if (_pendingPage case final project?) {
        _pendingPage = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openPage(project);
        });
      }
      return _list(stacks, selected: null, onOpen: _openPage);
    }

    // The wide layout shows the requested stack as [_selected].
    _pendingPage = null;

    final selected = switch (_selected) {
      final name? when stackNamed(stacks, name) != null => name,
      _ => projects.first.name,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _listWidth,
          child: _list(
            stacks,
            selected: selected,
            onOpen: (project) => setState(() => _selected = project),
          ),
        ),
        const VerticalDivider(width: 32),
        Expanded(
          child: StackOverview(
            // Another stack starts at its top.
            key: ValueKey(selected),
            monitoring: widget.monitoring,
            serverId: widget.serverId,
            project: selected,
            showTitle: true,
          ),
        ),
      ],
    );
  }

  Widget _unlisted(List<ComposeProject> projects) => UnlistedStacks(
    key: ValueKey('stacks.unlisted.${widget.serverId}'),
    monitoring: widget.monitoring,
    serverId: widget.serverId,
    projects: projects,
  );

  /// The stacks by name, [selected] marked in the wide layout.
  Widget _list(
    DockerStacksPayload stacks, {
    required String? selected,
    required ValueChanged<String> onOpen,
  }) {
    final projects = stacks.grouping.projects;
    // The tiles paint their selection and splashes on a Material of their
    // own, above whatever colours the panel.
    return Material(
      type: MaterialType.transparency,
      child: ListView.separated(
        // The stacks, then the ones without containers (STK-08).
        itemCount: projects.length + 1,
        separatorBuilder: (context, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == projects.length) return _unlisted(projects);
          final project = projects[index];
          return _StackTile(
            key: ValueKey('stacks.row.${project.name}'),
            project: project,
            verdict: stackVerdictOf(stacks, project.name),
            selected: selected == null ? null : selected == project.name,
            onTap: () => onOpen(project.name),
          );
        },
      ),
    );
  }
}

/// One stack's row: its name, its verdict chip and managed-by badge, and
/// its counts. [selected] is null where a row opens a page instead.
class _StackTile extends StatelessWidget {
  const _StackTile({
    super.key,
    required this.project,
    required this.verdict,
    required this.selected,
    required this.onTap,
  });

  final ComposeProject project;
  final StackVerdict verdict;
  final bool? selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final counts = stackCountsOf(project);
    final marker = project.ownership.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    return MergeSemantics(
      child: Semantics(
        hint: selected == null ? l10n.dockerStackOpenHint : null,
        child: ListTile(
          selected: selected ?? false,
          selectedTileColor: theme.colorScheme.secondaryContainer.withValues(
            alpha: 0.5,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          onTap: onTap,
          title: Text(
            project.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          trailing: selected == null ? const Icon(Icons.chevron_right) : null,
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    StackVerdictChip(verdict: verdict),
                    if (marker != null) StackManagedByBadge(marker: marker),
                  ],
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l10n.dockerStackServices(counts.services),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    Text(
                      l10n.dockerStackRunning(counts.up, counts.containers),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    if (counts.unhealthy > 0)
                      _Unhealthy(count: counts.unhealthy),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How many containers report unhealthy, as an icon and words in the
/// error colour, so colour is never the only cue (A11Y-01).
class _Unhealthy extends StatelessWidget {
  const _Unhealthy({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(Icons.error_outline, size: 14, color: color),
        Flexible(
          child: Text(
            AppLocalizations.of(context).dockerStackUnhealthy(count),
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// STK-05's line: the compose plugin's version and the standalone
/// binary's, which Klabautermann only reads with, or that the host has
/// neither, so no stack verifies.
class StackCliLine extends StatelessWidget {
  const StackCliLine({super.key, required this.cli});

  final DockerComposeCli cli;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final plugin = cli.pluginVersion;
    final standalone = cli.standaloneVersion;
    final facts = [
      if (plugin != null) l10n.dockerStacksCliPlugin(plugin),
      if (standalone != null)
        l10n.dockerStacksCliStandalone(
          cli.standaloneLegacy.toString(),
          standalone,
        ),
      if (plugin == null && standalone == null) l10n.dockerStacksCliNone,
    ];
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(
            Icons.terminal,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          Expanded(
            child: Wrap(
              spacing: 16,
              runSpacing: 2,
              children: [
                Text(
                  l10n.dockerStacksCliLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                for (final fact in facts)
                  Text(fact, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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

/// [verdict] in words, as its chip says it.
String stackVerdictText(AppLocalizations l10n, StackVerdict verdict) =>
    switch (verdict) {
      StackUnverified(:final reason) => l10n.dockerStackUnverified(reason.name),
      StackSourceNotOnHost(deployedBy: final manager?) =>
        l10n.dockerStackNotOnHostDeployedBy(manager.displayName),
      _ => l10n.dockerStackVerdict(_verdictName(verdict)),
    };

/// The kinds of verdict, whose names [verdict]'s messages select by.
enum _VerdictKind { verifying, waiting, verified, unverified, notOnHost }

/// The name [verdict]'s messages select by.
String _verdictName(StackVerdict verdict) => switch (verdict) {
  StackVerifying(waiting: StackWait.channel) => _VerdictKind.waiting,
  StackVerifying() => _VerdictKind.verifying,
  StackVerified() => _VerdictKind.verified,
  StackUnverified() => _VerdictKind.unverified,
  StackSourceNotOnHost() => _VerdictKind.notOnHost,
}.name;

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
              l10n.dockerStackVerdictNote(_verdictName(verdict)),
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
      _Section(
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
      _Section(
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

/// A heading over its [children], read as a heading.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      Semantics(
        container: true,
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      ...children,
    ],
  );
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
            constraints: const BoxConstraints(minHeight: 40),
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
