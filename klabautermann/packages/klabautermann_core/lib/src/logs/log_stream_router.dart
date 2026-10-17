/// The engine's log streams (03 §5.2, §7.6, §10.1): every [OpenLogStream]
/// and [CloseStream] the engine accepts, a window routed to a [LogService]
/// and a follow to its [LogFollower] on its server's link once the link
/// is ready, the app is in the foreground and the read's channel share
/// has room.
///
/// The router answers each open before it returns, with the read's
/// [LogStreamRunning] or a [LogStreamWaiting] that says what it waits
/// for, and every stream ends exactly once:
///
/// ```text
///   open ─▶ waiting (link, channel, background) ─▶ running ─▶ ended
///              ▲                                      │
///              ├──── background: paused, process closed
///              └──── a follow's link lost or replaced: paused
///   a window's link lost or replaced ─▶ ended (failed)
///   Disconnect, fleet removal, close() ─▶ ended (failed)
///   CloseStream ─▶ ended (closed)
/// ```
library;

import 'dart:async';

import 'package:seance_core/seance_core.dart'
    show SshLink, SshLinkClosed, quoteShellWord;

import '../engine/protocol.dart';
import '../links/channel_quota.dart';
import 'log_follower.dart';
import 'log_service.dart';

/// The most streams one server holds open, waiting or running [E]: a
/// server view opens one for its Logs panel and one for a unit's page, so
/// this leaves room for views that close while their answers cross.
const kLogStreamsPerServerMax = 16;

/// Builds the [LogService] of one link; tests pass a fake clock.
typedef LogServiceOpener =
    LogService Function(SshLink link, void Function(EngineEvent) emit);

LogService _defaultService(SshLink link, void Function(EngineEvent) emit) =>
    LogService(link: link, quote: quoteShellWord, emit: emit);

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

