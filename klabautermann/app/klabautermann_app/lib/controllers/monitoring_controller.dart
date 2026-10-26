import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../ui/charts/series_ring.dart';
import '../ui/charts/time_series.dart';
import 'account_reads.dart';
import 'container_terminals.dart';
import 'docker_controller.dart';
import 'docker_endpoint_choices.dart';
import 'history_reads.dart';
import 'job_history_reads.dart';
import 'log_reads.dart';
import 'log_streams.dart';
import 'stack_folders.dart';

/// How long a server's link outlives the last view that opened it, as long
/// as the grace 03 §5.1 and D34 give a backgrounded phone's link: stepping
/// to another server and back keeps one long-lived connection (03 §5.12)
/// instead of a new login each time.
const Duration kLinkLeaveGrace = Duration(seconds: 30);

/// The readings a session ring keeps per series (OV-03): ten minutes at
/// the Desktop `core` cadence of 2 s, 25 at the `overview` cadence of 5 s
/// (03 §6.4).
const int kSessionRingCapacity = 300;

/// How often [MonitoringController.clock] ticks: 03 §9.5 item 4 words
/// freshness in seconds ("updated 4 s ago").
const Duration kFreshnessTick = Duration(seconds: 1);

/// The longest a refresh waits for its readings (PLT-02) [E]: a slow
/// sampler's reply on a slow link comes well within it, and a hung `df`
/// does not keep the pull indicator spinning. The panel's freshness line
/// keeps telling a reading's age after it.
const Duration kRefreshWait = Duration(seconds: 10);

/// The streams whose readings feed [MetricSeries] rings.
const Set<SampleStream> _ringStreams = {
  SampleStream.overview,
  SampleStream.core,
};

/// One chart series a session ring keeps (OV-03), read from an `overview`
/// or `core` reading.
enum MetricSeries {
  /// CPU busy in percent ([CpuPercentages.busy]).
  cpuBusy,

  /// Used memory in bytes ([MemoryUsage.usedBytes]).
  memoryUsed,

  /// Used swap in bytes ([MemoryUsage.swapUsedBytes]).
  swapUsed,

  /// The one-minute load average ([LoadAvg.load1]).
  load1;

  /// This series' value in [result], or null when the reading has none:
  /// an unknown value is a gap in the ring, never zero (03 §10.4).
  double? readFrom(SampleResult result) {
    final (cpu, memory, load) = switch (result) {
      OverviewResult(:final cpu, :final memory, :final load) ||
      CoreResult(:final cpu, :final memory, :final load) => (cpu, memory, load),
      _ => (null, null, null),
    };
    return switch (this) {
      cpuBusy => cpu?.busy,
      memoryUsed => memory?.usedBytes?.toDouble(),
      swapUsed => memory?.swapUsedBytes?.toDouble(),
      load1 => load?.load1,
    };
  }
}

/// How old a reading taken [at] is by [now] (03 §9.5 item 4), or null
/// without one. The engine stamps [Sample.at] with this device's clock, so
/// only a clock set back since makes the age negative; that reads as zero.
Duration? sampleAge(DateTime? at, DateTime now) {
  if (at == null) return null;
  final age = now.difference(at);
  return age.isNegative ? Duration.zero : age;
}

/// Why a session history has no data, from a [Gap]'s cause (03 §9.5
/// item 5).
ChartGapReason chartGapReasonOf(GapCause cause) => switch (cause) {
  GapCause.background => ChartGapReason.background,
  GapCause.disconnected => ChartGapReason.disconnected,
  GapCause.readingLost => ChartGapReason.readingFailed,
};

/// A phone's time in the background (03 §9.5 item 6): from [start] to
/// [end] by this device's clock, which paused sampling [serverIds], the
/// servers the engine was sampling, or said it paused, whose screen was
/// open at the return.
@immutable
final class BackgroundPause {
  BackgroundPause({
    required this.start,
    required this.end,
    required Set<String> serverIds,
  }) : serverIds = Set.unmodifiable(serverIds);

  final DateTime start, end;
  final Set<String> serverIds;
}

/// What the engine last said sampling a server is doing ([state]), and
/// the phase before it ([previous]; null for the first this engine run).
/// The protocol has the engine send a [SamplingState] at each phase
/// change, so the pair tells a link lost while sampling, whose loss
/// `state.since` dates, from one already down when a view or the return
/// from the background subscribed the server again, whose phase began
/// only then (03 §9.5 item 4).
@immutable
final class SamplingStatus {
  const SamplingStatus(this.state, {this.previous});

