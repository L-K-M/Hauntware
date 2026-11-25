import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../panel_kit.dart';
import 'docker_notice.dart';
import 'stack_overview.dart'
    show
        StackManagedByBadge,
        StackOverview,
        StackOverviewPage,
        StackVerdictChip;
import 'stacks_view.dart';
import 'unlisted_stacks.dart';

/// The panel width from which the stacks show as a list beside the
/// selected one's overview; narrower, as on a phone, the list shows alone
/// and a stack opens its overview on a page of its own. It grows with the
/// text scale, as the other sub-tabs' do; a 1280 px desktop window's
/// panel (about 720 px) takes both.
const double _twoPaneWidth = 640;

/// The list's width beside the overview.
const double _listWidth = 280;

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
          child: HeadedPanelBody(
            header: header,
            body: _body(context, stacks, wide: wide),
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
            // Another stack or server starts at its top.
            key: ValueKey((widget.serverId, selected)),
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
