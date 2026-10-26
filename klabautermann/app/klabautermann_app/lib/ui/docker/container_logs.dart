import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../logs/log_view.dart';
import '../logs/logs_panel.dart';
import '../logs/logs_panel_controller.dart';
import 'container_details.dart' show InspectedContainer;
import 'container_log_range.dart';
import 'containers_view.dart' show containerNameOf;

/// Below this width at 100 % text the log view puts its search on a row
/// of its own, as the Logs panel does (03 §10.5).
const double _compactWidth = 600;

/// The search field's width beside the Live chip at 100 % text; it grows
/// with the text.
const double _searchWidth = 450;

/// The share of the screen a phone's log sheet opens at, and the least it
/// drags down to before it closes, as SVC-04's sheet does (03 §10.5).
const double _sheetShare = 0.6;
const double _sheetMinShare = 0.25;

/// The share of its height the view's header takes before it scrolls,
/// so large text never pushes the lines out of sight.
const double _headerShare = 0.5;

/// Why a container's logging driver keeps no logs the API can read
/// ([AppLocalizations.dockerLogsDriverUnreadable], 03 §7.12 CTX-01).
enum _DriverReason {
  /// The `none` driver: the container keeps no logs at all.
  none,

  /// Podman, which reads only `json-file`, `k8s-file` and `journald`.
  podman,

  /// A remote driver with Docker's dual-logging cache turned off.
  cacheDisabled,

  /// The engine could not name the driver.
  other,
}

