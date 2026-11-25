import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../ui/charts/series_ring.dart';
import '../ui/charts/time_series.dart';
import 'account_reads.dart';
import 'attention.dart';
import 'container_columns.dart';
import 'container_terminals.dart';
import 'disk_usage_reads.dart';
import 'docker_controller.dart';
import 'docker_endpoint_choices.dart';
import 'history_reads.dart';
import 'host_reads.dart';
import 'job_history_reads.dart';
import 'log_reads.dart';
import 'log_streams.dart';
import 'monitoring/background_pause.dart';
import 'monitoring/freshness_clock.dart';
import 'monitoring/pending_refresh.dart';
import 'monitoring/server_readings.dart';
import 'package_reads.dart';
import 'port_forwards.dart';
import 'stack_folders.dart';
import 'timer_detail_reads.dart';
import 'tls_endpoints.dart';

export 'monitoring/background_pause.dart' show BackgroundPause;
export 'monitoring/freshness_clock.dart' show kFreshnessTick;
export 'monitoring/pending_refresh.dart' show kRefreshWait;
export 'monitoring/server_readings.dart'
    show
        MetricSeries,
        SamplingStatus,
        chartGapReasonOf,
        kSessionRingCapacity,
        sampleAge;

/// How long a server's link outlives the last view that opened it, as long
/// as the grace 03 §5.1 and D34 give a backgrounded phone's link: stepping
/// to another server and back keeps one long-lived connection (03 §5.12)
/// instead of a new login each time.
const Duration kLinkLeaveGrace = Duration(seconds: 30);

/// The monitoring concern (03 §10.1): what the engine should keep linked
/// and sample for what the user can see, and what comes back.
///
/// Views open and leave servers: the first open sends [Connect], the last
/// leave [Disconnect] after the grace. Visible surfaces hold subscriptions,
/// each under its own id (D45). The app's activity goes out when it
/// changes. A server that leaves the fleet takes its link and subscriptions
/// with it in the engine (03 §5.1), so it is sent nothing while it is gone,
/// and if it comes back, the views still holding it connect and subscribe
/// again. Samples land in a listenable per server and stream and a ring
/// per [MetricSeries], so a tick repaints only the surfaces painting it
/// (§10.1 forbids a whole-app rebuild every 1 to 5 s).
///
/// Everything here lasts one engine run. An [EngineClient] is one run (its
/// handshake consumes [EngineReady], and the engine's exit closes its
/// events), so a restarted engine comes with a new client and a controller
/// built anew over it: the seq floor starts empty, as the new engine counts
/// from the start (D44), and surfaces resubscribe as `KlabautermannApp`
/// remounts them for the new controller.
final class MonitoringController extends ChangeNotifier {
  /// [linkGrace] replaces [kLinkLeaveGrace]; zero sends [Disconnect] at
  /// once. [now] is what [clock] reads. [dockerEndpointChoices], the
  /// Docker sockets chosen on this device (CN-09), outlives this run and
  /// goes to [docker]; without it the choices last this run.
  /// [stackFolders], the folders STK-08 scans on each server, and
  /// [tlsEndpoints], the endpoints CRT-01 checks, outlive it the same way.
  MonitoringController(
    this._engine, {
    this._linkGrace = kLinkLeaveGrace,
    DateTime Function() now = DateTime.now,
    DockerEndpointChoices? dockerEndpointChoices,
    StackFolders? stackFolders,
    TlsEndpoints? tlsEndpoints,
    AttentionAcks? attentionAcks,
    ContainerColumnChoice? containerColumns,
  }) : _clock = FreshnessClock(now),
       stackFolders = stackFolders ?? StackFolders(),
       tlsEndpoints = tlsEndpoints ?? TlsEndpoints(),
       attentionAcks = attentionAcks ?? AttentionAcks(),
       containerColumns = containerColumns ?? ContainerColumnChoice() {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
    hostReads = HostReads(_engine, _onEngineDone);
    _backgroundPause = BackgroundPauseNotifier(
      () => _clock.value,
      () => {
        // A server the fleet no longer lists has no phase: its readings
        // were purged, and its SamplingStates are dropped.
        for (final MapEntry(key: id, value: readings) in _readings.entries)
          if (readings.sampling.value?.state.phase == SamplingPhase.sampling)
            id,
      },
      (serverId) => _openViews.containsKey(serverId),
    );
    logs = LogStreams(_engine);
    terminals = ContainerTerminals(_engine);
    jobHistory = JobHistoryReads(_engine);
    packages = PackageReads(_engine);
    rollups = HistoryReads(_engine);
    accounts = AccountReads(_engine);
    diskUsage = DiskUsageReads(_engine);
    timerDetails = TimerDetailReads(_engine);
    forwards = PortForwardsController(_engine);
    docker = DockerController(
      _engine,
      endpointChoices: dockerEndpointChoices,
      now: now,
    );
  }

