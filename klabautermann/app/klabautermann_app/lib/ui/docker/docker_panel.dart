import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView, showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/docker_notice_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../server_header.dart' show HeaderedBody;
import 'container_logs.dart';
import 'containers_panel.dart';
import 'docker_endpoint.dart';
import 'docker_endpoint_picker.dart';
import 'images_panel.dart';
import 'events_panel.dart';
import 'networks_panel.dart';
import 'review_panel.dart';
import 'stacks_panel.dart';
import 'volumes_panel.dart';

/// Hands the Docker tab SAF-08's notice state on every route (M3's M12):
/// a phone pushes the server screen as a route of its own, so it sits
/// above the navigator, as the announcement switch's scope does.
class DockerNoticeScope extends InheritedNotifier<DockerNoticeController> {
  const DockerNoticeScope({
    super.key,
    required DockerNoticeController notice,
    required super.child,
  }) : super(notifier: notice);

  static DockerNoticeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockerNoticeScope>()?.notifier;
}

/// The Docker tab's sub-tabs in 03 §10.2's order, then the security
/// review (DKE-06).
enum DockerSubTab {
  containers,
  images,
  stacks,
  volumes,
  networks,
  events,
  review;

  String label(AppLocalizations l10n) => switch (this) {
    containers => l10n.dockerTabContainers,
    images => l10n.dockerTabImages,
    stacks => l10n.dockerTabStacks,
    volumes => l10n.dockerTabVolumes,
    networks => l10n.dockerTabNetworks,
    events => l10n.dockerTabEvents,
    review => l10n.dockerTabReview,
  };
}

/// The Docker tab once [serverId]'s endpoint is ready (03 §10.2): SAF-08's
/// notice until it is dismissed on this device, the engine strip
/// (DKE-01), and the sub-tabs: Containers ([ContainersPanel]), Images
/// ([ImagesPanel]), Stacks ([StacksPanel]), Volumes ([VolumesPanel]),
/// Networks ([NetworksPanel]), Events ([EventsPanel]) and Review
/// ([ReviewPanel]). While [visible], the tab counts as a view of the
/// server's Docker engine
/// ([DockerController.openView]), so a ready endpoint's details are read,
/// and each sub-tab watches its list while it shows: the stacks only
/// then, since asking for them runs compose checks on the host.
///
/// On the desktop, a container's logs ([ContainerLogsScope]) show in a
/// pane under the sub-tabs, which keeps the list and the inspector in
/// sight, where 03 §10.2's bottom dock (v1) will hold them; the pane
/// follows only while the tab shows.
class DockerPanel extends StatefulWidget {
  const DockerPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<DockerPanel> createState() => _DockerPanelState();
}

class _DockerPanelState extends State<DockerPanel> {
  /// The server [DockerController.openView] was told of, if any.
  String? _held;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(DockerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      widget.monitoring == oldWidget.monitoring,
      'new controllers come with a new tree (KlabautermannApp, D44)',
    );
    _sync();
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