/// Hands the desktop's container log pane the container whose logs it
/// shows: the container's details and its row open one, and the Docker
/// tab shows it. The desktop shell holds it above both; without one, as
/// on a phone, logs open in a bottom sheet.
class ContainerLogsScope
    extends InheritedNotifier<ValueNotifier<InspectedContainer?>> {
  const ContainerLogsScope({
    super.key,
    required ValueNotifier<InspectedContainer?> logs,
    required super.child,
  }) : super(notifier: logs);

  /// The container shown, rebuilding [context] as it changes.
  static ValueNotifier<InspectedContainer?>? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ContainerLogsScope>()
          ?.notifier;

  /// The container shown, without rebuilding [context] as it changes:
  /// what an action that opens a container's logs reads.
  static ValueNotifier<InspectedContainer?>? find(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ContainerLogsScope>()?.notifier;
}

/// Opens [container]'s logs (03 §7.12 CTX-01): in the desktop Docker
/// tab's log pane where there is one, otherwise in a bottom sheet that
/// drags from a quarter of the screen to its full height (02 CTX-01,
/// 03 §10.5). The sheet reads the logs while it is open; closing it by
/// its button, a drag or Back closes the stream.
void openContainerLogs(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required ContainerSummary container,
}) {
  if (ContainerLogsScope.find(context) case final logs?) {
    logs.value = InspectedContainer(serverId: serverId, container: container);
    return;
  }

  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: _sheetShare,
        minChildSize: _sheetMinShare,
        maxChildSize: 1,
        builder: (context, scroll) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: ContainerLogsView(
            monitoring: monitoring,
            serverId: serverId,
            containerId: container.id,
            // The sheet covers the tab, so the tab cannot change.
            visible: true,
            headerScroll: scroll,
            title: _Title(
              name: containerNameOf(container),
              onClose: () => Navigator.pop(context),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The desktop Docker tab's log pane under its sub-tabs, where 03
/// §10.2's bottom dock (v1) will hold logs: the container's name and a
/// close button over its logs. Its close button takes keyboard focus as
/// it opens, so the logs are read next, and Escape inside it closes it.
class ContainerLogsPane extends StatefulWidget {
  const ContainerLogsPane({
    super.key,
    required this.monitoring,
    required this.shown,
    required this.visible,
    required this.onClose,
  });

  final MonitoringController monitoring;
  final InspectedContainer shown;

  /// Whether the Docker tab shows; the stream is open only meanwhile.
  final bool visible;
  final VoidCallback onClose;

  @override
  State<ContainerLogsPane> createState() => _ContainerLogsPaneState();
}

class _ContainerLogsPaneState extends State<ContainerLogsPane> {
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
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
    },
    child: FocusTraversalGroup(
      child: ContainerLogsView(
        monitoring: widget.monitoring,
        serverId: widget.shown.serverId,
        containerId: widget.shown.container.id,
        visible: widget.visible,
        title: _Title(
          name: containerNameOf(widget.shown.container),
          onClose: widget.onClose,
          closeFocus: _close,
        ),
      ),
    ),
  );
}

/// One container's logs (03 §7.12 CTX-01, CTX-02, §10.8) under [title]:
/// the Live chip and the search over the [LogView], the stream's status
/// line, and the driver notice when the container's logging driver keeps
/// no logs the API can read. Each line starts with its time and its
/// stream, `stderr` in the error colour and named to a screen reader.
///
/// It reads through a [LogsPanelController.container] over the app's log
/// streams while [visible], as the Logs panel reads the host's: the
/// same bounded buffer, Live chip, gap notice and dropped-lines rows.
/// Showing it again starts the follow over, as the stream has no cursor.
/// Another container starts the view afresh.
class ContainerLogsView extends StatefulWidget {
  const ContainerLogsView({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.containerId,
    required this.visible,
    required this.title,
    this.headerScroll,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String containerId;
  final bool visible;
  final Widget title;

  /// The header's scroll controller, such as a sheet's, so dragging the
  /// header drags the sheet while the lines scroll alone.
  final ScrollController? headerScroll;

  @override
  State<ContainerLogsView> createState() => _ContainerLogsViewState();
}

class _ContainerLogsViewState extends State<ContainerLogsView> {
  late LogsPanelController _panel = _start();

  LogsPanelController _start() => LogsPanelController.container(
    streams: widget.monitoring.logs,
    serverId: widget.serverId,
    containerId: widget.containerId,
  )..setVisible(widget.visible);

  @override
  void didUpdateWidget(ContainerLogsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId ||
        widget.containerId != oldWidget.containerId ||
        widget.monitoring != oldWidget.monitoring) {
      _panel.dispose();
      _panel = _start();
    }
    _panel.setVisible(widget.visible);
  }

  @override
  void dispose() {
    _panel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // A new controller gets new search text.
    return KeyedSubtree(
      key: ObjectKey(_panel),
      child: ListenableBuilder(
        listenable: _panel,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < scaler.scale(_compactWidth);
            final search = LogSearchField(search: _panel.search);
            final header = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: widget.title,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      LogLiveChip(panel: _panel),
                      ContainerLogRangeButton(panel: _panel),
                      if (!compact)
                        SizedBox(
                          width: scaler.scale(_searchWidth),
                          child: search,
                        ),
                    ],
                  ),
                ),
                if (compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: search,
                  ),
                _status(l10n),
              ],
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * _headerShare,
                  ),
                  child: SingleChildScrollView(
                    controller: widget.headerScroll,
                    child: header,
                  ),
                ),
                Expanded(child: _lines(l10n)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The stream's status line, or the driver notice in its place for a
  /// logging driver the API cannot read, which retrying does not change.
  Widget _status(AppLocalizations l10n) {
    if (_panel.status case LogStreamEnded(
      reason: LogStreamEndReason.logDriverUnreadable,
      :final detail,
    )) {
      return LogNotice(
        icon: Icons.info_outline,
        text: l10n.dockerLogsDriverUnreadable(
          _driverReason(detail).name,
          detail ?? '',
        ),
        announce: true,
      );
    }
    return LogStatusNotice(panel: _panel);
  }

  /// Why [driver] keeps no logs the API reads, by the rule the engine
  /// applies (`unreadableLogDriver`): only `none` on Docker, as its
  /// dual-logging cache serves every other driver unless turned off.
  _DriverReason _driverReason(String? driver) {
    if (driver == null || driver.isEmpty) return _DriverReason.other;
    if (driver == 'none') return _DriverReason.none;
    final runtime = widget.monitoring.docker
        .endpointFor(widget.serverId)
        .value
        ?.route
        ?.runtime;
    return runtime == EngineRuntime.podman
        ? _DriverReason.podman
        : _DriverReason.cacheDisabled;
  }

  Widget _lines(AppLocalizations l10n) => Stack(
    fit: StackFit.expand,
    children: [
      LogView(controller: _panel.logs, search: _panel.search),
      if (logsPanelEndedEmpty(_panel))
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.dockerLogsEmpty, textAlign: TextAlign.center),
          ),
        ),
    ],
  );
}

/// The container's name over "Logs", with a close button.
class _Title extends StatelessWidget {
  const _Title({required this.name, required this.onClose, this.closeFocus});

  final String name;
  final VoidCallback onClose;
  final FocusNode? closeFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Text(l10n.dockerLogsTitle),
            ],
          ),
        ),
        IconButton(
          focusNode: closeFocus,
          tooltip: l10n.dockerLogsClose,
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
      ],
    );
  }
}