  /// The folders the Stacks sub-tab scans for stacks without containers
  /// (STK-08), chosen on this device.
  final StackFolders stackFolders;

  /// The Containers tab's columns as chosen on this device (CTR-08),
  /// which outlive this run as [stackFolders] do.
  final ContainerColumnChoice containerColumns;

  /// The endpoints the System tab's Certificates section checks from this
  /// device (CRT-01), chosen on this device.
  final TlsEndpoints tlsEndpoints;

  /// TRI-03's acknowledged problems, kept on this device.
  final AttentionAcks attentionAcks;

  /// The log streams panels open, and each server's journal access for
  /// LOG-04's notice (03 §10.1, §10.8): a concern of its own that lasts
  /// this engine run, listening to the engine beside this controller. It
  /// sends every [OpenLogStream] the app sends, [openLogRead]'s included,
  /// since a rejection names no stream.
  late final LogStreams logs;

  /// The container shells views open (03 §7.13, CTX-07): a concern of
  /// its own for this engine run, listening beside [logs].
  late final ContainerTerminals terminals;

  /// The Jobs tab's last runs (JOB-05), a concern of its own beside
  /// [logs].
  late final JobHistoryReads jobHistory;

  /// The System tab's package checks (PKG-01 to PKG-03), a concern of its
  /// own beside [logs].
  late final PackageReads packages;

  /// The on-device history the History card charts (HIS-01), a concern of
  /// its own beside [logs].
  late final HistoryReads rollups;

  /// The System tab's account reads (ACC-01, ACC-02), a concern of its
  /// own beside [logs].
  late final AccountReads accounts;

  /// The disk space explorer's folder reads (DSK-07), a concern of its
  /// own beside [logs].
  late final DiskUsageReads diskUsage;

  /// The Jobs tab's timer reads (JOB-02), a concern of its own beside
  /// [logs].
  late final TimerDetailReads timerDetails;

  /// The one-shot host, unit, redaction and certificate reads, a concern
  /// of its own beside [logs].
  late final HostReads hostReads;

  /// Each server's Docker endpoint, which the server header names, and
  /// the engine details the Docker tab shows (03 §5.9, §10.2): a concern
  /// of its own for this engine run, listening beside [logs].
  late final DockerController docker;

  /// The port forwards this run opened (NET-11, DKE-09), a concern of its
  /// own beside [docker].
  late final PortForwardsController forwards;

  final EngineClient _engine;
  final Duration _linkGrace;
  final FreshnessClock _clock;
  late final StreamSubscription<EngineEvent> _events;

  final Map<String, ServerReadings> _readings = {};

  /// The refreshes waiting for their readings.
  final Set<PendingRefresh> _refreshes = {};

  /// The fleet's ids from the last [CatalogReplaced] this controller saw.
  /// The engine's startup fleet goes to the fleet controller, its client's
  /// first listener (`main.dart`), so this is null until the next import;
  /// no sample can precede the views that subscribe it, which show fleet
  /// servers only, so until then every server counts as listed.
  Set<String>? _fleetIds;

