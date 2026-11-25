part of 'container_details.dart';

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
/// button that opens its logs ([openContainerLogs]), one that opens a
/// shell in the workspace dock (OV-10) where actions are allowed
/// (CTX-07), and a close button. It takes keyboard focus as it opens, so
/// the details are read next, and Escape inside it closes it.
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _close.requestFocus();
    });
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
    return _RemovedBuilder(
      monitoring: widget.monitoring,
      serverId: serverId,
      containerId: container.id,
      builder: (context, removed) => _inspector(
        context,
        container: container,
        serverId: serverId,
        removed: removed,
      ),
    );
  }

  Widget _inspector(
    BuildContext context, {
    required ContainerSummary container,
    required String serverId,
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
                      tooltip: l10n.dockerShellOpen,
                      icon: const Icon(Icons.terminal),
                      onPressed: () {
                        // The desktop dock (OV-10) gives a shell the room
                        // the inspector's column lacks.
                        if (WorkspaceDockScope.maybeOf(context)
                            case final dock?) {
                          dock.show(DockedShell(serverId, container));
                        }
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
              child: ContainerDetailsView(
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
