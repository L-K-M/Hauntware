import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../controllers/port_forwards.dart';
import '../../l10n/app_localizations.dart';
import '../../services/hand_off.dart';
import '../hand_off_actions.dart' show HandOffScope;
import 'container_links.dart';

/// The server's own loopback address, where a published port and a
/// host-network container's ports answer, and the device's, where a
/// forward listens.
const String _loopback = '127.0.0.1';

/// A TCP port of a container and the target a forward to it takes, as the
/// server reaches it (DKE-08, DKE-09).
@immutable
final class AppPort {
  const AppPort({
    required this.privatePort,
    this.publicPort,
    this.hostIp,
    this.forwardHost,
  });

  final int privatePort;

  /// The host port Docker publishes it on; null when it is not published.
  final int? publicPort;

  /// The address a published port is bound to, as Docker lists it.
  final String? hostIp;

  /// The host a forward reaches it at from the server: the loopback
  /// address or the bound address for a published port, the container's
  /// address for one that is not; null when the list names none.
  final String? forwardHost;

  /// The port a forward reaches it at from the server.
  int get forwardPort => publicPort ?? privatePort;

  @override
  bool operator ==(Object other) =>
      other is AppPort &&
      other.privatePort == privatePort &&
      other.publicPort == publicPort &&
      other.forwardHost == forwardHost;

  @override
  int get hashCode => Object.hash(privatePort, publicPort, forwardHost);
}

/// One running container's ways in: the pages its labels point at
/// (CTR-11) and each TCP port once.
typedef ContainerApps = ({
  ContainerSummary container,
  List<LabelLink> links,
  List<AppPort> ports,
});

/// The ways in to [containers] (DKE-08), running ones only, each with at
/// least one: label links, then TCP ports in order. Docker lists a port
/// published on both address families twice, which shows once; a UDP
/// port cannot be forwarded over SSH and is left out.
List<ContainerApps> containerApps(List<ContainerSummary> containers) => [
  for (final container in containers)
    if (container.state == 'running')
      if (_appsOf(container) case final apps
          when apps.links.isNotEmpty || apps.ports.isNotEmpty)
        apps,
];

ContainerApps _appsOf(ContainerSummary container) {
  final containerIp = container.networks.values.firstOrNull;
  final onHost = container.networkMode == 'host';
  final ports = <AppPort>{};
  for (final port in container.ports) {
    final private = port.privatePort;
    if (private == null || (port.type ?? 'tcp') != 'tcp') continue;
    final public = port.publicPort;
    ports.add(
      AppPort(
        privatePort: private,
        publicPort: public,
        hostIp: public == null ? null : _boundAddress(port.ip),
        forwardHost: public != null
            ? _boundAddress(port.ip) ?? _loopback
            : onHost
            ? _loopback
            : containerIp,
      ),
    );
  }
  return (
    container: container,
    links: labelLinks(container.labels),
    ports: [...ports],
  );
}

/// A published port's bound address when it names one interface; null for
/// every interface.
String? _boundAddress(String? ip) => switch (ip) {
  null || '' || '0.0.0.0' || '::' => null,
  final ip => ip,
};

/// The Apps sub-tab (DKE-08, DKE-09, NET-11, 03 §5.11): each running
/// container's label links, opened in the system browser, and its TCP
/// ports, each forwarded on request to a port on this device's loopback
/// interface and opened once it listens: a published one at its host
/// port, one that is not at the container's address. A forward to any
/// host and port the server reaches starts from the header. Forwards
/// show with their local port, connections and why the last one failed,
/// and an ended one with its reason until dismissed.
///
/// While [visible], it holds the server's container watch. Every forward
/// it opened closes once it is disposed or shows another server, since a
/// forward closes with its view (NET-11).
class AppsPanel extends StatefulWidget {
  const AppsPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<AppsPanel> createState() => _AppsPanelState();
}

class _AppsPanelState extends State<AppsPanel> {
  /// The server whose container watch this panel holds, if any.
  String? _held;

  /// Forwards to open in the browser once they listen.
  final Set<String> _openWhenReady = {};