  /// The streams the engine was asked to sample, by `(serverId,
  /// subscriptionId)`.
  final Map<(String, String), Set<SampleStream>> _subscribed = {};
  int _subscriptionCount = 0;

  /// How many views have each server open, and the [Disconnect]s waiting
  /// out the grace.
  final Map<String, int> _openViews = {};
  final Map<String, Timer> _leaving = {};

  /// What the engine was last told. It starts with the app in the
  /// foreground, so only a change is sent (03 §10.1).
  AppActivity _activity = AppActivity.foreground;

  /// The 6.4 column the engine samples at; it starts at Desktop's.
  CadenceProfile _cadence = CadenceProfile.desktop;

  /// Each server's cap as the engine was last told; none at the start.
  Map<String, CadenceProfile> _caps = const {};
  bool _engineStopped = false;

  /// The phone's last background pause, fed the activity and sampling
  /// phases this controller sees.
  late final BackgroundPauseNotifier _backgroundPause;

  final ValueNotifier<Map<String, ConnectRejectedReason>> _connectRejections =
      ValueNotifier(const {});

  final ValueNotifier<Set<String>> _visibleServers = ValueNotifier(const {});

  /// Set by [dispose]: views that let go as the tree unmounts after it
  /// change nothing.
  bool _disposed = false;

  /// The latest sample of [serverId]'s [stream]. A surface listens to this
  /// one box instead of the whole controller.
  ValueListenable<Sample?> sampleFor(String serverId, SampleStream stream) =>
      _server(serverId).box(stream);

  /// The latest sample of [serverId]'s [stream] that carried a reading
  /// rather than [CollectorUnavailable], or null before one: what a view
  /// keeps listing, marked as old, while the collector fails, as the
  /// System tab's mounts while `df` times out on a stale mount.
  ValueListenable<Sample?> lastReadingFor(
    String serverId,
    SampleStream stream,
  ) => _server(serverId).lastReading(stream);

  /// What the probe last found on [serverId] ([HostProfileChanged]):
  /// SYS-01's virtualization and the container facts behind D50's
  /// unknowns. Until this engine run's probe answers, it may be the device
  /// cache's copy from an earlier run, up to 24 hours old (D59; the
  /// event's `cachedAt` is not kept here yet), and it is null before
  /// either.
  ValueListenable<HostProfile?> profileFor(String serverId) =>
      _server(serverId).profile;

  /// How far [serverId]'s clock was from this device's at its last probe
  /// in this engine run (CN-17), or null before one.
  ValueListenable<ServerClock?> clockFor(String serverId) =>
      _server(serverId).clock;

  /// The session ring of [serverId]'s [series] as [stream] reports it
  /// (OV-03): one reading per kept sample of [stream], null where it had no
  /// value.
  SeriesRing seriesFor(
    String serverId,
    SampleStream stream,
    MetricSeries series,
  ) {
    assert(ringStreams.contains(stream), '$stream carries no metrics');
    return _server(serverId).rings(stream)[series]!;
  }

  /// The session history of [serverId]'s [series] from the `core` stream
  /// on a time axis (OV-03, 03 §10.7): a reading per sample at its
  /// [Sample.at], with a gap labelled with its reason wherever readings
  /// stopped (03 §9.5 item 5). A background pause, a link lost while
  /// sampling or a return to a link still down opens one when
  /// [SamplingState] says so, and a [Gap] or a failed reading opens one
  /// if none is open; the next reading closes it. A stream no
  /// subscription names ends its gap with an unknown reading, which
  /// breaks the line without a label.
  TimeSeriesRing historyFor(String serverId, MetricSeries series) =>
      _server(serverId).history[series]!;

  /// The phone's last time in the background while the engine sampled
  /// a server open at the return (03 §9.5 item 6), until the user
  /// dismisses it, leaves that server or the app goes to the background
  /// again; null otherwise, and always on a desktop, which never reports
  /// the background.
  ValueListenable<BackgroundPause?> get backgroundPause => _backgroundPause;

  void dismissBackgroundPause() => _backgroundPause.dismiss();