  final SamplingState state;
  final SamplingPhase? previous;
}

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
  /// [stackFolders], the folders STK-08 scans on each server, outlives it
  /// the same way.
  MonitoringController(
    this._engine, {
    this._linkGrace = kLinkLeaveGrace,
    DateTime Function() now = DateTime.now,
    DockerEndpointChoices? dockerEndpointChoices,
    StackFolders? stackFolders,
  }) : _clock = _FreshnessClock(now),
       stackFolders = stackFolders ?? StackFolders() {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
    logs = LogStreams(_engine);
    terminals = ContainerTerminals(_engine);
    jobHistory = JobHistoryReads(_engine);
    rollups = HistoryReads(_engine);
    accounts = AccountReads(_engine);
    docker = DockerController(
      _engine,
      endpointChoices: dockerEndpointChoices,
      now: now,
    );
  }

  /// The folders the Stacks sub-tab scans for stacks without containers
  /// (STK-08), chosen on this device.
  final StackFolders stackFolders;

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

  /// The on-device history the History card charts (HIS-01), a concern of
  /// its own beside [logs].
  late final HistoryReads rollups;

  /// The System tab's account reads (ACC-01, ACC-02), a concern of its
  /// own beside [logs].
  late final AccountReads accounts;

  /// Each server's Docker endpoint, which the server header names, and
  /// the engine details the Docker tab shows (03 §5.9, §10.2): a concern
  /// of its own for this engine run, listening beside [logs].
  late final DockerController docker;

  final EngineClient _engine;
  final Duration _linkGrace;
  final _FreshnessClock _clock;
  late final StreamSubscription<EngineEvent> _events;

  final Map<String, _ServerReadings> _readings = {};

  /// The host queries waiting for their answers, by query id.
  final Map<String, (String, Completer<HostResult>)> _hostQueries = {};
  int _nextHostQuery = 0;

  /// Unit reads waiting on the engine, by request id.
  final Map<String, (String, Completer<UnitQueryResult>)> _unitQueries = {};
  int _nextUnitQuery = 0;

  /// The [redactLines] requests waiting for the engine, by request id.
  final Map<String, Completer<String?>> _redactions = {};
  int _nextRedaction = 0;

  /// The refreshes waiting for their readings.
  final Set<_PendingRefresh> _refreshes = {};

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
  bool _engineStopped = false;

  /// When the app last went to the background, and the servers the
  /// engine was sampling then or said it paused since; the return words
  /// [backgroundPause] from them.
  DateTime? _backgroundSince;
  Set<String> _pausedServers = {};
  final ValueNotifier<BackgroundPause?> _backgroundPause = ValueNotifier(null);

  final ValueNotifier<Map<String, ConnectRejectedReason>> _connectRejections =
      ValueNotifier(const {});

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
    assert(_ringStreams.contains(stream), '$stream carries no metrics');
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

  void dismissBackgroundPause() => _backgroundPause.value = null;

  /// Why the engine could not connect each server whose last [Connect] it
  /// rejected with [ConnectRejected] (D61): it has no config to dial with
  /// until the user imports their SSH config again, or a synced server's
  /// endpoint waits for confirmation (03 §4.7). Only servers a view
  /// holds are kept. A server's entry goes when this controller sends its
  /// next [Connect], which the next fleet does for each one it still
  /// lists, since that fleet may give it a config.
  ValueListenable<Map<String, ConnectRejectedReason>> get connectRejections =>
      _connectRejections;

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

  /// Reads [query] on [serverId]: the files under `/var/log` or the
  /// journal's boots (LOG-08, LOG-09). A stopped engine answers no link.
  Future<HostResult> queryHost(String serverId, HostQuerySpec query) {
    final queryId = 'host-${_nextHostQuery++}';
    if (_engineStopped) return Future.value(_noHostLink(serverId, queryId));
    final answer = Completer<HostResult>();
    _hostQueries[queryId] = (serverId, answer);
    _send(HostQuery(serverId: serverId, queryId: queryId, query: query));
    return answer.future;
  }

  /// [lines] joined by newlines, through the engine's secret redactor
  /// (LOG-10, 03 §8.9), which the app cannot import; null when the engine
  /// has stopped, so nothing is exported unredacted by accident.
  Future<String?> redactLines(List<String> lines) {
    if (_engineStopped) return Future.value();
    final requestId = 'redact-${_nextRedaction++}';
    final answer = Completer<String?>();
    _redactions[requestId] = answer;
    _send(RedactLines(requestId, lines));
    return answer.future;
  }

  static HostResult _noHostLink(String serverId, String queryId) => HostResult(
    serverId: serverId,
    queryId: queryId,
    payload: const HostQueryFailed(HostQueryFailure.noLink),
  );

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
    final refresh = _PendingRefresh(
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
      if (id == serverId) ...streams.where(_ringStreams.contains),
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

  /// Reads [query] on [serverId]: a unit's file, its resources or the
  /// sockets (03 §7.5, SVC-07, SVC-08, SVC-10). A stopped engine answers
  /// no link.
  Future<UnitQueryResult> queryUnit(String serverId, UnitQuerySpec query) {
    final requestId = 'unit-${_nextUnitQuery++}';
    if (_engineStopped) return Future.value(_noUnitLink(serverId, requestId));
    final answer = Completer<UnitQueryResult>();
    _unitQueries[requestId] = (serverId, answer);
    _send(UnitQuery(serverId: serverId, requestId: requestId, query: query));
    return answer.future;
  }

  static UnitQueryResult _noUnitLink(String serverId, String requestId) =>
      UnitQueryResult(
        serverId: serverId,
        requestId: requestId,
        payload: const UnitQueryFailed(UnitQueryFailure.noLink),
      );

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

    final leaving = _leaving.remove(serverId);
    if (leaving != null) {
      leaving.cancel();
      return;
    }
    if (_listed(serverId)) _connect(serverId);
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
    _forgetPause(serverId);
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

  /// Tells the engine whether the user can see the app (03 §10.1), when
  /// that changed.
  void setAppActivity(AppActivity activity) {
    if (activity == _activity) return;
    _activity = activity;
    _notePause(activity);
    _send(SetAppActivity(activity));
  }

  /// Keeps when the background began and, on return, the pause it was
  /// for the open servers the engine had sampling. Only the engine's
  /// phase says a server was read: a subscription alone samples nothing
  /// while the link is down.
  void _notePause(AppActivity activity) {
    final now = _clock.value;
    switch (activity) {
      case AppActivity.background:
        _backgroundSince = now;
        // A server the fleet no longer lists has no phase: its readings
        // were purged, and its SamplingStates are dropped.
        _pausedServers = {
          for (final MapEntry(key: id, value: readings) in _readings.entries)
            if (readings.sampling.value?.state.phase == SamplingPhase.sampling)
              id,
        };
        _backgroundPause.value = null;
      case AppActivity.foreground:
        final since = _backgroundSince;
        _backgroundSince = null;
        final shown = _pausedServers.where(_openViews.containsKey).toSet();
        if (since == null || shown.isEmpty) return;
        _backgroundPause.value = BackgroundPause(
          start: since,
          end: now,
          serverIds: shown,
        );
    }
  }

  /// The return banner tells of the screen open at the return only.
  void _forgetPause(String serverId) {
    final pause = _backgroundPause.value;
    if (pause == null || !pause.serverIds.contains(serverId)) return;
    final rest = pause.serverIds.difference({serverId});
    _backgroundPause.value = rest.isEmpty
        ? null
        : BackgroundPause(start: pause.start, end: pause.end, serverIds: rest);
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
      case HostResult(:final queryId):
        _hostQueries.remove(queryId)?.$2.complete(event);
      case RedactedLines(:final requestId, :final text):
        _redactions.remove(requestId)?.complete(text);
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
        if (_backgroundSince != null &&
            event.phase == SamplingPhase.pausedInBackground) {
          _pausedServers.add(serverId);
        }
      case Gap(:final serverId):
        // As for a sample: a server that left the fleet stays purged.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _server(serverId).gap(event);
      case UnitQueryResult(:final requestId):
        _unitQueries.remove(requestId)?.$2.complete(event);
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
    _engineStopped = true;
    for (final MapEntry(key: queryId, value: (serverId, answer))
        in _hostQueries.entries) {
      answer.complete(_noHostLink(serverId, queryId));
    }
    _hostQueries.clear();
    for (final MapEntry(key: requestId, value: (serverId, answer))
        in _unitQueries.entries) {
      answer.complete(_noUnitLink(serverId, requestId));
    }
    _unitQueries.clear();
    for (final answer in _redactions.values) {
      answer.complete(null);
    }
    _redactions.clear();
    for (final timer in _leaving.values) {
      timer.cancel();
    }
    _leaving.clear();
  }

  _ServerReadings _server(String serverId) =>
      _readings.putIfAbsent(serverId, _ServerReadings.new);

  @override
  void dispose() {
    unawaited(_events.cancel());
    logs.dispose();
    terminals.dispose();
    jobHistory.dispose();
    rollups.dispose();
    accounts.dispose();
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
    super.dispose();
  }
}