  DockerController get _docker => widget.monitoring.docker;
  PortForwardsController get _forwards => widget.monitoring.forwards;

  @override
  void initState() {
    super.initState();
    _forwards.addListener(_onForwards);
    _sync();
  }

  @override
  void didUpdateWidget(AppsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId) {
      _release();
      _forwards.closeServer(oldWidget.serverId);
      _openWhenReady.clear();
    }
    _sync();
  }

  @override
  void dispose() {
    _forwards
      ..removeListener(_onForwards)
      ..closeServer(widget.serverId);
    _release();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    _docker.watchContainers(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.unwatchContainers(held);
  }

  void _onForwards() {
    for (final forward in _forwards.forwardsFor(widget.serverId)) {
      if (!_openWhenReady.contains(forward.forwardId)) continue;
      if (forward.ended != null) {
        _openWhenReady.remove(forward.forwardId);
      } else if (forward.localPort case final port?) {
        _openWhenReady.remove(forward.forwardId);
        unawaited(_openLocal(port));
      }
    }
  }

  void _forward(String host, int port) {
    final id = _forwards.open(widget.serverId, host: host, port: port);
    if (HandOffScope.maybeOf(context) != null) _openWhenReady.add(id);
  }

  Future<void> _openLocal(int port) async {
    final launcher = HandOffScope.maybeOf(context);
    if (launcher == null) return;
    await _open(launcher, Uri(scheme: 'http', host: _loopback, port: port));
  }

  Future<void> _open(HandOffLauncher launcher, Uri uri) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final notOpened = AppLocalizations.of(context).dockerLinksNotOpened;
    var opened = false;
    try {
      opened = await launcher.open(uri);
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
    if (!opened && overlay.mounted) showTopToast(overlay, message: notOpened);
  }

  Future<void> _askTarget() async {
    final target = await showDialog<(String, int)>(
      context: context,
      builder: (context) => const _ForwardDialog(),
    );
    if (target == null || !mounted) return;
    _forward(target.$1, target.$2);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        _docker.containersFor(widget.serverId),
        _forwards,
      ]),
      builder: (context, _) {
        final list = _docker.containersFor(widget.serverId).value;
        final containers = list.containers;
        final apps = containers == null ? null : containerApps(containers);
        final forwards = _forwards.forwardsFor(widget.serverId);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              l10n.appsForwardNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => unawaited(_askTarget()),
                icon: const Icon(Icons.swap_horiz),
                label: Text(l10n.appsForwardPort),
              ),
            ),
            if (forwards.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(l10n.appsForwardsTitle, style: theme.textTheme.titleSmall),
              for (final forward in forwards)
                _ForwardRow(
                  forward: forward,
                  onOpen: switch (forward.localPort) {
                    final port? when HandOffScope.maybeOf(context) != null =>
                      () => unawaited(_openLocal(port)),
                    _ => null,
                  },
                  onStop: () => _forwards.close(forward.forwardId),
                  onDismiss: () => _forwards.dismiss(forward.forwardId),
                ),
            ],
            const SizedBox(height: 16),
            if (apps == null)
              if (list.failure != null)
                Text(l10n.appsListFailed)
              else
                const Center(child: CircularProgressIndicator())
            else if (apps.isEmpty)
              Text(l10n.appsNone)
            else
              for (final app in apps)
                _ContainerAppsTile(app: app, onForward: _forward),
          ],
        );
      },
    );
  }
}

/// A container's links and ports.
class _ContainerAppsTile extends StatelessWidget {
  const _ContainerAppsTile({required this.app, required this.onForward});