  /// Why the engine could not connect each server whose last [Connect] it
  /// rejected with [ConnectRejected] (D61): it has no config to dial with
  /// until the user imports their SSH config again, or a synced server's
  /// endpoint waits for confirmation (03 §4.7). Only servers a view
  /// holds are kept. A server's entry goes when this controller sends its
  /// next [Connect], which the next fleet does for each one it still
  /// lists, since that fleet may give it a config.
  ValueListenable<Map<String, ConnectRejectedReason>> get connectRejections =>
      _connectRejections;

  /// The servers a view holds open while the user can see the app: every
  /// [openServer] count in the foreground, none in the background. Admin
  /// memory (FL-16) re-arms admin mode only on a server the user is
  /// looking at, never over a link dialed unattended.
  ValueListenable<Set<String>> get visibleServers => _visibleServers;

  void _noteVisible() {
    if (_disposed) return;
    final visible = _activity == AppActivity.foreground
        ? _openViews.keys.toSet()
        : const <String>{};
    if (setEquals(visible, _visibleServers.value)) return;
    _visibleServers.value = Set.unmodifiable(visible);
  }

  /// The freshness clock: this device's time, notifying every
  /// [kFreshnessTick] while anything listens, so an age keeps counting
  /// between samples. Nothing ticks while nothing shows one. With the
  /// [Sample.at] of a stream's latest sample ([sampleFor]) it gives that
  /// reading's age ([sampleAge], 03 §9.5 item 4). Freshness is per stream:
  /// a slow stream's newer reading says nothing about a stalled fast one.
  ValueListenable<DateTime> get clock => _clock;

  /// What the engine last said sampling [serverId] is doing, or null
  /// before it said anything this engine run. With [sampleFor] and [clock]
  /// it gives a stream's freshness line (`ui/freshness.dart`, 03 §9.5 item
  /// 4): paused in the background, or disconnected since the link was lost
  /// while sampling.
  ValueListenable<SamplingStatus?> samplingFor(String serverId) =>
      _server(serverId).sampling;

  bool isSubscribed(String serverId, String subscriptionId) =>
      _subscribed.containsKey((serverId, subscriptionId));

  /// A subscription id no other surface holds: [surface] names the kind,
  /// and a count keeps two of a kind apart, such as a closing page and the
  /// one replacing it (D45).
  String newSubscriptionId(String surface) =>
      '$surface-${_subscriptionCount++}';

  /// Asks the engine to sample [streams] of [serverId] for the surface
  /// [subscriptionId] (03 §10.1, D45). Each surface holds its own id, so
  /// unsubscribing one leaves the streams of the others running;
  /// subscribing an id again replaces its streams.
  void subscribe(
    String serverId,
    String subscriptionId,
    Set<SampleStream> streams,
  ) {
    assert(streams.isNotEmpty, 'unsubscribe instead of naming no stream');
    final named = _ringStreamsNamed(serverId);
    final kept = _subscribed[(serverId, subscriptionId)] = Set.unmodifiable(
      streams,
    );
    _followRingStreams(serverId, named);
    if (!_listed(serverId)) return;
    _send(
      Subscribe(
        serverId: serverId,
        subscriptionId: subscriptionId,
        streams: kept,
      ),
    );
  }

  void unsubscribe(String serverId, String subscriptionId) {
    final named = _ringStreamsNamed(serverId);
    if (_subscribed.remove((serverId, subscriptionId)) == null) return;
    _followRingStreams(serverId, named);
    if (!_listed(serverId)) return;
    _send(Unsubscribe(serverId: serverId, subscriptionId: subscriptionId));
  }

