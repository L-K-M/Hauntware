/// One container's log stream (03 §5.6, §7.12 CTX-01; M7, M9): an
/// [OpenLogStream] of a [ContainerLogSource], which the Docker router
/// runs over its server's endpoint on a connection of its own, with the
/// journal follow's ring and pace (LOG-02).
///
/// ```text
///   run ─▶ inspect: Config.Tty, HostConfig.LogConfig
///    ▲       ├─ gone ─▶ ended (missing)
///    │       └─ no readable logs ─▶ ended (logDriverUnreadable, driver)
///    │     GET /logs?tail=N&follow=1&timestamps=1, since the newest line
///    │       on a resume ─▶ frames by Config.Tty ─▶ joined lines
///    │       ─▶ ring ─▶ LogBatch, at most 20 a second
///    │       └─ ends (the container stopped), or its connection fails:
///    │          read again after 1 s, 2 s, ... 30 s, since the newest line
///    └──── pause (the endpoint dropped): connection closed, ring kept
///   end: connection closed, ring discarded ─▶ ended
/// ```
///
/// A window (no follow) reads its last lines once and ends.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:klabautermann_docker/klabautermann_docker.dart';

import '../engine/protocol.dart';
import '../logs/log_follower.dart'
    show
        kFollowLineMaxBytes,
        kFollowRingBytes,
        kFollowRingLines,
        kLogBatchInterval;
import '../logs/log_service.dart' show kLogWindowMax;

/// The drivers whose logs the API reads on every engine: Docker's own
/// files and journald, and Podman's `k8s-file`, which its compat layer
/// may also report as `json-file`.
const _readableDrivers = {'json-file', 'local', 'journald', 'k8s-file'};

/// The log option that turns Docker's dual-logging cache off for a
/// remote driver.
const _cacheDisabled = 'cache-disabled';

/// A container id, or a name as Docker allows them.
final _containerRef = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$');

const _retryBase = Duration(seconds: 1);
const _retryCap = Duration(seconds: 30);

/// [at] as the Engine API's `since=` and `until=` take it.
LogTimestamp? _timestamp(DateTime? at) {
  if (at == null) return null;
  final micros = at.microsecondsSinceEpoch;
  return LogTimestamp.fromUnix(
    micros ~/ Duration.microsecondsPerSecond,
    nanos: micros % Duration.microsecondsPerSecond * 1000,
  );
}

/// The name of [config]'s driver when it keeps no logs the API can read
/// (03 §7.12 CTX-01), or null when the API reads them or the driver is
/// not named, which the read then tries. Docker reads any driver but
/// `none` through its dual-logging cache unless the container turns that
/// off; Podman keeps no such cache. A cache turned off daemon-wide does
/// not show in inspect: the logs request then fails with 501, read as
/// the same reason.
String? unreadableLogDriver(LogConfig? config, {required bool podman}) {
  final driver = config?.type;
  if (driver == null || driver.isEmpty) return null;
  if (_readableDrivers.contains(driver)) return null;
  if (driver == 'none' || podman) return driver;
  return config!.config[_cacheDisabled] == 'true' ? driver : null;
}

/// The endpoint a [ContainerLogReader] reads over, as the router hands
/// it.
abstract interface class ContainerLogTarget {
  /// Whether Podman serves the endpoint (M13), which has no dual-logging
  /// cache.
  bool get podman;

  /// A client over a connection of its own. On a relay it holds a session
  /// channel, which the router counts as a follower's (M9).
  DockerClient openStream();
}

/// The read of one container log stream, owned by the Docker router in
/// the engine isolate: [run] once the endpoint is ready, [pause] when it
/// drops, [end] to close it.
final class ContainerLogReader {
  /// [onEnded] hears that the stream ended, after its [LogStreamEnded].
  /// [track] takes each connection close, which the router's close waits
  /// for. [elapsed] is a monotonic clock pacing the batches.
  ContainerLogReader({
    required this.streamId,
    required this._spec,
    required this._emit,
    required this._onEnded,
    required this._track,
    required this._elapsed,
    this._startTimer = Timer.new,
  });

  final String streamId;
  final LogStreamSpec _spec;
  final void Function(EngineEvent event) _emit;
  final void Function() _onEnded;
  final void Function(Future<void> closing) _track;
  final Duration Function() _elapsed;
  final Timer Function(Duration duration, void Function() callback) _startTimer;

  /// Lines received and not yet batched, oldest first, and their
  /// characters, held to the journal follow's bytes.
  final _ring = ListQueue<ContainerRecord>();
  int _ringChars = 0;

  /// Lines discarded since the last batch.
  int _dropped = 0;
  Duration? _lastBatch;
  Timer? _beat;

