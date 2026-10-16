/// A stand-in engine that replays the committed host fixtures, for the
/// app's frame-timing test (spike S5 part 2, 03 §11.4). It answers the
/// protocol from the real frame reader, sample pipeline and journal
/// parser, with no SSH: the app spawns it through
/// `IsolateEngineClient.spawn`'s entry point, so its events reach the UI
/// through the production client and isolate hop (D18).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:klabautermann_host/klabautermann_host.dart';

import '../engine/engine_isolate.dart' show EngineStart;
import '../engine/protocol.dart';
import '../logs/log_service.dart' show LogService;
import '../logs/log_stream_router.dart' show kLogStreamsPerServerMax;
import '../sampling/sample_pipeline.dart';
import '../sampling/sample_results.dart' show sampleStreamCollector;
import '../sampling/sampler_session.dart' show SamplerReplied;
import '../sampling/sampling_scheduler.dart' show samplingPeriod;
import 'fixture_replay.dart';
import 'host_fixtures.dart';

/// What a replay engine serves: [hosts] fleet servers, server `i` from
/// `fixtures[i % fixtures.length]`, each reading [monitored] from the
/// start, and follows of [logLinesPerSecond] cycling [journalRows].
final class ReplayPlan {
  const ReplayPlan({
    required this.fixtures,
    required this.journalRows,
    this.hosts = 10,
    this.monitored = const {SampleStream.core},
    this.logLinesPerSecond = 1000,
  }) : assert(hosts > 0 && logLinesPerSecond > 0);

  final List<HostFixture> fixtures;
  final List<String> journalRows;
  final int hosts;

  /// What every server reads whether or not a view subscribed it. The
  /// default is 04 §13 S5's load, `core` every 2 s on each server:
  /// heavier than FL-21's monitor set, whose fleet rows read `overview`
  /// (03 §6.4).
  final Set<SampleStream> monitored;

  final int logLinesPerSecond;
}

/// The entry point of a replay engine over [plan], for
/// `IsolateEngineClient.spawn`. It closes over [plan] alone, so it can be
/// sent to the new isolate; a closure written where it also captures a
/// client or a future cannot. The engine:
///
/// - [Hello] gets [EngineReady], the fleet in a [CatalogReplaced], each
///   server's [LinkState] (ready) and [Reachability] (online), and its
///   probe's [HostProfileChanged]. No link exists: [Connect] and
///   [Disconnect] change nothing for a fleet server.
/// - Each server samples the union of [ReplayPlan.monitored] and its
///   subscriptions, as `Sample`s and `SamplingState`s from its pipeline.
///   A stream read for the first time reads at once, except the
///   monitored ones at start, whose first reads spread over their period
///   as servers that connected at different moments would. Each then
///   reads at the cadence profile's period (03 §6.4), `identity` once;
///   the replies are the platform's fixtures with the fast counters
///   advanced to the read's time.
/// - [OpenLogStream] is rejected as `LogStreamRouter` rejects it (03
///   §7.6): a reused id, a server outside the fleet, or a server holding
///   [kLogStreamsPerServerMax] streams. Unlike the router, which rejects
///   follows until K26, it serves them: a journal or kernel follow runs
///   at [ReplayPlan.logLinesPerSecond] until closed, in [LogBatch]es at
///   most 20 a second (03 §10.1). A window 03 §8.8 refuses ends as
///   invalid at once; any other window gets the newest journal rows it
///   holds once, newest first, and ends filled, or at the oldest when it
///   holds them all; a file ends as [LogStreamEndReason.missing].
/// - [Shutdown] stops its timer and exits; every other request gets
///   [RequestRejected].
///
/// The support directory it is started with is ignored: the replay keeps
/// no files.
void Function(EngineStart start) replayEngine(ReplayPlan plan) =>
    (start) => _ReplayEngine(start.uiPort, plan).listen();

/// How often the replay looks for due reads and feeds its follows.
const _step = Duration(milliseconds: 10);

final class _ReplayEngine {
  _ReplayEngine(this._ui, this._plan);

  final SendPort _ui;
  final ReplayPlan _plan;
  final _commands = ReceivePort('klabautermann replay engine');
  final _clock = Stopwatch();
  final _sequence = SampleSequence();
  final Map<String, _Host> _hosts = {};

  /// The open follows, by stream id.
  final Map<String, _Follow> _follows = {};

  /// Every id an open named, so a reuse is rejected (03 §10.1).
  final Set<String> _usedIds = {};
  late final _journal = JournalFeed(_plan.journalRows, _plan.logLinesPerSecond);
  Timer? _timer;
  var _profile = CadenceProfile.desktop;
  var _activity = AppActivity.foreground;

