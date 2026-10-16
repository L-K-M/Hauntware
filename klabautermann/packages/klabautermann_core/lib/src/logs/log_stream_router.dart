/// The engine's log streams (03 §5.2, §7.6, §10.1): every [OpenLogStream]
/// and [CloseStream] the engine accepts, routed to a [LogService] on its
/// server's link once the link is ready, the app is in the foreground and
/// the read's channel share has room.
///
/// The router answers each open before it returns, with the read's
/// [LogStreamRunning] from the service or a [LogStreamWaiting] that says
/// what it waits for, and every stream ends exactly once:
///
/// ```text
///   open ─▶ waiting (link, channel, background) ─▶ running ─▶ ended
///              ▲                                      │
///              └──── background: paused, process closed
///   running, its link lost or replaced ─▶ ended (failed)
///   Disconnect, fleet removal, close() ─▶ ended (failed)
///   CloseStream ─▶ ended (closed)
/// ```
library;

import 'dart:async';

import 'package:seance_core/seance_core.dart' show SshLink, quoteShellWord;

import '../engine/protocol.dart';
import '../links/channel_quota.dart';
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

/// Owned by the engine isolate, which hands it the log requests and tells
/// it what changed: [update] after a server's [LinkState], [activity],
/// [disconnect], [retain] for the fleet and [close].
final class LogStreamRouter {
  /// [linkFor] gives a server's ready link, null while it has none.
  LogStreamRouter({
    required this._linkFor,
    required this._emit,
    this._openService = _defaultService,
  });

  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;
  final LogServiceOpener _openService;

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
  /// a follow (K26), a server outside the fleet, or a server already
  /// holding [kLogStreamsPerServerMax] streams.
  String? open(OpenLogStream request) {
    final OpenLogStream(:streamId, :spec) = request;
    final serverId = spec.serverId;
    if (!_usedIds.add(streamId)) return 'stream id $streamId was used before';
    if (spec.follow) return 'following a log is not implemented yet';
    if (!_fleet.contains(serverId)) return 'no fleet server $serverId';
    if ((_servers[serverId]?.count ?? 0) >= kLogStreamsPerServerMax) {
      return '$serverId holds $kLogStreamsPerServerMax log streams';
    }

    // Refused before it waits for anything, as the service would refuse
    // it on opening.
    if (!LogService.accepts(spec)) {
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

  /// Follows [serverId]'s link: a read running on a link that went ends
  /// as failed, and waiting reads start once one is ready.
  void update(String serverId) {
    final server = _servers[serverId];
    if (server != null) _pump(server);
  }

  /// Follows the app's visibility (03 §6.4): the background pauses every
  /// read, closing the processes of those running, and the foreground
  /// starts them again from their start.
  set activity(AppActivity activity) {
    if (activity == _activity) return;
    _activity = activity;
    for (final server in _servers.values.toList()) {
      if (activity == AppActivity.background) _pause(server);
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
  /// drops the server's entry once it holds no stream.
  void _pump(_Server server) {
    final link = _linkFor(server.id);
    if (!identical(link, server.link)) {
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
      stream.waitingFor = null;
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
    final closing = service.close();
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));
  }

  /// Stops [server]'s running reads without an event and queues them
  /// ahead of the others, in the order they started.
  void _pause(_Server server) {
    final paused = server.running.values.toList();
    for (final stream in paused) {
      server.running.remove(stream.id);
      server.quota.give(stream.share);
      server.service!.pause(stream.id);
    }
    server.waiting.insertAll(0, paused);
  }

  void _endAll(_Server server) {
    _closeService(server);
    for (final stream in server.waiting) {
      _endWaiting(stream, LogStreamEndReason.failed);
    }
    server.waiting.clear();
  }

  // -- streams --------------------------------------------------------

  void _wait(_Stream stream, LogStreamWaitReason reason) {
    if (stream.waitingFor == reason) return;
    stream.waitingFor = reason;
    _emit(LogStreamState(stream.id, LogStreamWaiting(reason)));
  }

  /// Ends [stream], which waits and runs nothing, for [reason].
  void _endWaiting(_Stream stream, LogStreamEndReason reason) {
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

  /// Streams running on [service], in the order they started.
  final Map<String, _Stream> running = {};

  /// The link [service] reads over.
  SshLink? link;
  LogService? service;

  int get count => waiting.length + running.length;
}

final class _Stream {
  _Stream(this.id, this.spec, this.server);

  final String id;
  final LogStreamSpec spec;
  final _Server server;

  /// What the last [LogStreamWaiting] sent named; null while running or
  /// before any.
  LogStreamWaitReason? waitingFor;

  ChannelShare get share =>
      spec.follow ? ChannelShare.follower : ChannelShare.shortAction;
}