/// A [MonitoringController.refresh] waiting for a newer sample of each of
/// its streams, while the server samples, for at most [kRefreshWait].
final class _PendingRefresh {
  _PendingRefresh(
    this.serverId,
    this._readings,
    Set<SampleStream> streams,
    this._onDone,
  ) : _before = {
        for (final stream in streams) stream: _readings.box(stream).value?.seq,
      } {
    for (final stream in _before.keys) {
      _readings.box(stream).addListener(_check);
    }
    _readings.sampling.addListener(_check);
    _timer = Timer(kRefreshWait, finish);
  }

  final String serverId;
  final _ServerReadings _readings;

  /// Each stream's latest seq when the refresh went out.
  final Map<SampleStream, int?> _before;
  final void Function(_PendingRefresh refresh) _onDone;
  final Completer<void> _done = Completer();
  late final Timer _timer;

  Future<void> get done => _done.future;

  void _check() {
    final sampling =
        _readings.sampling.value?.state.phase == SamplingPhase.sampling;
    final read = _before.entries.every((entry) {
      final seq = _readings.box(entry.key).value?.seq;
      return seq != null && seq > (entry.value ?? -1);
    });
    if (!sampling || read) finish();
  }

  /// Stops waiting; once only.
  void finish() {
    if (_done.isCompleted) return;
    _timer.cancel();
    for (final stream in _before.keys) {
      _readings.box(stream).removeListener(_check);
    }
    _readings.sampling.removeListener(_check);
    _onDone(this);
    _done.complete();
  }
}