  void listen() {
    _ui.send(_commands.sendPort);
    _commands.listen(_handle);
  }

  void _send(EngineEvent event) => _ui.send(event);

  void _reject(String request, String reason) =>
      _send(RequestRejected(request, reason));

  void _handle(Object? message) {
    switch (message) {
      case Hello(:final protocolVersion):
        if (protocolVersion != kEngineProtocolVersion) {
          _reject('Hello', 'protocol $protocolVersion');
          return;
        }
        _start();
      case Subscribe(:final serverId, :final subscriptionId, :final streams):
        final host = _hosts[serverId];
        if (host == null) return;
        host.subscriptions[subscriptionId] = streams;
        _update(host);
      case Unsubscribe(:final serverId, :final subscriptionId):
        final host = _hosts[serverId];
        if (host?.subscriptions.remove(subscriptionId) == null) return;
        _update(host!);
      case SetCadenceProfile(:final profile):
        _profile = profile;
      case SetAppActivity(:final activity):
        _activity = activity;
        _hosts.values.forEach(_update);
      case Connect(:final serverId) || Disconnect(:final serverId):
        if (!_hosts.containsKey(serverId)) {
          _reject('${message.runtimeType}', 'no fleet server $serverId');
        }
      case OpenLogStream():
        if (_open(message) case final reason?) _reject('OpenLogStream', reason);
      case CloseStream(:final streamId):
        final follow = _follows.remove(streamId);
        if (follow == null) return;
        follow.host.follows.remove(streamId);
        _send(
          LogStreamState(
            streamId,
            const LogStreamEnded(LogStreamEndReason.closed),
          ),
        );
      case Shutdown():
        _timer?.cancel();
        _commands.close();
        Isolate.exit();
      case EngineRequest():
        _reject(
          '${message.runtimeType}',
          'the replay engine does not serve it',
        );
      default:
        _reject('<unknown>', 'isolate message was not an EngineRequest');
    }
  }

  void _start() {
    if (_timer != null) return;

    _clock.start();
    for (var i = 0; i < _plan.hosts; i++) {
      final host = _Host(
        i,
        _plan.fixtures[i % _plan.fixtures.length],
        _sequence,
      );
      _hosts[host.id] = host;
      for (final stream in _plan.monitored) {
        final period = samplingPeriod(stream, _profile) ?? Duration.zero;
        host.due[stream] = period * i ~/ _plan.hosts;
      }
    }
    _send(const EngineReady(kEngineProtocolVersion));
    _send(CatalogReplaced([for (final host in _hosts.values) host.entry]));
    for (final host in _hosts.values) {
      _send(LinkState(host.id, const LinkReady()));
      _send(Reachability(host.id, ReachabilityStatus.online));
      // The probe runs on a session of its own after a connect (03 §6.1).
      final probe = HwsTickAssembler(nonce: replayNonce)..push(readyFrame());
      final tick = probe.push(replyFrame(1, null, host.fixture.probe)).single;
      host.pipeline.addProbe(SamplerReplied(tick as HwsTick)).forEach(_send);
      _update(host);
    }
    _timer = Timer.periodic(_step, (_) => _tick());
  }

  /// Takes [host]'s streams from [ReplayPlan.monitored] and its
  /// subscriptions; a new one reads at once.
  void _update(_Host host) {
    final streams = {
      ..._plan.monitored,
      for (final streams in host.subscriptions.values) ...streams,
    };
    final now = _clock.elapsed;
    host.due.removeWhere((stream, _) => !streams.contains(stream));
    for (final stream in streams.difference(host.readOnce)) {
      host.due.putIfAbsent(stream, () => now);
    }
    host.pipeline
        .updateConditions(
          streams: streams,
          linkReady: true,
          activity: _activity,
          at: DateTime.now().toUtc(),
        )
        .forEach(_send);
  }

  void _tick() {
    final now = _clock.elapsed;
    final at = DateTime.now().toUtc();
    for (final host in _hosts.values) {
      _read(host, now, at);
    }
    for (final follow in _follows.values) {
      final due =
          _plan.logLinesPerSecond *
          (now - follow.start).inMicroseconds ~/
          Duration.microsecondsPerSecond;
      if (due > follow.fed) {
        _journal.feed(follow.replay, due - follow.fed);
        follow.fed = due;
      }
      if (follow.replay.flush(now - follow.start) case final batch?) {
        _send(batch);
      }
    }
  }

