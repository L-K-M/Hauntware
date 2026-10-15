import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../ui/charts/series_ring.dart';

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
  /// once. [now] is what [clock] reads.
  MonitoringController(
    this._engine, {
    this._linkGrace = kLinkLeaveGrace,
    DateTime Function() now = DateTime.now,
  }) : _clock = _FreshnessClock(now) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  final Duration _linkGrace;
  final _FreshnessClock _clock;
  late final StreamSubscription<EngineEvent> _events;

  final Map<String, _ServerReadings> _readings = {};

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

  /// What the probe last found on [serverId] ([HostProfileChanged]), or
  /// null before its first answer this engine run: SYS-01's
  /// virtualization and the container facts behind D50's unknowns.
  ValueListenable<HostProfile?> profileFor(String serverId) =>
      _server(serverId).profile;

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
        _readings[serverId]?.unnamed(stream);
      }
    });
  }

  /// A view of [serverId] opened (the desktop workspace, the phone's pushed
  /// screen). The first sends [Connect]; within the grace after the last
  /// leave the link is still held and nothing is sent.
  ///
  /// An engine with links off, as the app spawns it until they are ready,
  /// answers [Connect] with [RequestRejected], which this controller
  /// ignores like every event it does not consume: the views stay as they
  /// are and show no error.
  void openServer(String serverId) {
    final views = _openViews[serverId] ?? 0;
    _openViews[serverId] = views + 1;
    if (views > 0) return;

    final leaving = _leaving.remove(serverId);
    if (leaving != null) {
      leaving.cancel();
      return;
    }
    if (_listed(serverId)) _send(Connect(serverId));
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
    _send(SetAppActivity(activity));
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
      case Sample(:final serverId):
        // One still in flight when its server left the fleet would bring
        // back what the purge dropped.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _server(serverId).accept(event);
      case HostProfileChanged(:final serverId, :final profile):
        // As for a sample: a server that left the fleet stays purged.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _server(serverId).profile.value = profile;
      case CatalogReplaced(:final entries):
        _replaceFleet({for (final entry in entries) entry.serverId});
      case SamplingState(:final serverId):
        // As for a sample: a server that left the fleet stays purged.
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        final box = _server(serverId).sampling;
        box.value = SamplingStatus(event, previous: box.value?.state.phase);
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
      if (_openViews.containsKey(serverId)) _send(Connect(serverId));
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
    _onEngineDone();
    for (final readings in _readings.values) {
      readings.dispose();
    }
    _clock.dispose();
    super.dispose();
  }
}

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

  /// Ring streams no subscription names, and those named again since,
  /// whose next reading follows a hole.
  final Set<SampleStream> _unnamed = {};
  final Set<SampleStream> _afterHole = {};

  /// The engine's latest [SamplingState] for the server, with the phase
  /// before it.
  final ValueNotifier<SamplingStatus?> sampling = ValueNotifier(null);

  void unnamed(SampleStream stream) => _unnamed.add(stream);

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
    if (sample.result is! CollectorUnavailable) {
      lastReading(sample.stream).value = sample;
    }
    box(sample.stream).value = sample;
  }

  void dispose() {
    sampling.dispose();
    for (final box in [..._boxes.values, ..._lastReadings.values]) {
      box.dispose();
    }
    for (final ring in _rings.values.expand((rings) => rings.values)) {
      ring.dispose();
    }
    profile.dispose();
  }
}