  /// Asks the engine to read the streams of [serverId]'s subscription
  /// [subscriptionId] at once (PLT-02's pull to refresh). Completes once
  /// each has a newer sample, failed readings included, once the server
  /// stops sampling, or after [kRefreshWait]; at once when the engine is
  /// not sampling the server, as while links are off or the link is down,
  /// since no reading would come.
  Future<void> refresh(String serverId, String subscriptionId) {
    final streams = _subscribed[(serverId, subscriptionId)];
    if (streams == null || !_listed(serverId)) return Future.value();

    _send(
      RefreshSubscription(serverId: serverId, subscriptionId: subscriptionId),
    );
    final readings = _readings[serverId];
    if (_engineStopped ||
        readings == null ||
        readings.sampling.value?.state.phase != SamplingPhase.sampling) {
      return Future.value();
    }
    final refresh = PendingRefresh(
      serverId,
      readings,
      streams,
      _refreshes.remove,
    );
    _refreshes.add(refresh);
    return refresh.done;
  }

  /// Whether the fleet lists [serverId]. The engine holds no link or
  /// subscription for a server it does not list (03 §5.1).
  bool _listed(String serverId) => _fleetIds?.contains(serverId) ?? true;

  /// The ring streams some subscription of [serverId] names.
  Set<SampleStream> _ringStreamsNamed(String serverId) => {
    for (final MapEntry(key: (id, _), value: streams) in _subscribed.entries)
      if (id == serverId) ...streams.where(ringStreams.contains),
  };

  /// Marks where a ring stream of [serverId] went unsampled, given the
  /// streams [before] a change: the engine samples a stream only while a
  /// subscription names it (03 §6.4) and reports no [Gap] for one nobody
  /// asked for, so only this controller knows its rings have a hole, which
  /// they must not draw across (9.5 item 5). A stream handed from one
  /// surface to another within one turn (a tab switch lets the old panel
  /// go before the new one subscribes) has no hole, so a stream counts as
  /// unnamed only if no subscription names it once the turn is over.
  void _followRingStreams(String serverId, Set<SampleStream> before) {
    final now = _ringStreamsNamed(serverId);
    for (final stream in now.difference(before)) {
      _readings[serverId]?.named(stream);
    }
    final left = before.difference(now);
    if (left.isEmpty) return;
    scheduleMicrotask(() {
      final unnamed = left.difference(_ringStreamsNamed(serverId));
      for (final stream in unnamed) {
        _readings[serverId]?.unnamed(stream, _clock.value);
      }
    });
  }

  /// Opens a bounded read of [spec], a window ([LogStreamSpec.follow]
  /// false) such as SVC-04's unit logs (03 §7.5), through [logs]. The
  /// returned [LogRead] reports its records and state; the caller closes
  /// it once it no longer shows it.
  LogRead openLogRead(LogStreamSpec spec) => LogRead(logs, spec);

  /// A view of [serverId] opened (the desktop workspace, the phone's pushed
  /// screen). The first sends [Connect]; within the grace after the last
  /// leave the link is still held and nothing is sent.
  ///
  /// A server the engine has no config for gets [ConnectRejected], which
  /// [connectRejections] keeps for the views to show. A [RequestRejected]
  /// of [Connect], for an id outside the engine's fleet or from an engine
  /// spawned with links off, is ignored like every event this controller
  /// does not consume: the views stay as they are and show no error.
  void openServer(String serverId) {
    final views = _openViews[serverId] ?? 0;
    _openViews[serverId] = views + 1;
    if (views > 0) return;
    _noteVisible();

    final leaving = _leaving.remove(serverId);
    if (leaving != null) {
      leaving.cancel();
      return;
    }
    if (_listed(serverId)) _connect(serverId);
  }

  /// The user's retry of [serverId]'s connect while a view shows it (03
  /// D71): a connect that failed waiting for them, or a host key that
  /// changed, is otherwise tried again only by the next [openServer]
  /// after the grace. The engine takes the [Connect] as the user's own,
  /// so a changed key is reviewed again. Nothing is sent while no view
  /// shows the server or the fleet does not list it.
  void retryConnect(String serverId) {
    if ((_openViews[serverId] ?? 0) == 0 || !_listed(serverId)) return;
    _connect(serverId);
  }

