import 'dart:async' show unawaited;
import 'dart:convert' show LineSplitter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:ghost_ui/ghost_ui.dart' show ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../controllers/log_reads.dart';
import '../../theme/app_theme.dart'
    show klabautermannMonoStyle, klabautermannThemeStyle;
import '../actions/action_entry.dart';
import '../logs/log_export.dart' show showExportSheet;
import '../actions/docker_actions.dart'
    show ContainerActionButtons, containerActionsShown;
import '../processes_view.dart' show argumentText, clipProcessText;
import '../time_display.dart';
import '../timed_reveal.dart';
import '../workspace_dock.dart';
import 'container_details_view.dart';
import 'container_diagnosis.dart';
import 'container_links.dart';
import 'container_command.dart';
import 'container_logs.dart';
import 'container_processes.dart';
import 'container_terminal.dart';
import 'containers_panel.dart' show ContainerHealthBadge, DockerNotice;
import 'container_usage_charts.dart';
import 'containers_view.dart';
import 'images_view.dart' show shortImageId;

/// The container the desktop inspector shows (03 §10.2): the row opened
/// on [serverId], as listed then.
@immutable
final class InspectedContainer {
  const InspectedContainer({required this.serverId, required this.container});

  final String serverId;
  final ContainerSummary container;
}

/// Hands the desktop inspector's container to the Containers sub-tab,
/// which opens one, and to the inspector, which shows it. The desktop
/// shell holds it above both; without one, as on a phone, details open
/// on a page of their own.
class ContainerInspectionScope
    extends InheritedNotifier<ValueNotifier<InspectedContainer?>> {
  const ContainerInspectionScope({
    super.key,
    required ValueNotifier<InspectedContainer?> inspection,
    required super.child,
  }) : super(notifier: inspection);

  /// The inspection, rebuilding [context] as it changes.
  static ValueNotifier<InspectedContainer?>? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ContainerInspectionScope>()
          ?.notifier;

  /// The inspection, without rebuilding [context] as it changes: what a
  /// row that opens a container reads.
  static ValueNotifier<InspectedContainer?>? find(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<ContainerInspectionScope>()
          ?.notifier;
}

/// Opens [container]'s details (03 §7.12 CTR-03, CTR-04): in the desktop
/// inspector where there is one, otherwise on a pushed page (03 §10.5:
/// details push further).
void openContainerDetails(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required ContainerSummary container,
}) {
  if (ContainerInspectionScope.find(context) case final inspection?) {
    inspection.value = InspectedContainer(
      serverId: serverId,
      container: container,
    );
    return;
  }

  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ContainerDetailsPage(
          monitoring: monitoring,
          serverId: serverId,
          container: container,
        ),
      ),
    ),
  );
}

/// The desktop inspector's body while it shows a container: its name, a
/// button that opens its logs ([openContainerLogs]), one that swaps its
/// details for a [ContainerShellPane] where actions are allowed (CTX-07),
/// and a close button. It takes keyboard focus as it opens, so the
/// details are read next, and Escape inside it closes it, except from a
/// shell pane, whose terminal hands Escape to the container.
///
/// The shell pane goes, closing its shell, when another container shows
/// or actions on the server stop being allowed.
class ContainerInspectorBody extends StatefulWidget {
  const ContainerInspectorBody({
    super.key,
    required this.monitoring,
    required this.inspected,
    required this.onClose,
  });

  final MonitoringController monitoring;
  final InspectedContainer inspected;
  final VoidCallback onClose;

  @override
  State<ContainerInspectorBody> createState() => _ContainerInspectorBodyState();
}