  /// The newest timestamp of a line received, where a resume continues.
  LogTimestamp? _newest;

  /// How many lines arrived since the stream opened.
  int _received = 0;

  /// Bumped on each stop, so a request under way when it came drops its
  /// answer.
  int _epoch = 0;

  /// The endpoint the read runs over; null while it is paused or ended.
  ContainerLogTarget? _target;
  DockerClient? _client;
  StreamSubscription<TimestampedLogLine>? _lines;
  Timer? _retry;
  int _retries = 0;

  /// The end the engine gave, sent once the ring is out.
  LogStreamEnded? _ending;
  bool _ended = false;

  String get _containerId => (_spec.source as ContainerLogSource).containerId;

  /// Whether a read of [spec] runs, rather than ending as invalid at
  /// once: a container reference Docker could name, no cursor, and a
  /// window within 1 (0 for a follow) and [kLogWindowMax].
  static bool accepts(LogStreamSpec spec) => switch (spec.source) {
    ContainerLogSource(:final containerId) =>
      _containerRef.hasMatch(containerId) &&
          spec.afterCursor == null &&
          spec.window >= (spec.follow ? 0 : 1) &&
          spec.window <= kLogWindowMax,
    _ => false,
  };

  /// Starts the read over [target] and returns how it continues the
  /// stream, for the router's [LogStreamRunning]: after the newest line
  /// received, or, when lines came without a timestamp, with only new
  /// ones ([LogContinuity.gap]).
  LogContinuity run(ContainerLogTarget target) {
    assert(_target == null && _ending == null && !_ended, 'not idle');
    _target = target;
    _retries = 0;
    final gap = _newest == null && _received > 0;
    unawaited(_open(target, _epoch));
    if (_ring.isNotEmpty || _dropped > 0) _schedule();
    return gap ? LogContinuity.gap : LogContinuity.complete;
  }

  /// Stops the read without an event, for an endpoint that dropped, and
  /// keeps the lines not yet batched for the next run, sending them now
  /// when the pace allows. Returns false, changing nothing, once the
  /// stream is ending: it ends as soon as its last batch goes.
  bool pause() {
    if (_ending != null || _ended) return false;
    _stop();
    _beat?.cancel();
    _beat = null;
    _flush();
    return true;
  }

  /// Ends the stream with [status] at once: the connection closes and
  /// lines not yet batched go. Does nothing once it ended.
  void end(LogStreamEnded status) {
    if (_ended) return;
    _stop();
    _finish(status);
  }

  // -- the read -------------------------------------------------------

  Future<void> _open(ContainerLogTarget target, int epoch) async {
    final client = _client = target.openStream();
    final since = _newest;
    final source = _spec.source as ContainerLogSource;
    String? driver;
    try {
      final inspect = (await client.inspectContainer(_containerId)).value;
      if (epoch != _epoch) return;
      final logConfig = inspect.hostConfig?.logConfig;
      driver = logConfig?.type;
      if (unreadableLogDriver(logConfig, podman: target.podman)
          case final name?) {
        return _endAfterRing(
          LogStreamEnded(LogStreamEndReason.logDriverUnreadable, detail: name),
        );
      }

      final response = await client.containerLogsRaw(
        _containerId,
        follow: _spec.follow,
        // Since a line, every later one; without one, the range or the
        // window, or only new lines once lines without a timestamp
        // arrived.
        tail: since != null || source.ranged
            ? null
            : _received > 0
            ? 0
            : _spec.window,
        since: since ?? _timestamp(source.since),
        until: _timestamp(source.until),
      );
      if (epoch != _epoch) {
        unawaited(response.body.listen(null).cancel());
        return;
      }
      // Docker 20.10 and Podman send no Content-Type (D01), so Config.Tty
      // decides where the header is missing.
      final framing = resolveLogFraming(
        negotiated: client.apiVersion,
        tty: inspect.tty,
        contentType: response.headers.value('Content-Type'),
      ).framing;
      var lines = joinTimestampedLogLines(
        framing == LogFraming.raw
            ? rawLogFrames(response.body)
            : demuxStdcopy(response.body),
        framing: framing,
        maxLineBytes: kFollowLineMaxBytes,
      );
      // `since` is inclusive (03 §5.6); Podman's was seen exclusive once,
      // which drops nothing here.
      if (since != null) lines = dropInclusiveSince(lines, since);
      _lines = lines.listen(
        (line) {
          if (epoch == _epoch) _line(line);
        },
        onError: (Object error) => _lost(epoch, error),
        onDone: () => _lost(epoch, null),
        cancelOnError: true,
      );
    } on DockerException catch (error) {
      if (epoch != _epoch) return;
      switch (error) {
        case DockerNotFoundException(:final daemonMessage):
          _endAfterRing(
            LogStreamEnded(LogStreamEndReason.missing, detail: daemonMessage),
          );
        // moby's ErrReadLogsNotSupported: a driver inspect could not tell.
        case DockerApiException(statusCode: 501):
          _endAfterRing(
            LogStreamEnded(
              LogStreamEndReason.logDriverUnreadable,
              detail: driver,
            ),
          );
        case DockerApiException(:final daemonMessage, :final statusCode):
          _endAfterRing(
            LogStreamEnded(
              LogStreamEndReason.failed,
              detail: daemonMessage ?? 'HTTP $statusCode',
            ),
          );
        default:
          _lost(epoch, error);
      }
    }
  }