    _docker.openView(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.closeView(held);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final notice = DockerNoticeScope.maybeOf(context);
    final logs = ContainerLogsScope.maybeOf(context);
    final shownLogs = switch (logs?.value) {
      final shown? when shown.serverId == widget.serverId => shown,
      _ => null,
    };
    return DefaultTabController(
      length: DockerSubTab.values.length,
      child: HeaderedBody(
        headerPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (notice != null && notice.showsNotice)
              _RootEquivalenceNotice(notice: notice),
            DockerEngineStrip(
              docker: _docker,
              profile: widget.monitoring.profileFor(widget.serverId),
              serverId: widget.serverId,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              isScrollable: true,
              tabs: [
                for (final tab in DockerSubTab.values)
                  Tab(text: tab.label(l10n)),
              ],
            ),
            Expanded(
              child: Builder(
                builder: (context) {
                  final tabs = DefaultTabController.of(context);
                  return ListenableBuilder(
                    listenable: tabs,
                    builder: (context, _) => SelectedTabView(
                      children: [
                        for (final tab in DockerSubTab.values)
                          switch (tab) {
                            DockerSubTab.containers => ContainersPanel(
                              monitoring: widget.monitoring,
                              serverId: widget.serverId,
                              visible:
                                  widget.visible && tabs.index == tab.index,
                            ),
                            DockerSubTab.images => ImagesPanel(
                              monitoring: widget.monitoring,
                              serverId: widget.serverId,
                              visible:
                                  widget.visible && tabs.index == tab.index,
                            ),
                            DockerSubTab.volumes => VolumesPanel(
                              monitoring: widget.monitoring,
                              serverId: widget.serverId,
                              visible:
                                  widget.visible && tabs.index == tab.index,
                            ),
                            DockerSubTab.networks => NetworksPanel(
                              monitoring: widget.monitoring,
                              serverId: widget.serverId,
                              visible:
                                  widget.visible && tabs.index == tab.index,
                            ),
                            DockerSubTab.events => EventsPanel(
                              monitoring: widget.monitoring,
                              serverId: widget.serverId,
                              visible:
                                  widget.visible && tabs.index == tab.index,
                            ),
                            DockerSubTab.stacks => StacksPanel(
                              monitoring: widget.monitoring,
                              serverId: widget.serverId,
                              visible:
                                  widget.visible && tabs.index == tab.index,
                            ),
                            DockerSubTab.review => ReviewPanel(
                              docker: _docker,
                              serverId: widget.serverId,
                            ),
                          },
                      ],
                    ),
                  );
                },
              ),
            ),
            if (shownLogs != null) ...[
              const Divider(height: 1),
              Expanded(
                // Lines arrive up to 20 times a second; the list above
                // need not repaint with them.
                child: RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ContainerLogsPane(
                      // Another container's logs start with a new pane.
                      key: ValueKey(shownLogs.container.id),
                      monitoring: widget.monitoring,
                      shown: shownLogs,
                      visible: widget.visible,
                      onClose: () => logs?.value = null,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// DKE-01's engine strip: the engine as its API names it (M13), the
/// negotiated API version, and the engine's product, version and host
/// from its details, or that they are being read or could not be. Under
/// them, CN-09's socket picker ([DockerEndpointPicker]) over the sockets
/// in [profile], the server's probe answer.
class DockerEngineStrip extends StatelessWidget {
  const DockerEngineStrip({
    super.key,
    required this.docker,
    required this.profile,
    required this.serverId,
  });

  final DockerController docker;
  final ValueListenable<HostProfile?> profile;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final endpoint = docker.endpointFor(serverId);
    final engine = docker.engineFor(serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([endpoint, engine]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        final theme = Theme.of(context);
        final route = endpoint.value?.route;
        final api = endpoint.value?.negotiatedApi;
        final facts = <Widget>[
          if (route != null) Text(dockerEngineText(l10n, route)),
          if (api != null) Text(l10n.dockerEngineApi(api.toString())),
          ...switch (engine.value) {
            DockerEnginePayload(:final info, :final version) => [
              Text(_productText(l10n, route, info, version)),
              Text(_hostText(l10n, info, version)),
            ],
            DockerQueryFailed() => [
              Text(l10n.dockerEngineReadFailed),
              TextButton(
                onPressed: () => docker.retry(serverId),
                child: Text(l10n.dockerRetry),
              ),
            ],
            _ => [Text(l10n.dockerEngineReading)],
          },
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.dockerEngineHeading,
                style: theme.textTheme.titleSmall,
              ),
            ),
            DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              child: Wrap(
                spacing: 16,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: facts,
              ),
            ),
            DockerEndpointPicker(
              docker: docker,
              profile: profile,
              serverId: serverId,
            ),
          ],
        );
      },
    );
  }
}

/// The engine's product and version: "Docker Engine - Community 29.0.1".
/// The product falls back to the runtime's name, and the version to the
/// one `/info` gave.
String _productText(
  AppLocalizations l10n,
  DockerEndpointRoute? route,
  EngineInfo info,
  DockerServerVersion version,
) {
  final name =
      version.platformName ??
      switch (route?.runtime) {
        EngineRuntime.podman => l10n.dockerRuntimePodman,
        EngineRuntime.docker || null => l10n.dockerRuntimeDocker,
      };
  return switch (version.version ?? info.serverVersion) {
    final number? => l10n.dockerEngineVersion(name, number),
    null => l10n.dockerEngineVersionUnknown(name),
  };
}

/// The engine host's operating system and architecture, or unknown.
String _hostText(
  AppLocalizations l10n,
  EngineInfo info,
  DockerServerVersion version,
) {
  final os = info.operatingSystem ?? version.os;
  final architecture = info.architecture ?? version.arch;
  if (os == null) return l10n.dockerEngineOsUnknown;
  if (architecture == null) return os;
  return l10n.dockerEngineOs(os, architecture);
}

/// SAF-08's explanation (03 §8.4) at the head of the Docker tab until the
/// user dismisses it on this device.
class _RootEquivalenceNotice extends StatelessWidget {
  const _RootEquivalenceNotice({required this.notice});

  final DockerNoticeController notice;

  /// Hides the notice; a dismissal that cannot be saved says so, since
  /// the notice returns at the next start, and prints why.
  Future<void> _dismiss(BuildContext context) async {
    // Captured first: the notice is gone once the dismissal applies.
    final overlay = Overlay.of(context, rootOverlay: true);
    final notSaved = AppLocalizations.of(context).dockerNoticeNotSaved;
    try {
      await notice.dismiss();
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) showTopToast(overlay, message: notSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = scheme.onSecondaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.shield_outlined, size: 20, color: color),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            l10n.accessRootEquivalenceTitle,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: color,
                            ),
                          ),
                        ),
                        Text(
                          l10n.accessRootEquivalenceBody,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () => unawaited(_dismiss(context)),
                child: Text(l10n.dockerNoticeDismiss),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