class _ContainerInspectorBodyState extends State<ContainerInspectorBody> {
  final _close = FocusNode();
  bool _shell = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _close.requestFocus();
    });
  }

  @override
  void didUpdateWidget(ContainerInspectorBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.inspected;
    if (old.serverId != widget.inspected.serverId ||
        old.container.id != widget.inspected.container.id) {
      _shell = false;
    }
  }

  @override
  void dispose() {
    _close.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final container = widget.inspected.container;
    final serverId = widget.inspected.serverId;
    final shell =
        _shell &&
        actionsAllowedAt(context, serverId, ActionEntryPoint.containerShell);
    return _RemovedBuilder(
      monitoring: widget.monitoring,
      serverId: serverId,
      containerId: container.id,
      builder: (context, removed) => _inspector(
        context,
        container: container,
        serverId: serverId,
        shell: shell && !removed,
        removed: removed,
      ),
    );
  }

  Widget _inspector(
    BuildContext context, {
    required ContainerSummary container,
    required String serverId,
    required bool shell,
    required bool removed,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      containerNameOf(container),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.dockerLogsShow,
                  icon: const Icon(Icons.article_outlined),
                  onPressed: () => openContainerLogs(
                    context,
                    monitoring: widget.monitoring,
                    serverId: widget.inspected.serverId,
                    container: container,
                  ),
                ),
                if (!removed) ...[
                  ContainerCommandButton(
                    serverId: serverId,
                    container: container,
                  ),
                  ActionEntry(
                    serverId: serverId,
                    point: ActionEntryPoint.containerShell,
                    child: IconButton(
                      tooltip: shell
                          ? l10n.dockerShellHide
                          : l10n.dockerShellOpen,
                      icon: Icon(shell ? Icons.info_outline : Icons.terminal),
                      onPressed: () {
                        // The desktop dock (OV-10) gives a shell the room
                        // the inspector's column lacks.
                        if (!shell) {
                          if (WorkspaceDockScope.maybeOf(context)
                              case final dock?) {
                            dock.show(DockedShell(serverId, container));
                            return;
                          }
                        }
                        setState(() => _shell = !shell);
                      },
                    ),
                  ),
                ],
                IconButton(
                  focusNode: _close,
                  tooltip: l10n.dockerDetailsClose,
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shell
                  ? ContainerShellPane(
                      key: ValueKey((serverId, container.id)),
                      monitoring: widget.monitoring,
                      serverId: serverId,
                      container: container,
                    )
                  : ContainerDetailsView(
                      monitoring: widget.monitoring,
                      serverId: serverId,
                      container: container,
                      padding: EdgeInsets.zero,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A container's details on a page of its own, as a phone pushes it
/// (03 §10.5), under an app bar that names it, opens its logs in a
/// bottom sheet ([openContainerLogs]) and, where actions are allowed,
/// pushes a shell in it ([openContainerShellPage]).
class ContainerDetailsPage extends StatelessWidget {
  const ContainerDetailsPage({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.container,
  });

  final MonitoringController monitoring;
  final String serverId;
  final ContainerSummary container;

  @override
  Widget build(BuildContext context) => _RemovedBuilder(
    monitoring: monitoring,
    serverId: serverId,
    containerId: container.id,
    builder: _scaffold,
  );

  Widget _scaffold(BuildContext context, bool removed) => Scaffold(
    appBar: AppBar(
      title: Text(containerNameOf(container)),
      actions: [
        Builder(
          builder: (context) => IconButton(
            tooltip: AppLocalizations.of(context).dockerLogsShow,
            icon: const Icon(Icons.article_outlined),
            onPressed: () => openContainerLogs(
              context,
              monitoring: monitoring,
              serverId: serverId,
              container: container,
            ),
          ),
        ),
        if (!removed) ...[
          Builder(
            builder: (context) => ContainerCommandButton(
              serverId: serverId,
              container: container,
            ),
          ),
          ActionEntry(
            serverId: serverId,
            point: ActionEntryPoint.containerShell,
            child: Builder(
              builder: (context) => IconButton(
                tooltip: AppLocalizations.of(context).dockerShellOpen,
                icon: const Icon(Icons.terminal),
                onPressed: () => openContainerShellPage(
                  context,
                  monitoring: monitoring,
                  serverId: serverId,
                  container: container,
                ),
              ),
            ),
          ),
        ],
      ],
    ),
    body: SafeArea(
      child: ContainerDetailsView(
        monitoring: monitoring,
        serverId: serverId,
        container: container,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      ),
    ),
  );
}

/// Builds a container's header while telling it whether the container is
/// gone, so a header does not offer a command or shell that would end in
/// a refusal. It counts as a view of the container, as
/// [ContainerDetailsView] does, and shares what that one reads.
class _RemovedBuilder extends StatefulWidget {
  const _RemovedBuilder({
    required this.monitoring,
    required this.serverId,
    required this.containerId,
    required this.builder,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String containerId;
  final Widget Function(BuildContext context, bool removed) builder;

  @override
  State<_RemovedBuilder> createState() => _RemovedBuilderState();
}

class _RemovedBuilderState extends State<_RemovedBuilder> {
  late ValueListenable<DockerContainerDetails> _details;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _details = _docker.openContainer(widget.serverId, widget.containerId);
  }

  @override
  void didUpdateWidget(_RemovedBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId == oldWidget.serverId &&
        widget.containerId == oldWidget.containerId) {
      return;
    }

    _docker.closeContainer(oldWidget.serverId, oldWidget.containerId);
    _details = _docker.openContainer(widget.serverId, widget.containerId);
  }

  @override
  void dispose() {
    _docker.closeContainer(widget.serverId, widget.containerId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _details,
    builder: (context, details, _) => widget.builder(context, details.removed),
  );
}

/// One container's details (03 §7.12 CTR-03, CTR-04, DKE-10): its
/// managed-by badge, state, health with the last checks' output,
/// restart policy, image and times, its command, environment and labels,
/// mounts, ports, networks, and the inspect as raw JSON.
///
/// While it shows, it counts as a details view of the container
/// ([DockerController.openContainer]), which has it inspected and read
/// again as its row changes. Its ports are the row's, from the latest
/// list: the inspect the engine sends carries none.
///
/// Masked values (03 §8.9) show their mask until selected, then their
/// text for [kRevealDuration]. The revealed text lives in this view's
/// state only: each is masked again when its time is up, when the app
/// turns inactive, and when the view closes or shows another container,
/// and nothing sends, stores or logs it (SAF-07). Inactive precedes
/// hidden on the way to the background, while a frame can still draw
/// the mask before an app switcher's snapshot. A screen reader hears
/// "(masked)" where the screen shows the mask, and the raw JSON is drawn
/// from the masked model, so it never holds a revealed value.
class ContainerDetailsView extends StatefulWidget {
  const ContainerDetailsView({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.container,
    this.padding = EdgeInsets.zero,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The container's row as opened; the latest list's row replaces it
  /// once one arrives.
  final ContainerSummary container;
  final EdgeInsetsGeometry padding;

  @override
  State<ContainerDetailsView> createState() => _ContainerDetailsViewState();
}

class _ContainerDetailsViewState extends State<ContainerDetailsView> {
  /// The revealed values by where they show.
  late final TimedReveals<_Shown> _revealed;
  late ValueListenable<DockerContainerDetails> _details;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _revealed = TimedReveals(onChanged: () => setState(() {}));
    _details = _docker.openContainer(widget.serverId, widget.container.id);
    _docker.pinStats(widget.serverId, widget.container.id);
  }

  @override
  void didUpdateWidget(ContainerDetailsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId == oldWidget.serverId &&
        widget.container.id == oldWidget.container.id) {
      return;
    }

    // Another container: nothing revealed carries over.
    _revealed.maskAll();
    _docker.closeContainer(oldWidget.serverId, oldWidget.container.id);
    _docker.unpinStats(oldWidget.serverId, oldWidget.container.id);
    _details = _docker.openContainer(widget.serverId, widget.container.id);
    _docker.pinStats(widget.serverId, widget.container.id);
  }

  @override
  void dispose() {
    _revealed.dispose();
    _docker.closeContainer(widget.serverId, widget.container.id);
    _docker.unpinStats(widget.serverId, widget.container.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // a new list (SYN-08).
    final list = _docker.containersFor(widget.serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([_details, list]),
      builder: (context, _) {
        final id = widget.container.id;
        final row =
            list.value.containers?.where((c) => c.id == id).firstOrNull ??
            widget.container;
        return _build(context, _details.value, row);
      },
    );
  }

  /// [sections] with the usage charts (CST-03) after them while the
  /// container is up: the facts come first, the charts' history below.
  List<Widget> _withUsage(
    List<Widget> sections,
    ContainerSummary row, {
    required bool removed,
  }) {
    if (removed || !containerIsUp(row)) return sections;
    return [
      ...sections,
      ContainerUsageCharts(
        monitoring: widget.monitoring,
        serverId: widget.serverId,
        containerId: row.id,
      ),
    ];
  }

  Widget _build(
    BuildContext context,
    DockerContainerDetails read,
    ContainerSummary row,
  ) {
    final l10n = AppLocalizations.of(context);
    final container = read.container;
    final failure = read.failure;
    final children = <Widget>[
      if (read.removed)
        DockerNotice(
          icon: Icons.delete_outline,
          text: l10n.dockerDetailsRemoved,
        )
      else if (failure != null)
        DockerNotice(
          icon: Icons.error_outline,
          text: l10n.dockerDetailsFailed(failure.failure.name),
          detail: failure.detail,
          action: TextButton(
            onPressed: () =>
                _docker.retryContainer(widget.serverId, widget.container.id),
            child: Text(l10n.dockerRetry),
          ),
        ),
      if (container == null && !read.removed && failure == null)
        DockerNotice(
          icon: Icons.hourglass_empty,
          text: l10n.dockerDetailsReading,
        ),
      if (container != null && (read.removed || failure != null))
        DockerNotice(icon: Icons.history, text: l10n.dockerDetailsKept),
      if (container != null)
        ..._withUsage(
          _sections(
            context,
            container,
            row,
            live: !read.removed && failure == null,
            removed: read.removed,
          ),
          row,
          removed: read.removed,
        ),
    ];
    return ListView(
      padding: widget.padding,
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(bottom: 16), child: child),
      ],
    );
  }

  List<Widget> _sections(
    BuildContext context,
    ContainerDetails container,
    ContainerSummary row, {
    required bool live,
    required bool removed,
  }) {
    final l10n = AppLocalizations.of(context);
    final config = container.config;
    final env = config?.env ?? const <EnvVar>[];
    final labels = config?.labels ?? const <String, MaskedValue>{};
    final health = container.state?.health;
    final masked =
        env.any((variable) => variable.value.isMasked) ||
        labels.values.any((value) => value.isMasked) ||
        [
          ...?config?.entrypoint,
          ...?config?.cmd,
        ].any((value) => value.isMasked) ||
        (health?.log ?? const []).any(
          (check) => check.output?.isMasked ?? false,
        );
    return [
      if (detectOwnership(labels).primary case final marker?)
        _ManagedByBadge(marker: marker),
      // The row is the stale one from before the container went.
      if (!removed && containerActionsShown(context, widget.serverId, row))
        ContainerActionButtons(serverId: widget.serverId, container: row),
      if (masked)
        Text(
          l10n.dockerDetailsRevealNote(kRevealDuration.inSeconds),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      _Section(
        title: l10n.dockerDetailsOverview,
        children: _overview(context, container, row),
      ),
      if (diagnoseContainer(container) case final diagnoses
          when diagnoses.isNotEmpty)
        _Section(
          title: l10n.dockerDiagnosisTitle,
          children: [
            _LogTail(
              monitoring: widget.monitoring,
              serverId: widget.serverId,
              containerId: container.id,
              // A run that ended usually says why in its last lines; a
              // failing health check's output shows in Health checks.
              read:
                  !removed &&
                  diagnoses.any(
                    (d) => d.kind != ContainerDiagnosisKind.unhealthy,
                  ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  for (final diagnosis in diagnoses)
                    ContainerDiagnosisRow(diagnosis: diagnosis),
                ],
              ),
            ),
          ],
        ),
      if (labelLinks(labels) case final links when links.isNotEmpty)
        _Section(
          title: l10n.dockerLinksTitle,
          children: [ContainerLinks(links: links)],
        ),
      if (health != null && health.status != HealthStatus.none)
        _Section(
          title: l10n.dockerDetailsHealthTitle,
          children: [
            if (health.log.isEmpty)
              _Muted(l10n.dockerDetailsHealthEmpty)
            else
              // The newest first.
              for (final (index, check) in health.log.indexed.toList().reversed)
                _healthCheck(context, index, check),
          ],
        ),
      _Section(
        title: l10n.dockerDetailsCommandTitle,
        children: [
          _arguments(
            context,
            l10n.dockerDetailsEntrypoint,
            _Field.entrypoint,
            config?.entrypoint ?? const [],
          ),
          _arguments(
            context,
            l10n.dockerDetailsCmd,
            _Field.cmd,
            config?.cmd ?? const [],
          ),
        ],
      ),
      _Section(
        title: l10n.dockerDetailsEnvTitle,
        children: [
          if (env.isEmpty) _Muted(l10n.dockerDetailsEnvEmpty),
          for (final variable in env)
            _value(
              context,
              (_Field.env, variable.name),
              variable.value,
              name: variable.name,
            ),
        ],
      ),
      _Section(
        title: l10n.dockerDetailsLabelsTitle,
        children: [
          if (labels.isEmpty) _Muted(l10n.dockerDetailsLabelsEmpty),
          for (final MapEntry(:key, :value) in labels.entries)
            _value(context, (_Field.label, key), value, name: key),
        ],
      ),
      _Section(
        title: l10n.dockerDetailsMountsTitle,
        children: [
          if (container.mounts.isEmpty) _Muted(l10n.dockerDetailsMountsEmpty),
          for (final mount in container.mounts) _Mount(mount: mount),
        ],
      ),
      _Section(
        title: l10n.dockerContainersColumnPorts,
        children: [
          if (row.ports.isEmpty) _Muted(l10n.dockerDetailsPortsEmpty),
          for (final port in containerPortLabels(row)) Text(port),
        ],
      ),
      _Section(
        title: l10n.dockerDetailsNetworksTitle,
        children: _networks(context, container),
      ),
      // Only over a live read: a container that is gone, or a server
      // the details cannot reach, says so once above.
      if (live)
        ContainerProcessesSection(
          docker: _docker,
          serverId: widget.serverId,
          containerId: widget.container.id,
          up: containerIsUp(row),
        ),
      _RawJson(
        monitoring: widget.monitoring,
        container: container,
        name: containerNameOf(row),
      ),
    ];
  }

  List<Widget> _overview(
    BuildContext context,
    ContainerDetails container,
    ContainerSummary row,
  ) {
    final l10n = AppLocalizations.of(context);
    final unknown = l10n.chartUnknownValue;
    final state = container.state;
    final health = state?.health;
    final restart = container.hostConfig?.restartPolicy;
    final created = engineTime(container.created);
    final started = engineTime(state?.startedAt);
    final finished = engineTime(state?.finishedAt);
    final running = state?.running ?? false;
    final error = state?.error;
    String time(DateTime time) =>
        l10n.dockerDetailsTime(displayTime(context, widget.serverId, time));

    return [
      _Facts(
        facts: [
          (l10n.dockerDetailsId, shortContainerId(container.id)),
          (l10n.dockerContainersColumnState, _stateText(l10n, state)),
          if (health != null && health.status != HealthStatus.none)
            (l10n.dockerContainersColumnHealth, null),
          (
            l10n.dockerDetailsRestartPolicy,
            restart == null ? unknown : _restartText(l10n, restart),
          ),
          if (container.restartCount case final count?)
            (l10n.dockerDetailsRestarts, count.toString()),
          (
            l10n.dockerContainersColumnImage,
            container.config?.image ?? row.image ?? unknown,
          ),
          if (container.image case final image?)
            (l10n.dockerDetailsImageId, shortImageId(image)),
          if (created != null) (l10n.dockerDetailsCreated, time(created)),
          if (started != null) (l10n.dockerDetailsStarted, time(started)),
          if (finished != null && !running)
            (l10n.dockerDetailsFinished, time(finished)),
        ],
        health: health,
      ),
      if (state?.oomKilled ?? false)
        DockerNotice(icon: Icons.memory, text: l10n.dockerDetailsOomKilled),
      if (error != null && error.isNotEmpty)
        DockerNotice(
          icon: Icons.error_outline,
          text: l10n.dockerDetailsStateError,
          detail: error,
        ),
    ];
  }

  Widget _healthCheck(
    BuildContext context,
    int index,
    ContainerHealthCheck check,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final code = check.exitCode?.toString() ?? l10n.chartUnknownValue;
    final end = engineTime(check.end);
    final output = check.output;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(
          end == null
              ? l10n.dockerDetailsHealthCheckUntimed(code)
              : l10n.dockerDetailsHealthCheck(
                  code,
                  displayTime(context, widget.serverId, end),
                ),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (output == null || output.display.trim().isEmpty)
          _Muted(l10n.dockerDetailsHealthNoOutput)
        else
          // Keyed by the check's time where it has one: a read again
          // shifts the log, and a reveal stays with what was selected.
          _value(
            context,
            (_Field.health, check.start ?? check.end ?? index),
            output,
            mono: true,
          ),
      ],
    );
  }

  /// An entrypoint or argument list: each argument on its own line, as a
  /// process's details show them, a masked one revealed on selection.
  Widget _arguments(
    BuildContext context,
    String label,
    _Field field,
    List<MaskedValue> arguments,
  ) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        _Label(label),
        if (arguments.isEmpty) _Muted(l10n.dockerDetailsNone),
        for (final (index, argument) in arguments.indexed)
          _value(context, (field, index), argument, mono: true),
      ],
    );
  }

  List<Widget> _networks(BuildContext context, ContainerDetails container) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final mode = container.hostConfig?.networkMode;
    final networks =
        container.networkSettings?.networks ??
        const <String, ContainerNetwork>{};
    return [
      if (mode != null && mode.isNotEmpty)
        _Facts(facts: [(l10n.dockerDetailsNetworkMode, mode)]),
      if (networks.isEmpty) _Muted(l10n.dockerDetailsNetworksEmpty),
      for (final MapEntry(key: name, value: network) in networks.entries)
        MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(
                name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final (label, value) in [
                (l10n.dockerDetailsIpAddress, network.ipAddress),
                (l10n.dockerDetailsGateway, network.gateway),
                (l10n.dockerDetailsAliases, network.aliases.join(', ')),
              ])
                if (value != null && value.isNotEmpty)
                  Text(
                    l10n.dockerContainersFact(label, value),
                    style: theme.textTheme.bodySmall,
                  ),
            ],
          ),
        ),
    ];
  }

  /// A value under its [name], if any: plain, or masked until selected.
  /// [key] says where it shows, which its reveal is kept by.
  Widget _value(
    BuildContext context,
    _Shown key,
    MaskedValue value, {
    String? name,
    bool mono = false,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = mono
        ? theme.textTheme.bodyMedium?.merge(_monoStyle)
        : theme.textTheme.bodyMedium;

    if (!value.isMasked) {
      final text = Text(clipProcessText(value.display), style: style);
      if (name == null) return text;
      return MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_Label(name), text],
        ),
      );
    }

    final revealed = _revealed.isRevealed(key);
    final shown = clipProcessText(revealed ? value.reveal()! : value.display);
    // A masked value is read as masked, never as eight asterisks.
    final spoken = revealed
        ? shown
        : clipProcessText(
            argumentText(value, maskWord: l10n.dockerDetailsMasked),
          );
    return Semantics(
      // A node of its own, not merged into its section's.
      container: true,
      button: true,
      label: name == null ? spoken : l10n.dockerDetailsEntry(name, spoken),
      hint: revealed
          ? l10n.dockerDetailsHideHint
          : l10n.dockerDetailsRevealHint,
      excludeSemantics: true,
      onTap: () => _revealed.toggle(key),
      child: InkWell(
        onTap: () => _revealed.toggle(key),
        child: ConstrainedBox(
          // A touch needs a 48 dp target (A11Y-01); a pointer, the line.
          constraints: BoxConstraints(
            minHeight: ghostIsDesktopPlatform(theme.platform)
                ? 0
                : kMinInteractiveDimension,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (name != null) _Label(name),
                      Text(shown, style: style),
                    ],
                  ),
                ),
                Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Where a masked value shows in the details, which keeps its reveal.
enum _Field { env, label, entrypoint, cmd, health }

/// One masked value's place: its field, and there the variable's name,
/// the label's key, the argument's index or the check's time (its index
/// when it has none).
typedef _Shown = (_Field, Object);

/// The app's monospace stack, `ghost_fonts`' bundled family first, for a
/// command line, a check's output and the raw JSON.
final TextStyle _monoStyle = TextStyle(
  fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
  fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies
      .skip(1)
      .toList(growable: false),
);

/// [state] in words, a stopped container's with its exit code.
String _stateText(AppLocalizations l10n, ContainerDetailsState? state) {
  final status = state?.status;
  if (status == null || status.isEmpty) return l10n.chartUnknownValue;

  final known = EngineContainerState.of(status);
  final words = known == null ? status : l10n.dockerContainerState(known.name);
  final code = state?.exitCode;
  if (code == null ||
      (known?.up ?? true) ||
      known == EngineContainerState.created) {
    return words;
  }
  return l10n.dockerDetailsStateExited(words, code);
}

/// A restart policy in words, on-failure's with its retry limit.
String _restartText(AppLocalizations l10n, ContainerRestartPolicy policy) {
  final kind = RestartPolicyKind.of(policy.name);
  if (kind == null) return policy.name!;

  final words = l10n.dockerDetailsRestartPolicyName(kind.name);
  final retries = policy.maximumRetryCount ?? 0;
  if (kind != RestartPolicyKind.onFailure || retries <= 0) return words;
  return l10n.dockerDetailsRestartPolicyRetries(words, retries);
}

/// How many of a container's newest log lines its diagnosis shows.
const _logTailLines = 20;

/// [child], the diagnosis (TRI-04), over [containerId]'s newest log
/// lines when [read]: one bounded read while it shows, oldest first as
/// Docker sends them. Lines show as they arrive; none show when the
/// read fails, and the Logs view says why there.
class _LogTail extends StatefulWidget {
  const _LogTail({
    required this.monitoring,
    required this.serverId,
    required this.containerId,
    required this.read,
    required this.child,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String containerId;
  final bool read;
  final Widget child;

  @override
  State<_LogTail> createState() => _LogTailState();
}

class _LogTailState extends State<_LogTail> {
  LogRead? _read;

  @override
  void initState() {
    super.initState();
    if (widget.read) _open();
  }

  @override
  void didUpdateWidget(_LogTail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.containerId == widget.containerId &&
        oldWidget.read == widget.read) {
      return;
    }

    _close();
    if (widget.read) _open();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _open() {
    _read = widget.monitoring.openLogRead(
      LogStreamSpec(
        serverId: widget.serverId,
        source: ContainerLogSource(widget.containerId),
        window: _logTailLines,
        follow: false,
      ),
    )..addListener(_changed);
  }

  void _close() {
    _read
      ?..removeListener(_changed)
      ..close();
    _read = null;
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final read = _read;
    if (read == null) return widget.child;

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lines = [
      for (final record in read.records)
        if (record is ContainerRecord) record.text,
    ];
    final readAll = switch (read.state) {
      LogReadReported(
        status: LogStreamEnded(
          reason: LogStreamEndReason.windowFilled ||
              LogStreamEndReason.oldestReached,
        ),
      ) =>
        true,
      _ => false,
    };
    if (lines.isEmpty && !readAll) return widget.child;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        widget.child,
        _Label(l10n.dockerLogsTitle),
        if (lines.isEmpty)
          _Muted(l10n.dockerLogsEmpty)
        else
          // One text per line, selectable together.
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Text(
                    line,
                    style: klabautermannMonoStyle.copyWith(
                      fontSize: theme.textTheme.bodySmall?.fontSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A heading over its [children], read as a heading.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Semantics(
          container: true,
          header: true,
          child: Text(title, style: theme.textTheme.titleSmall),
        ),
        ...children,
      ],
    );
  }
}

/// A label over its value, in the muted colour.
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A line that says there is nothing to show.
class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Labelled values, each read as one node; a null value is the health
/// badge, drawn from [health].
class _Facts extends StatelessWidget {
  const _Facts({required this.facts, this.health});

  final List<(String, String?)> facts;
  final ContainerDetailsHealth? health;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final health = this.health;
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        for (final (label, value) in facts)
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Label(label),
                if (value != null)
                  Text(value, style: theme.textTheme.bodyMedium)
                else if (health != null) ...[
                  ContainerHealthBadge(health: health.status),
                  if (health.failingStreak case final streak? when streak > 0)
                    Text(
                      l10n.dockerDetailsHealthStreak(streak),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One mount: where it shows in the container, where it comes from, and
/// its type and access.
class _Mount extends StatelessWidget {
  const _Mount({required this.mount});

  final ContainerMount mount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unknown = l10n.chartUnknownValue;
    // A volume reads by its name; its source is the engine's own path.
    final source = mount.type == 'volume'
        ? mount.name ?? mount.source
        : mount.source;
    final access = switch (mount.rw) {
      true => l10n.dockerDetailsMountReadWrite,
      false => l10n.dockerDetailsMountReadOnly,
      null => unknown,
    };
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            mount.destination ?? unknown,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (source != null && source.isNotEmpty)
            Text(source, style: theme.textTheme.bodySmall),
          Text(
            l10n.dockerDetailsMountSummary(
              l10n.dockerDetailsMountKind(mount.type ?? ''),
              access,
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// DKE-10's badge: the manager that owns the container, and the label
/// that says so.
class _ManagedByBadge extends StatelessWidget {
  const _ManagedByBadge({required this.marker});

  final OwnershipMarker marker;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = scheme.onSecondaryContainer;
    final manager = marker.manager.displayName;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Icon(Icons.lock_outline, size: 18, color: color),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      l10n.dockerDetailsManagedBy(manager),
                      style: theme.textTheme.titleSmall?.copyWith(color: color),
                    ),
                    Text(
                      l10n.dockerDetailsManagedByNote(manager, marker.label),
                      style: theme.textTheme.bodySmall?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The inspect as raw JSON, folded until opened, from the masked model
/// ([containerDetailsJson]), and exported from there (PLT-08) through
/// LOG-10's sheet, redacted unless the user includes secrets.
class _RawJson extends StatelessWidget {
  const _RawJson({
    required this.monitoring,
    required this.container,
    required this.name,
  });

  final MonitoringController monitoring;
  final ContainerDetails container;

  /// The container's name, for the file's.
  final String name;

  void _export(BuildContext context, String json) {
    final l10n = AppLocalizations.of(context);
    unawaited(
      showExportSheet(
        context,
        monitoring: monitoring,
        lines: const LineSplitter().convert(json),
        fileName: l10n.dockerDetailsRawFileName(name),
        title: l10n.dockerDetailsRawExportTitle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        l10n.dockerDetailsRawTitle,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        l10n.dockerDetailsRawNote,
        style: theme.textTheme.bodySmall,
      ),
      children: [
        // Built only once opened.
        Builder(
          builder: (context) {
            final json = containerDetailsJson(container);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      json,
                      style: theme.textTheme.bodySmall?.merge(_monoStyle),
                    ),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _export(context, json),
                    icon: const Icon(Icons.ios_share),
                    label: Text(l10n.logsExport),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