  /// A view [openServer] counted closed. The last sends [Disconnect] once
  /// the grace passes without another open.
  void leaveServer(String serverId) {
    final views = _openViews[serverId];
    assert(views != null, 'leaveServer without openServer for $serverId');
    if (views == null) return;
    if (views > 1) {
      _openViews[serverId] = views - 1;
      return;
    }

    _openViews.remove(serverId);
    _noteVisible();
    _backgroundPause.forget(serverId);
    _forgetRejection(serverId);
    // A stopped engine (or a disposed controller) holds no link, nor does
    // the engine hold one for a server the fleet no longer lists, so no
    // grace timer waits to disconnect it.
    if (_engineStopped || !_listed(serverId)) return;
    if (_linkGrace == Duration.zero) {
      _send(Disconnect(serverId));
      return;
    }
    _leaving[serverId] = Timer(_linkGrace, () {
      _leaving.remove(serverId);
      _send(Disconnect(serverId));
    });
  }

  /// Picks the 6.4 column the engine samples at (SAF-19), when that
  /// changed.
  void setCadenceProfile(CadenceProfile profile) {
    if (profile == _cadence) return;
    _cadence = profile;
    _send(SetCadenceProfile(profile));
  }

  /// The 6.4 column the engine samples [serverId] at: the app's, or its
  /// cap's when that is slower, as the scheduler resolves it.
  CadenceProfile cadenceFor(String serverId) => switch (_caps[serverId]) {
    final cap? when cap.index > _cadence.index => cap,
    _ => _cadence,
  };

  /// Caps each server in [caps] at its column and lifts the caps of those
  /// left out (SAF-19), telling the engine only what changed.
  void setCadenceCaps(Map<String, CadenceProfile> caps) {
    for (final serverId in {..._caps.keys, ...caps.keys}) {
      final cap = caps[serverId];
      if (cap == _caps[serverId]) continue;
      _send(SetServerCadenceCap(serverId, cap));
    }
    _caps = Map.unmodifiable(caps);
  }

  /// Tells the engine whether the user can see the app (03 §10.1), when
  /// that changed.
  void setAppActivity(AppActivity activity) {
    if (activity == _activity) return;
    _activity = activity;
    _backgroundPause.noteActivity(activity);
    _noteVisible();
    _send(SetAppActivity(activity));
  }

  /// Sends [Connect] for [serverId], whose earlier rejection the answer
  /// replaces.
  void _connect(String serverId) {
    _forgetRejection(serverId);
    _send(Connect(serverId));
  }

  void _forgetRejection(String serverId) {
    final rejections = _connectRejections.value;
    if (!rejections.containsKey(serverId)) return;
    _connectRejections.value = Map.unmodifiable(
      {...rejections}..remove(serverId),
    );
  }