/// Owned by the engine isolate, which hands it the log requests and tells
/// it what changed: [update] after a server's [LinkState], [activity],
/// [disconnect], [retain] for the fleet and [close].
final class LogStreamRouter {
  /// [linkFor] gives a server's ready link, null while it has none.
  /// [startTimer] and [elapsed], a monotonic clock, pace the follows'
  /// batches; tests pass a fake clock.
  LogStreamRouter({
    required this._linkFor,
    required this._emit,
    this._openService = _defaultService,
    this._startTimer = Timer.new,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _monotonicClock();

  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;
  final LogServiceOpener _openService;
  final Timer Function(Duration duration, void Function() callback) _startTimer;
  final Duration Function() _elapsed;

  /// Servers with a stream open; an entry goes with its last stream.
  final Map<String, _Server> _servers = {};
  final Map<String, _Stream> _streams = {};

  /// Every id an open named, so a reuse is refused (03 §10.1); one short
  /// string per open for the engine's lifetime.
  final Set<String> _usedIds = {};
  final Set<Future<void>> _closing = {};
  Set<String> _fleet = const {};
  AppActivity _activity = AppActivity.foreground;

  /// Accepts [request] and returns null, having sent the stream's first
  /// [LogStreamState], or returns why the engine rejects it: a reused id,
  /// a server outside the fleet, or a server already holding
  /// [kLogStreamsPerServerMax] streams.
  String? open(OpenLogStream request) {
    final OpenLogStream(:streamId, :spec) = request;
    final serverId = spec.serverId;
    if (!_usedIds.add(streamId)) return 'stream id $streamId was used before';
    if (!_fleet.contains(serverId)) return 'no fleet server $serverId';
    if ((_servers[serverId]?.count ?? 0) >= kLogStreamsPerServerMax) {
      return '$serverId holds $kLogStreamsPerServerMax log streams';
    }

    // Refused before it waits for anything, as the service would refuse
    // it on opening.
    if (!(spec.follow ? LogFollower.accepts(spec) : LogService.accepts(spec))) {
      _emit(
        LogStreamState(
          streamId,
          const LogStreamEnded(LogStreamEndReason.invalid),
        ),
      );
      return null;
    }

    final server = _servers.putIfAbsent(serverId, () => _Server(serverId));
    final stream = _Stream(streamId, spec, server);
    if (spec.follow) stream.follower = _follower(stream);
    _streams[streamId] = stream;
    server.waiting.add(stream);
    _pump(server);
    return null;
  }

  /// [CloseStream]: ends [streamId] as closed, stopping its read. Does
  /// nothing when the stream is not open.
  void closeStream(String streamId) {
    final stream = _streams[streamId];
    if (stream == null) return;
    // The follower sends the end, and _followerEnded follows it.
    if (stream.follower case final follower?) {
      return follower.end(const LogStreamEnded(LogStreamEndReason.closed));
    }

    final server = stream.server;
    if (server.running.containsKey(streamId)) {
      // The service sends the end, which _onServiceEvent follows.
      server.service!.closeStream(streamId);
      return;
    }
    server.waiting.remove(stream);
    _endWaiting(stream, LogStreamEndReason.closed);
    _pump(server);
  }

  /// Follows [serverId]'s link: a window running on a link that went ends
  /// as failed, a follow waits for the next link, and waiting reads start
  /// once one is ready.
  void update(String serverId) {
    final server = _servers[serverId];
    if (server != null) _pump(server);
  }

  /// Follows the app's visibility (03 §6.4): the background pauses every
  /// read, closing the processes of those running, and the foreground
  /// starts a window again from its start and resumes a follow.
  set activity(AppActivity activity) {
    if (activity == _activity) return;
    _activity = activity;
    for (final server in _servers.values.toList()) {
      if (activity == AppActivity.background) {
        _pause(server, server.running.values.toList());
      }
      _pump(server);
    }
  }

  /// Ends every stream of [serverId] as failed: the app let its link go,
  /// and nothing would bring one back for them.
  void disconnect(String serverId) {
    final server = _servers.remove(serverId);
    if (server != null) _endAll(server);
  }

  /// Takes [fleet] as the servers streams may open on, and ends every
  /// stream of a server outside it as failed (03 §5.1).
  void retain(Set<String> fleet) {
    _fleet = fleet;
    for (final serverId in _servers.keys.toList()) {
      if (!fleet.contains(serverId)) disconnect(serverId);
    }
  }

  /// Ends every stream as failed; completes once their processes have
  /// closed.
  Future<void> close() async {
    for (final serverId in _servers.keys.toList()) {
      disconnect(serverId);
    }
    while (_closing.isNotEmpty) {
      await Future.wait(_closing.toList());
    }
  }

  // -- servers --------------------------------------------------------

  /// Starts what [server] can run and tells each read left waiting why;
  /// drops the server's entry once it holds no stream. A closed link the
  /// supervisor has not reported yet counts as none, so a follow lost on
  /// it waits instead of starting there again.
  void _pump(_Server server) {
    var link = _linkFor(server.id);
    if (link?.state is SshLinkClosed) link = null;
    if (!identical(link, server.link)) {
      _pause(server, [
        for (final stream in server.running.values)
          if (stream.follower != null) stream,
      ]);
      _closeService(server);
      server.link = link;
    }
    final blocked = switch (link) {
      _ when _activity == AppActivity.background =>
        LogStreamWaitReason.background,
      null => LogStreamWaitReason.link,
      _ => null,
    };

    // A copy: an end the service sends while a read opens pumps again.
    for (final stream in server.waiting.toList()) {
      if (!server.waiting.contains(stream)) continue;
      if (blocked != null) {
        _wait(stream, blocked);
        continue;
      }
      final share = stream.share;
      if (!server.quota.take(
        share,
        learnedSessionLimit: link!.seen.learnedSessionLimit,
      )) {
        _wait(stream, LogStreamWaitReason.channel);
        continue;
      }

      server.waiting.remove(stream);
      server.running[stream.id] = stream;
      if (stream.follower case final follower?) {
        _status(stream, LogStreamRunning(continuity: follower.run(link)));
        continue;
      }
      // The service sends the window's states from here.
      stream.status = null;
      final service = server.service ??= _service(server, link);
      service.open(stream.id, stream.spec);
    }

    if (server.count == 0 && identical(_servers[server.id], server)) {
      _servers.remove(server.id);
      _closeService(server);
    }
  }

  LogService _service(_Server server, SshLink link) {
    late final LogService service;
    service = _openService(
      link,
      (event) => _onServiceEvent(server, service, event),
    );
    return service;
  }

  /// Passes [event] on; an end frees its read's slot for the next read.
  void _onServiceEvent(_Server server, LogService service, EngineEvent event) {
    _emit(event);
    if (event case LogStreamState(:final streamId, status: LogStreamEnded())) {
      final stream = server.running.remove(streamId);
      if (stream == null) return;
      _streams.remove(streamId);
      server.quota.give(stream.share);
      // A service closing sends its ends after it was let go.
      if (identical(server.service, service)) _pump(server);
    }
  }

  /// Closes [server]'s service, which ends each read it runs as failed.
  void _closeService(_Server server) {
    final service = server.service;
    if (service == null) return;

    server.service = null;
    server.link = null;
    _track(service.close());
  }

  /// Stops [streams], running on [server], without an event and queues
  /// them ahead of the others, in the order they started. A follow the
  /// host ended stays until its last batch goes.
  void _pause(_Server server, List<_Stream> streams) {
    final paused = <_Stream>[];
    for (final stream in streams) {
      if (stream.follower case final follower?) {
        if (!follower.pause()) continue;
      } else {
        server.service!.pause(stream.id);
      }
      server.running.remove(stream.id);
      server.quota.give(stream.share);
      paused.add(stream);
    }
    server.waiting.insertAll(0, paused);
  }

  void _endAll(_Server server) {
    _closeService(server);
    for (final stream in [...server.running.values, ...server.waiting]) {
      _endWaiting(stream, LogStreamEndReason.failed);
    }
    server.waiting.clear();
  }

  void _track(Future<void> closing) {
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));
  }