  final ContainerApps app;
  final void Function(String host, int port) onForward;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final name = app.container.name ?? app.container.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(name, style: theme.textTheme.titleSmall),
          if (app.links.isNotEmpty) ContainerLinks(links: app.links),
          for (final port in app.ports)
            MergeSemantics(
              child: Row(
                spacing: 8,
                children: [
                  Expanded(child: Text(_portText(l10n, port))),
                  if (port.forwardHost case final host?)
                    TextButton(
                      onPressed: () => onForward(host, port.forwardPort),
                      child: Text(
                        l10n.appsForward,
                        semanticsLabel: l10n.appsForwardLabel(
                          _portText(l10n, port),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _portText(AppLocalizations l10n, AppPort port) =>
      switch (port.publicPort) {
        final public? => l10n.appsPortPublished(
          '${port.hostIp ?? '*'}:$public',
          port.privatePort.toString(),
        ),
        null => l10n.appsPortUnpublished(port.privatePort.toString()),
      };
}

/// One forward: where it listens and what it reaches, or why it ended.
class _ForwardRow extends StatelessWidget {
  const _ForwardRow({
    required this.forward,
    required this.onOpen,
    required this.onStop,
    required this.onDismiss,
  });

  final PortForwardState forward;
  final VoidCallback? onOpen;
  final VoidCallback onStop;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final target = forward.host.contains(':')
        ? '[${forward.host}]:${forward.port}'
        : '${forward.host}:${forward.port}';
    final ended = forward.ended;
    final localPort = forward.localPort;
    final title = switch ((ended, localPort)) {
      (final ended?, _) => l10n.appsForwardEnded(target, _endText(l10n, ended)),
      (null, final port?) => l10n.appsForwardListening(port.toString(), target),
      (null, null) => l10n.appsForwardOpening(target),
    };
    final detail = ended != null || localPort == null
        ? null
        : switch (forward.failure) {
            PortForwardFailure.forwardingDisabled =>
              l10n.appsForwardForwardingDisabled,
            PortForwardFailure.connectFailed => l10n.appsForwardConnectFailed(
              target,
            ),
            null => l10n.appsForwardConnections(forward.connections),
          };
    return MergeSemantics(
      child: Row(
        spacing: 8,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                if (detail != null)
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: forward.failure == null
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          if (ended == null) ...[
            if (onOpen != null)
              IconButton(
                tooltip: l10n.appsForwardOpen(target),
                icon: const Icon(Icons.open_in_new),
                onPressed: onOpen,
              ),
            IconButton(
              tooltip: l10n.appsForwardStop(target),
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: onStop,
            ),
          ] else
            IconButton(
              tooltip: l10n.appsForwardDismiss(target),
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }

  static String _endText(AppLocalizations l10n, PortForwardEnd end) =>
      switch (end) {
        PortForwardEnd.closed ||
        PortForwardEnd.duplicateId => l10n.appsForwardEndClosed,
        PortForwardEnd.noLink => l10n.appsForwardEndNoLink,
        PortForwardEnd.linkLost => l10n.appsForwardEndLinkLost,
        PortForwardEnd.bindFailed => l10n.appsForwardEndBindFailed,
        PortForwardEnd.invalidTarget => l10n.appsForwardEndInvalidTarget,
        PortForwardEnd.tooMany => l10n.appsForwardEndTooMany,
        PortForwardEnd.serverForgotten => l10n.appsForwardEndForgotten,
      };
}

/// Asks for a host and port as the server reaches them, checked with
/// [portForwardTargetProblem] as the engine checks them; null when
/// cancelled.
class _ForwardDialog extends StatefulWidget {
  const _ForwardDialog();

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  final _host = TextEditingController(text: _loopback);
  final _port = TextEditingController();
  PortForwardTargetProblem? _problem;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    final problem = portForwardTargetProblem(host, port);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop((host, port));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.appsForwardDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            Text(l10n.appsForwardDialogBody),
            TextField(
              controller: _host,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.appsForwardHost,
                errorText: _problem == PortForwardTargetProblem.badHost
                    ? l10n.appsForwardHostProblem
                    : null,
              ),
              onChanged: (_) => setState(() => _problem = null),
            ),
            TextField(
              controller: _port,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.appsForwardPortField,
                errorText: _problem == PortForwardTargetProblem.badPort
                    ? l10n.appsForwardPortProblem
                    : null,
              ),
              onChanged: (_) => setState(() => _problem = null),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.appsForwardCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.appsForwardStart)),
      ],
    );
  }
}
