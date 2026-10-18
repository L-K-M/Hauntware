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
import '../links/channel_quota.dart';
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
///   probe's [HostProfileChanged], never a cached one (D59): its
///   `cachedAt` is null. No link exists: [Connect] changes nothing for a
///   fleet server, and [Disconnect] only ends the server's log streams
///   as failed, as the engine's router does before the link closes.
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
///   holds them all; a file ends as [LogStreamEndReason.missing]. A
///   server runs as many follows at once as [ChannelShare.follower]
///   allows (03 §5.2); a further one waits for a channel until one ends,
///   as the router queues it.
/// - [SetAppActivity] with the background pauses every follow without an
///   event, reports each stream as waiting for the foreground, and a
///   stream opened then waits too; the foreground runs them again from
///   their start, the paused ones first, as the router does (03 §6.4).
/// - [Shutdown] ends every log stream as failed, stops its timer and
///   exits; every other request gets [RequestRejected], save a
///   [Disconnect] of a server outside the fleet, which the engine ignores
///   too.
///
/// The support directory it is started with, and the access to it, are
/// ignored: the replay keeps no files, a capability cache included.
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

  /// The open log streams, waiting or following, by id.
  final Map<String, _Stream> _streams = {};

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
        if (activity == _activity) return;
        _activity = activity;
        for (final host in _hosts.values) {
          _update(host);
          if (activity == AppActivity.background) _pause(host);
          _pump(host);
        }
      case Connect(:final serverId):
        if (!_hosts.containsKey(serverId)) {
          _reject('Connect', 'no fleet server $serverId');
        }
      case Disconnect(:final serverId):
        if (_hosts[serverId] case final host?) _endAll(host);
      case OpenLogStream():
        if (_open(message) case final reason?) _reject('OpenLogStream', reason);
      case CloseStream(:final streamId):
        if (_streams[streamId] case final stream?) {
          _end(stream, LogStreamEndReason.closed);
        }
      case Shutdown():
        // Each stream's end goes out before the isolate does.
        _hosts.values.forEach(_endAll);
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
    for (final host in _hosts.values) {
      for (final follow in host.following.values) {
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
    if (host.logStreams >= kLogStreamsPerServerMax) {
      return '${host.id} holds $kLogStreamsPerServerMax log streams';
    }

    // Refused before it waits for anything, as the router refuses it.
    if (!spec.follow && !LogService.accepts(spec)) {
      _send(
        LogStreamState(
          streamId,
          const LogStreamEnded(LogStreamEndReason.invalid),
        ),
      );
      return null;
    }
    final stream = _Stream(streamId, spec, host);
    _streams[streamId] = stream;
    host.waiting.add(stream);
    _pump(host);
    return null;
  }

  /// Runs [host]'s waiting streams, oldest first, or tells each why it
  /// still waits, as `LogStreamRouter` does. The replay's links are
  /// always ready, so the background and the follower share hold a
  /// stream back.
  void _pump(_Host host) {
    for (final stream in host.waiting.toList()) {
      if (_activity == AppActivity.background) {
        _wait(stream, LogStreamWaitReason.background);
        continue;
      }
      if (stream.holdsChannel && !host.quota.take(ChannelShare.follower)) {
        _wait(stream, LogStreamWaitReason.channel);
        continue;
      }
      host.waiting.remove(stream);
      stream.waitingFor = null;
      _run(stream);
    }
  }

  /// Runs [stream] from its start: a follow until it ends or pauses, a
  /// window or file at once.
  void _run(_Stream stream) {
    final _Stream(id: streamId, :spec, :host) = stream;
    // A replay holds no files and no Docker engine.
    if (spec.source is FileLogSource || spec.source is ContainerLogSource) {
      _end(stream, LogStreamEndReason.missing);
      return;
    }
    _send(LogStreamState(streamId, const LogStreamRunning()));
    if (spec.follow) {
      host.following[streamId] = _Follow(
        stream,
        FollowReplay(streamId: streamId, maxPending: _plan.logLinesPerSecond),
        start: _clock.elapsed,
      );
      return;
    }

    final rows = _plan.journalRows.reversed.take(spec.window).join('\n');
    final window = FollowReplay(
      streamId: streamId,
      maxPending: math.max(1, spec.window),
    )..add(utf8.encode('$rows\n'));
    if (window.flush(Duration.zero) case final batch?) _send(batch);
    _end(
      stream,
      spec.window < _plan.journalRows.length
          ? LogStreamEndReason.windowFilled
          : LogStreamEndReason.oldestReached,
    );
  }

  /// Stops [host]'s follows without an event and queues them ahead of
  /// its waiting streams, in the order they started, as the router
  /// pauses its reads; records they had not sent go with them.
  void _pause(_Host host) {
    final paused = [for (final follow in host.following.values) follow.stream];
    host.following.clear();
    for (final _ in paused) {
      host.quota.give(ChannelShare.follower);
    }
    host.waiting.insertAll(0, paused);
  }

  /// Sends [stream]'s [LogStreamWaiting] for [reason], once per reason.
  void _wait(_Stream stream, LogStreamWaitReason reason) {
    if (stream.waitingFor == reason) return;
    stream.waitingFor = reason;
    _send(LogStreamState(stream.id, LogStreamWaiting(reason)));
  }

  /// Ends [stream] for [reason], waiting or running; a follow's end
  /// frees its slot for the next.
  void _end(_Stream stream, LogStreamEndReason reason) {
    final host = stream.host;
    _streams.remove(stream.id);
    host.waiting.remove(stream);
    final freed = host.following.remove(stream.id) != null;
    _send(LogStreamState(stream.id, LogStreamEnded(reason)));
    if (!freed) return;

    host.quota.give(ChannelShare.follower);
    _pump(host);
  }

  /// Ends every stream of [host] as failed, as `LogStreamRouter` does on
  /// [Disconnect] and [Shutdown]: nothing would bring a link back for
  /// them.
  void _endAll(_Host host) {
    // The waiting ones first, so that no follow's end runs them.
    final streams = [
      ...host.waiting,
      for (final follow in host.following.values) follow.stream,
    ];
    for (final stream in streams) {
      _end(stream, LogStreamEndReason.failed);
    }
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

  /// The server's log streams that wait, oldest first.
  final List<_Stream> waiting = [];

  /// The follower slots its running follows hold.
  final quota = ChannelQuota();

  /// The server's running follows by stream id, in the order they
  /// started; a window ends as it runs.
  final Map<String, _Follow> following = {};

  /// Streams read once per link (`identity`) that have read.
  final Set<SampleStream> readOnce = {};
  int seq = 0;

  String get id => entry.serverId;

  int get logStreams => waiting.length + following.length;
}

/// One open log stream.
final class _Stream {
  _Stream(this.id, this.spec, this.host);

  final String id;
  final LogStreamSpec spec;
  final _Host host;

  /// What the last [LogStreamWaiting] sent named; null while it runs or
  /// before any.
  LogStreamWaitReason? waitingFor;

  /// Whether it holds a follower slot while it runs: a journal or kernel
  /// follow does; a window or a file ends as it runs.
  bool get holdsChannel => spec.follow && spec.source is! FileLogSource;
}

/// One running follow, from when it started, and how many lines it has
/// been fed.
final class _Follow {
  _Follow(this.stream, this.replay, {required this.start});

  final _Stream stream;
  final FollowReplay replay;
  final Duration start;
  int fed = 0;
}