  // -- streams --------------------------------------------------------

  LogFollower _follower(_Stream stream) => LogFollower(
    streamId: stream.id,
    spec: stream.spec,
    emit: _emit,
    onLost: () => _followerLost(stream),
    onEnded: () => _followerEnded(stream),
    track: _track,
    elapsed: _elapsed,
    quote: quoteShellWord,
    startTimer: _startTimer,
  );

  /// Queues [stream], whose follow lost its process, ahead of the others
  /// and runs it again where it can.
  void _followerLost(_Stream stream) {
    final server = stream.server;
    if (server.running.remove(stream.id) == null) return;
    server.quota.give(stream.share);
    server.waiting.insert(0, stream);
    _pump(server);
  }

  /// Forgets [stream], whose follow sent its end, and frees its slot.
  void _followerEnded(_Stream stream) {
    _streams.remove(stream.id);
    final server = stream.server;
    if (server.running.remove(stream.id) != null) {
      server.quota.give(stream.share);
    }
    server.waiting.remove(stream);
    if (identical(_servers[server.id], server)) _pump(server);
  }

  void _wait(_Stream stream, LogStreamWaitReason reason) =>
      _status(stream, LogStreamWaiting(reason));

  /// Sends [status] for [stream] unless it was the last the router sent.
  void _status(_Stream stream, LogStreamStatus status) {
    if (stream.status == status) return;
    stream.status = status;
    _emit(LogStreamState(stream.id, status));
  }

  /// Ends [stream], which runs nothing on the service, for [reason]: a
  /// waiting window, or a follow, which ends itself.
  void _endWaiting(_Stream stream, LogStreamEndReason reason) {
    if (stream.follower case final follower?) {
      return follower.end(LogStreamEnded(reason));
    }
    _streams.remove(stream.id);
    _emit(LogStreamState(stream.id, LogStreamEnded(reason)));
  }
}

/// One server's open streams and the service on its current link.
final class _Server {
  _Server(this.id);

  final String id;
  final quota = ChannelQuota();

  /// Streams not running, oldest first.
  final List<_Stream> waiting = [];

  /// Streams running on [link], in the order they started.
  final Map<String, _Stream> running = {};

  /// The link [service] and the follows read over.
  SshLink? link;
  LogService? service;

  int get count => waiting.length + running.length;
}

final class _Stream {
  _Stream(this.id, this.spec, this.server);

  final String id;
  final LogStreamSpec spec;
  final _Server server;

  /// A follow's reader; null for a window.
  LogFollower? follower;

  /// The last status the router sent; null before any, and while the
  /// service runs a window and sends its states.
  LogStreamStatus? status;

  ChannelShare get share =>
      spec.follow ? ChannelShare.follower : ChannelShare.shortAction;
}