  /// One reply for [host]'s streams due by [now], through its pipeline.
  void _read(_Host host, Duration now, DateTime at) {
    final due = {
      for (final MapEntry(key: stream, value: time) in host.due.entries)
        if (time <= now) stream,
    };
    if (due.isEmpty) return;

    for (final stream in due) {
      final period = samplingPeriod(stream, _profile);
      if (period == null) {
        host.due.remove(stream);
        host.readOnce.add(stream);
        continue;
      }
      host.due[stream] = nextGridRead(host.due[stream]!, period, now);
    }

    final collectors = {
      for (final stream in due) sampleStreamCollector(stream),
    };
    // `core` reads every counter `overview` does, so its section serves
    // both, as the pipeline reads it.
    if (collectors.contains(Collector.core)) {
      collectors.remove(Collector.overview);
    }
    final seconds = now.inMicroseconds / 1e6;
    final reply = replyFrame(++host.seq, host.uptime + seconds, [
      for (final collector in collectors)
        _section(host.fixture, collector, seconds),
    ]);
    final tick = host.assembler.push(reply).single as HwsTick;
    host.pipeline.addTick(due, SamplerReplied(tick), at).forEach(_send);
  }

  ReplaySection _section(HostFixture fixture, Collector collector, double t) {
    final payload = fixture.payloads[collector.wireName];
    if (payload == null) {
      return (
        name: collector.wireName,
        status: SectionStatus.missing,
        payload: '',
      );
    }
    return (
      name: collector.wireName,
      status: SectionStatus.ok,
      payload: collector.sampler == SamplerKind.fast
          ? advanceCounters(payload, t)
          : payload,
    );
  }

  /// Opens [request]'s stream and returns null, having sent its first
  /// [LogStreamState], or returns why the engine rejects it.
  String? _open(OpenLogStream request) {
    final OpenLogStream(:streamId, :spec) = request;
    if (!_usedIds.add(streamId)) return 'stream id $streamId was used before';
    final host = _hosts[spec.serverId];
    if (host == null) return 'no fleet server ${spec.serverId}';
    if (host.follows.length >= kLogStreamsPerServerMax) {
      return '${host.id} holds $kLogStreamsPerServerMax log streams';
    }

    void state(LogStreamStatus status) =>
        _send(LogStreamState(streamId, status));
    if (!spec.follow && !LogService.accepts(spec)) {
      state(const LogStreamEnded(LogStreamEndReason.invalid));
      return null;
    }
    if (spec.source is FileLogSource) {
      state(const LogStreamEnded(LogStreamEndReason.missing));
      return null;
    }
    state(const LogStreamRunning());
    if (spec.follow) {
      final follow = _Follow(
        host,
        FollowReplay(streamId: streamId, maxPending: _plan.logLinesPerSecond),
        start: _clock.elapsed,
      );
      _follows[streamId] = host.follows[streamId] = follow;
      return null;
    }

    final rows = _plan.journalRows.reversed.take(spec.window).join('\n');
    final window = FollowReplay(
      streamId: streamId,
      maxPending: math.max(1, spec.window),
    )..add(utf8.encode('$rows\n'));
    if (window.flush(Duration.zero) case final batch?) _send(batch);
    state(
      LogStreamEnded(
        spec.window < _plan.journalRows.length
            ? LogStreamEndReason.windowFilled
            : LogStreamEndReason.oldestReached,
      ),
    );
    return null;
  }
}

/// One replayed server: its fleet entry, fixture, fast reader, pipeline,
/// subscriptions and when each stream reads next.
final class _Host {
  _Host(int index, this.fixture, SampleSequence sequence)
    : entry = FleetEntry(
        serverId: 'replay-$index',
        label: '${fixture.platform}-$index',
        // RFC 6761: an .invalid name never resolves, should one be dialed.
        host: '${fixture.platform}-$index.invalid',
        port: kSshDefaultPort,
        origin: FleetEntryOrigin.sshConfig,
        searchText: '${fixture.platform}-$index',
      ),
      uptime = fixtureUptime(fixture.core) ?? 1000,
      pipeline = ServerSamplePipeline(
        serverId: 'replay-$index',
        sequence: sequence,
      );

  final FleetEntry entry;
  final HostFixture fixture;
  final double uptime;
  final ServerSamplePipeline pipeline;
  final assembler = HwsTickAssembler(nonce: replayNonce)..push(readyFrame());
  final Map<String, Set<SampleStream>> subscriptions = {};
  final Map<SampleStream, Duration> due = {};

  /// The server's open follows, by stream id; a window ends as it opens.
  final Map<String, _Follow> follows = {};

  /// Streams read once per link (`identity`) that have read.
  final Set<SampleStream> readOnce = {};
  int seq = 0;

  String get id => entry.serverId;
}

/// One open follow, its server and how many lines it has been fed.
final class _Follow {
  _Follow(this.host, this.replay, {required this.start});

  final _Host host;
  final FollowReplay replay;
  final Duration start;
  int fed = 0;
}
