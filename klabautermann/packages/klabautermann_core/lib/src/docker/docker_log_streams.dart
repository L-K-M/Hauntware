part of 'docker_router.dart';

/// Accepts [request], an open of a container's logs, and returns null,
/// having sent the stream's first [LogStreamState], or returns why the
/// engine rejects it: a server outside the fleet, or one holding
/// [kLogStreamsPerServerMax] container log streams, a count of their
/// own beside the log router's host streams. The log router
/// refuses a reused id first. A new stream looks for a failed endpoint
/// again, as a watch does.
String? _openLogs(DockerRouter router, OpenLogStream request) {
  final OpenLogStream(:streamId, :spec) = request;
  final serverId = spec.serverId;
  if (!router._fleet.contains(serverId)) return 'no fleet server $serverId';
  if ((router._sessions[serverId]?.logs.length ?? 0) >=
      kLogStreamsPerServerMax) {
    return '$serverId holds $kLogStreamsPerServerMax container log streams';
  }
  if (!ContainerLogReader.accepts(spec)) {
    router._emit(
      LogStreamState(
        streamId,
        const LogStreamEnded(LogStreamEndReason.invalid),
      ),
    );
    return null;
  }

  final session = router._session(serverId);
  late final _LogStream stream;
  stream = _LogStream(
    spec,
    ContainerLogReader(
      streamId: streamId,
      spec: spec,
      emit: router._emit,
      onEnded: () => _logEnded(router, session, streamId, stream),
      track: router._track,
      elapsed: router._elapsed,
      startTimer: router._startTimer,
    ),
  );
  session.logs[streamId] = stream;
  router._logOwners[streamId] = session;
  session.failed = false;
  router._pump(session);
  return null;
}

/// One container log stream as the session runs it.
final class _LogStream {
  _LogStream(this.spec, this.reader);

  final LogStreamSpec spec;
  final ContainerLogReader reader;
  bool running = false;

  /// The relay slot it holds while running; null on streamlocal.
  ChannelShare? slot;

  /// The last status the router sent; null before any.
  LogStreamStatus? status;

  ChannelShare get share =>
      spec.follow ? ChannelShare.follower : ChannelShare.shortAction;
}

/// Runs [session]'s waiting log streams over its ready endpoint, in the
/// order they opened, or tells each why it waits. On a relay each takes
/// a slot of its share from the quota the log router's reads take
/// from (M9); streamlocal costs no session.
void _serveLogs(DockerRouter router, _Session session) {
  final endpoint = session.endpoint;
  for (final stream in session.logs.values.toList()) {
    if (stream.running) continue;
    if (endpoint == null) {
      _logStatus(
        router,
        stream,
        const LogStreamWaiting(LogStreamWaitReason.link),
      );
      continue;
    }
    if (endpoint.route.rank != DockerRank.streamlocal) {
      if (!session.quota.take(
        stream.share,
        learnedSessionLimit: session.link?.seen.learnedSessionLimit,
      )) {
        _logStatus(
          router,
          stream,
          const LogStreamWaiting(LogStreamWaitReason.channel),
        );
        continue;
      }
      stream.slot = stream.share;
    }
    stream.running = true;
    _logStatus(
      router,
      stream,
      LogStreamRunning(continuity: stream.reader.run(endpoint)),
    );
  }
}

/// Stops [session]'s running follows, which resume over the next
/// endpoint; a window ends as failed, as one on a lost link does.
void _pauseLogs(DockerRouter router, _Session session) {
  for (final stream in session.logs.values.toList()) {
    if (!stream.running) continue;
    if (!stream.spec.follow) {
      stream.reader.end(const LogStreamEnded(LogStreamEndReason.failed));
    } else if (stream.reader.pause()) {
      _release(session, stream);
    }
  }
}

void _endLogs(_Session session, LogStreamEnded status) {
  for (final stream in session.logs.values.toList()) {
    stream.reader.end(status);
  }
}

/// Forgets [stream], which sent its end, and runs what its slot lets.
void _logEnded(
  DockerRouter router,
  _Session session,
  String streamId,
  _LogStream stream,
) {
  session.logs.remove(streamId);
  router._logOwners.remove(streamId);
  _release(session, stream);
  if (identical(router._sessions[session.serverId], session)) {
    _serveLogs(router, session);
  }
}

void _release(_Session session, _LogStream stream) {
  stream.running = false;
  if (stream.slot case final share?) session.quota.give(share);
  stream.slot = null;
}

/// Sends [status] for [stream] unless it was the last one sent.
void _logStatus(
  DockerRouter router,
  _LogStream stream,
  LogStreamStatus status,
) {
  if (stream.status == status) return;
  stream.status = status;
  router._emit(LogStreamState(stream.reader.streamId, status));
}