/// What opened a history gap: a [SamplingState] phase, or a [Gap] or
/// failed reading, which never relabels an open one.
enum _HistoryGapSource { phase, reading }

/// [MonitoringController.clock]: one timer for every age on screen.
final class _FreshnessClock extends ChangeNotifier
    implements ValueListenable<DateTime> {
  _FreshnessClock(this._now);

  final DateTime Function() _now;
  Timer? _timer;

  @override
  DateTime get value => _now();

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(kFreshnessTick, (_) {
      notifyListeners();
      // A listener removed during the notification still counted then.
      if (!hasListeners) _stop();
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _stop();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}

/// One server's readings: its seq floor, latest sample and latest reading
/// per stream, rings and probe profile.
final class _ServerReadings {
  /// The highest [Sample.seq] kept: the engine counts one sequence per
  /// server across its streams (D44).
  int? _lastSeq;

  final Map<SampleStream, ValueNotifier<Sample?>> _boxes = {};
  final Map<SampleStream, ValueNotifier<Sample?>> _lastReadings = {};
  final Map<SampleStream, Map<MetricSeries, SeriesRing>> _rings = {};
  final ValueNotifier<HostProfile?> profile = ValueNotifier(null);
  final ValueNotifier<ServerClock?> clock = ValueNotifier(null);

  /// Ring streams no subscription names, and those named again since,
  /// whose next reading follows a hole.
  final Set<SampleStream> _unnamed = {};
  final Set<SampleStream> _afterHole = {};

  /// The engine's latest [SamplingState] for the server, with the phase
  /// before it.
  final ValueNotifier<SamplingStatus?> sampling = ValueNotifier(null);

  /// The `core` stream's series on a time axis, made on first use: rows
  /// read every fleet server's boxes, and only open servers sample `core`.
  Map<MetricSeries, TimeSeriesRing>? _history;
  Map<MetricSeries, TimeSeriesRing> get history => _history ??= {
    for (final series in MetricSeries.values)
      series: TimeSeriesRing(capacity: kSessionRingCapacity, lanes: 1),
  };
  Iterable<TimeSeriesRing> get _historyRings => _history?.values ?? const [];

  /// Opens a gap at [at] in every history ring that has a reading, as
  /// the engine gives a stream without one no gap. From the phase, a
  /// background pause or a lost link outranks a lost reading (03 §10.1),
  /// and a change between them starts a band of its own; a [Gap] or a
  /// failed reading opens one only where none is open, since the open
  /// one already says why readings stopped.
  void _openHistoryGap(
    DateTime at,
    ChartGapReason reason,
    _HistoryGapSource source,
  ) {
    if (_unnamed.contains(SampleStream.core)) return;
    for (final ring in _historyRings) {
      final last = ring.gaps.lastOrNull;
      final open = last != null && last.end == null;
      if (ring.length == 0) continue;
      if (open && source == _HistoryGapSource.reading) continue;
      ring.openGap(at, reason);
    }
  }

  /// The background pause, and a link lost while sampling, stop readings
  /// as the phase changes; a return with the link down ends the
  /// background's gap, as the app is in the foreground from then on.
  void phaseChanged(SamplingStatus status) {
    final reason = switch (status.state.phase) {
      SamplingPhase.pausedInBackground => ChartGapReason.background,
      SamplingPhase.waitingForLink
          when status.previous == SamplingPhase.sampling ||
              status.previous == SamplingPhase.pausedInBackground =>
        ChartGapReason.disconnected,
      _ => null,
    };
    if (reason == null) return;
    _openHistoryGap(status.state.since, reason, _HistoryGapSource.phase);
  }

  /// [gap] precedes the readings that resume its streams: none joins the
  /// reading before it.
  void gap(Gap gap) {
    for (final stream in gap.streams.where(_ringStreams.contains)) {
      _afterHole.add(stream);
    }
    if (gap.streams.contains(SampleStream.core)) {
      _openHistoryGap(
        gap.from,
        chartGapReasonOf(gap.cause),
        _HistoryGapSource.reading,
      );
    }
  }

  void unnamed(SampleStream stream, DateTime now) {
    _unnamed.add(stream);
    if (stream != SampleStream.core) return;
    for (final ring in _historyRings) {
      if (ring.length > 0) ring.add(now, const [null]);
    }
  }

  void named(SampleStream stream) {
    if (_unnamed.remove(stream)) _afterHole.add(stream);
  }

  ValueNotifier<Sample?> box(SampleStream stream) =>
      _boxes.putIfAbsent(stream, () => ValueNotifier<Sample?>(null));

  ValueNotifier<Sample?> lastReading(SampleStream stream) =>
      _lastReadings.putIfAbsent(stream, () => ValueNotifier<Sample?>(null));

  /// Every series of [stream] at once, so they stay aligned sample for
  /// sample.
  Map<MetricSeries, SeriesRing> rings(SampleStream stream) =>
      _rings.putIfAbsent(
        stream,
        () => {
          for (final series in MetricSeries.values)
            series: SeriesRing(kSessionRingCapacity),
        },
      );

  /// Keeps [sample] unless its seq is not above the floor.
  void accept(Sample sample) {
    final last = _lastSeq;
    if (last != null && sample.seq <= last) return;
    _lastSeq = sample.seq;

    // Rings first: a surface that hears the box may read them too.
    if (_ringStreams.contains(sample.stream)) {
      // Marked as the next reading arrives rather than when the stream is
      // named again: a reading still in flight then belongs before it.
      final hole = _afterHole.remove(sample.stream);
      for (final MapEntry(key: series, value: ring) in rings(
        sample.stream,
      ).entries) {
        if (hole && ring.length > 0) ring.add(null);
        ring.add(series.readFrom(sample.result));
      }
    }
    if (sample.stream == SampleStream.core) _record(sample);
    if (sample.result is! CollectorUnavailable) {
      lastReading(sample.stream).value = sample;
    }
    box(sample.stream).value = sample;
  }

  /// Adds [sample] to the history rings; a failed reading opens a gap.
  void _record(Sample sample) {
    if (sample.result is CollectorUnavailable) {
      _openHistoryGap(
        sample.at,
        ChartGapReason.readingFailed,
        _HistoryGapSource.reading,
      );
      return;
    }
    for (final MapEntry(key: series, value: ring) in history.entries) {
      ring.add(sample.at, [series.readFrom(sample.result)]);
    }
  }

  void dispose() {
    sampling.dispose();
    for (final ring in _historyRings) {
      ring.dispose();
    }
    for (final box in [..._boxes.values, ..._lastReadings.values]) {
      box.dispose();
    }
    for (final ring in _rings.values.expand((rings) => rings.values)) {
      ring.dispose();
    }
    profile.dispose();
    clock.dispose();
  }
}