  /// Sends [request] unless the engine has stopped: views and surfaces let
  /// go as the app closes, and a stopped engine has nothing to hear.
  void _send(EngineRequest request) {
    if (_engineStopped) return;
    try {
      _engine.send(request);
    } on StateError {
      _onEngineDone();
    }
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      // The host, unit, redaction and TLS reads are matched inside
      // their own EngineReads, a rejection of theirs included.
      case Sample(:final serverId):
        // One still in flight when its server left the fleet would bring
        // back what the purge dropped.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _server(serverId).accept(event);
      case HostProfileChanged(:final serverId, :final profile):
        // As for a sample: a server that left the fleet stays purged.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _server(serverId).profile.value = profile;
      case ServerClock(:final serverId):
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _server(serverId).clock.value = event;
      case CatalogReplaced(:final entries):
        final fleetIds = {for (final entry in entries) entry.serverId};
        final rejected = _connectRejections.value.keys.toList();
        _replaceFleet(fleetIds);
        // A new fleet may give a rejected server a config, so its views
        // connect again; one that still has none is rejected again. One
        // that left the fleet takes its rejection with it. Cleared first,
        // so listeners hear one change rather than one per server.
        if (rejected.isNotEmpty) _connectRejections.value = const {};
        for (final serverId in rejected) {
          if (fleetIds.contains(serverId) && _openViews.containsKey(serverId)) {
            _connect(serverId);
          }
        }
      case EndpointChanged(:final serverId):
        // SYN-08: the server's id now names another machine, so what was
        // read from the old one goes, in place, as its views stay open.
        _readings[serverId]?.clear();
        // The engine closed the link and dials the server no more until
        // the user confirms it again; a view still open connects again so
        // its rejection says why.
        if (_openViews.containsKey(serverId)) _connect(serverId);
      case ConnectRejected(:final serverId, :final reason):
        // Only for a server a view still holds: one whose views all left
        // has nothing to show it on. One answered after its server left
        // the fleet stays purged, as a sample does.
        if (!_openViews.containsKey(serverId)) return;
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _connectRejections.value = Map.unmodifiable({
          ..._connectRejections.value,
          serverId: reason,
        });
      case SamplingState(:final serverId):
        // As for a sample: a server that left the fleet stays purged.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        final readings = _server(serverId);
        final status = SamplingStatus(
          event,
          previous: readings.sampling.value?.state.phase,
        );
        readings
          ..sampling.value = status
          ..phaseChanged(status);
        _backgroundPause.notePhase(serverId, event.phase);
      case Gap(:final serverId):
        // As for a sample: a server that left the fleet stays purged.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _server(serverId).gap(event);
      case EngineEvent():
        break;
    }
  }

  /// SYN-08: a server that leaves the fleet takes its readings, last
  /// readings, rings, profile and seq floor with it, and comes back, if it
  /// does, without them. The engine forgets its link and subscriptions too
  /// (03 §5.1), so its pending [Disconnect] goes, and a server that comes
  /// back gets [Connect] and [Subscribe] again for the views and surfaces
  /// still holding it. Their counts and subscriptions stay meanwhile: the
  /// views leave and unsubscribe when they unmount.
  void _replaceFleet(Set<String> fleetIds) {
    final before = _fleetIds;
    _fleetIds = fleetIds;
    for (final refresh in _refreshes.toList()) {
      if (!fleetIds.contains(refresh.serverId)) refresh.finish();
    }
    _readings.removeWhere((serverId, readings) {
      if (fleetIds.contains(serverId)) return false;
      readings.dispose();
      return true;
    });
    _leaving.removeWhere((serverId, timer) {
      if (fleetIds.contains(serverId)) return false;
      timer.cancel();
      return true;
    });

    // Until the first fleet this controller saw, every server was listed.
    if (before == null) return;
    for (final serverId in fleetIds.difference(before)) {
      if (_openViews.containsKey(serverId)) _connect(serverId);
      for (final MapEntry(key: (id, subscriptionId), value: streams)
          in _subscribed.entries) {
        if (id != serverId) continue;
        _send(
          Subscribe(
            serverId: serverId,
            subscriptionId: subscriptionId,
            streams: streams,
          ),
        );
      }
    }
  }

  void _onEngineDone() {
    if (_engineStopped) return;
    _engineStopped = true;
    // HostReads answers each read's no-link or null value, as the loops
    // here did; a helper that already stopped does nothing again.
    hostReads.dispose();
    for (final timer in _leaving.values) {
      timer.cancel();
    }
    _leaving.clear();
  }

  ServerReadings _server(String serverId) =>
      _readings.putIfAbsent(serverId, ServerReadings.new);

  @override
  void dispose() {
    unawaited(_events.cancel());
    logs.dispose();
    terminals.dispose();
    jobHistory.dispose();
    packages.dispose();
    rollups.dispose();
    accounts.dispose();
    diskUsage.dispose();
    timerDetails.dispose();
    forwards.dispose();
    docker.dispose();
    _onEngineDone();
    for (final refresh in _refreshes.toList()) {
      refresh.finish();
    }
    for (final readings in _readings.values) {
      readings.dispose();
    }
    // A pending check for unnamed ring streams then finds no readings.
    _readings.clear();
    _clock.dispose();
    _backgroundPause.dispose();
    _connectRejections.dispose();
    _disposed = true;
    _visibleServers.dispose();
    super.dispose();
  }
}
