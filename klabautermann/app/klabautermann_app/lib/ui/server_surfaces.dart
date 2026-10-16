import 'package:flutter/foundation.dart' show defaultTargetPlatform, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';

/// The server workspace's panels in the desktop tab strip's order (03
/// §10.2), with the streams each samples while it shows (03 §6.4, §7).
/// A panel without streams reads its data otherwise: log streams, Docker
/// queries (M3), or the probe's [HostProfileChanged].
enum ServerPanel {
  /// OV-01 to OV-03 from `core`, mounts from `fs`, OS and kernel from
  /// `identity`, and the health card's failed units (03 §7.1).
  overview({
    SampleStream.core,
    SampleStream.fs,
    SampleStream.identity,
    SampleStream.failedUnits,
  }),
  processes({SampleStream.procs}),
  services({SampleStream.units}),
  logs({}),
  jobs({SampleStream.timers, SampleStream.cron}),
  docker({}),

  /// Identity (SYS-01), uptime and boot (BOOT-01), disks (DSK-01/02) and
  /// network (NET-01).
  system({SampleStream.identity, SampleStream.fs, SampleStream.core}),
  access({});

  const ServerPanel(this.streams);

  final Set<SampleStream> streams;

  String label(AppLocalizations l10n) => switch (this) {
    overview => l10n.workspaceTabOverview,
    processes => l10n.workspaceTabProcesses,
    services => l10n.workspaceTabServices,
    logs => l10n.workspaceTabLogs,
    jobs => l10n.workspaceTabJobs,
    docker => l10n.workspaceTabDocker,
    system => l10n.workspaceTabSystem,
    access => l10n.workspaceTabAccess,
  };
}

/// Holds [serverId] open while mounted (03 §5.12): [MonitoringController]
/// connects on the first open view and disconnects a grace period after
/// the last one closes.
class OpenServer extends StatefulWidget {
  const OpenServer({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.child,
  });

  final MonitoringController monitoring;
  final String serverId;
  final Widget child;

  @override
  State<OpenServer> createState() => _OpenServerState();
}

class _OpenServerState extends State<OpenServer> {
  @override
  void initState() {
    super.initState();
    widget.monitoring.openServer(widget.serverId);
  }

  @override
  void didUpdateWidget(OpenServer oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      widget.monitoring == oldWidget.monitoring,
      'new controllers come with a new tree (KlabautermannApp, D44)',
    );
    if (widget.serverId == oldWidget.serverId) return;

    widget.monitoring
      ..openServer(widget.serverId)
      ..leaveServer(oldWidget.serverId);
  }

  @override
  void dispose() {
    widget.monitoring.leaveServer(widget.serverId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One surface's subscription (D45): [streams] of [serverId] under an id of
/// its own while [visible], and none while hidden or once unmounted (03
/// §6.4: everything pauses when its view is hidden). A tab view keeps a
/// hidden page built, so its owner passes [visible] from the selected
/// index. With [pullToRefresh], pulling the surface down from its top
/// has the engine read its streams at once (PLT-02).
class SampledSurface extends StatefulWidget {
  const SampledSurface({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.surface,
    required this.streams,
    required this.visible,
    this.pullToRefresh = false,
    required this.child,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The surface's kind, which its subscription id starts with.
  final String surface;

  /// What the surface shows; an empty set subscribes nothing.
  final Set<SampleStream> streams;

  final bool visible;

  /// As on a phone's server screen (03 §10.5); a desktop has no pull.
  final bool pullToRefresh;

  final Widget child;

  @override
  State<SampledSurface> createState() => _SampledSurfaceState();
}

class _SampledSurfaceState extends State<SampledSurface> {
  late final String _subscriptionId = widget.monitoring.newSubscriptionId(
    widget.surface,
  );

  /// The server the engine was asked to sample, if any.
  String? _held;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SampledSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      widget.monitoring == oldWidget.monitoring,
      'new controllers come with a new tree (KlabautermannApp, D44)',
    );
    if (!setEquals(oldWidget.streams, widget.streams)) _release();
    _sync();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible && widget.streams.isNotEmpty;
    if (_held != (wanted ? widget.serverId : null)) _release();
    if (!wanted || _held != null) return;

    widget.monitoring.subscribe(
      widget.serverId,
      _subscriptionId,
      widget.streams,
    );
    _held = widget.serverId;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    widget.monitoring.unsubscribe(held, _subscriptionId);
  }

  /// Reads what the surface samples at once; it samples nothing hidden.
  Future<void> _refresh() {
    final held = _held;
    if (held == null) return Future.value();
    return widget.monitoring.refresh(held, _subscriptionId);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.pullToRefresh) return widget.child;

    return RefreshIndicator.adaptive(
      onRefresh: _refresh,
      // A panel's own lists, a table's inside a sideways scroll included,
      // pull from their top as well as the panel around them.
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      // A panel whose content fits does not scroll, so this view, its
      // exact size, overscrolls for it. Not primary: the panel's own view
      // answers a status bar tap.
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          primary: false,
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox.fromSize(size: box.biggest, child: widget.child),
        ),
      ),
    );
  }
}

/// Reports to [MonitoringController.setAppActivity] whether the user can
/// see the app (03 §10.1, §6.4). Only phones go to the background: while
/// hidden, paused or detached, and back to the foreground once resumed or
/// inactive (shown without focus). A desktop app stays in the foreground
/// while it runs, minimized (hidden) too: 02 pauses in the background on
/// phones only (FL-04, FL-21, D34), and the background pause stops every
/// subscription, link and probe, which would stop the alerts 9.5 item 7
/// promises while the app is open.
class AppActivityReporter extends StatefulWidget {
  const AppActivityReporter({
    super.key,
    required this.monitoring,
    required this.child,
  });

  final MonitoringController monitoring;
  final Widget child;

  @override
  State<AppActivityReporter> createState() => _AppActivityReporterState();
}

class _AppActivityReporterState extends State<AppActivityReporter> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: _report);
    // The app may already be out of sight when this mounts; the engine
    // assumes the foreground until told otherwise.
    if (SchedulerBinding.instance.lifecycleState case final state?) {
      _report(state);
    }
  }

  void _report(AppLifecycleState state) {
    final phone = switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => false,
    };
    widget.monitoring.setAppActivity(switch (state) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached when phone => AppActivity.background,
      _ => AppActivity.foreground,
    });
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