  /// The response ended: a window is complete; a follow's container
  /// stopped or its connection failed, and it reads again after a
  /// backoff, since the newest line, over the same endpoint. A link or
  /// daemon that went also fails the router's pooled reads, which pause
  /// it.
  void _lost(int epoch, Object? error) {
    if (epoch != _epoch) return;
    _closeConnection();
    if (!_spec.follow) {
      return _endAfterRing(
        error == null
            ? LogStreamEnded(
                _received >= _spec.window
                    ? LogStreamEndReason.windowFilled
                    : LogStreamEndReason.oldestReached,
              )
            : LogStreamEnded(LogStreamEndReason.failed, detail: '$error'),
      );
    }

    final delay = _retryBase * math.pow(2, math.min(_retries, 5)).toInt();
    _retries++;
    _retry?.cancel();
    _retry = _startTimer(delay < _retryCap ? delay : _retryCap, () {
      _retry = null;
      if (_target case final target? when epoch == _epoch) {
        unawaited(_open(target, epoch));
      }
    });
  }

  void _stop() {
    _target = null;
    _epoch++;
    _retry?.cancel();
    _retry = null;
    _closeConnection();
  }

  void _closeConnection() {
    final lines = _lines;
    final client = _client;
    _lines = null;
    _client = null;
    _track(
      Future.wait([?lines?.cancel(), ?client?.close()])
          .then((_) {}, onError: (Object _) {}),
    );
  }

  // -- the ring and the pace ------------------------------------------

  void _line(TimestampedLogLine line) {
    _received++;
    _retries = 0;
    final at = line.timestamp;
    if (at != null && (_newest == null || at > _newest!)) _newest = at;

    final record = ContainerRecord(
      stream: line.stream == StdcopyKind.stdout
          ? ContainerLogStream.stdout
          : ContainerLogStream.stderr,
      at: at == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              at.seconds * Duration.microsecondsPerSecond + at.nanos ~/ 1000,
              isUtc: true,
            ),
      text: line.message,
    );
    _ring.add(record);
    _ringChars += record.text.length;
    while (_ring.length > kFollowRingLines || _ringChars > kFollowRingBytes) {
      _ringChars -= _ring.removeFirst().text.length;
      _dropped++;
    }
    _schedule();
  }

  /// Arms the beat for the next batch: at once after a quiet spell, else
  /// [kLogBatchInterval] after the last.
  void _schedule() {
    if (_beat != null || _ended) return;
    final last = _lastBatch;
    final wait = last == null
        ? Duration.zero
        : kLogBatchInterval - (_elapsed() - last);
    _beat = _startTimer(wait.isNegative ? Duration.zero : wait, _onBeat);
  }

  void _onBeat() {
    _beat = null;
    // A timer may fire a little early.
    if (!_flush()) return _schedule();
    if (_ending case final status?) _finish(status);
  }

  /// Sends what the ring holds as one [LogBatch], unless the last went
  /// less than [kLogBatchInterval] ago; true when it sent it or nothing
  /// was waiting.
  bool _flush() {
    if (_ring.isEmpty && _dropped == 0) return true;
    final now = _elapsed();
    final last = _lastBatch;
    if (last != null && now - last < kLogBatchInterval) return false;

    _emit(LogBatch(streamId: streamId, records: _ring, dropped: _dropped));
    _ring.clear();
    _ringChars = 0;
    _dropped = 0;
    _lastBatch = now;
    return true;
  }

  /// Ends the stream for [status] once the lines held went out as the
  /// pace allows.
  void _endAfterRing(LogStreamEnded status) {
    _stop();
    if (_ring.isEmpty && _dropped == 0) return _finish(status);
    _ending = status;
    _schedule();
  }

  void _finish(LogStreamEnded status) {
    _ended = true;
    _ending = null;
    _beat?.cancel();
    _beat = null;
    _ring.clear();
    _ringChars = 0;
    _emit(LogStreamState(streamId, status));
    _onEnded();
  }
}
