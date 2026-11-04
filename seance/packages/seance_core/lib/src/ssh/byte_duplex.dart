import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'sequential_cleanup.dart';

/// Full-duplex byte transport around one SSH forwarding channel.
///
/// [stream] may be listened to at any time: bytes that arrive before the
/// listener attaches are buffered and replayed, and buffer growth past the
/// bound pauses the channel so the remote window stops granting the peer
/// credit — backpressure, not loss. Writes never wait on the read side.
abstract interface class ByteDuplex {
  /// Inbound bytes. Single-subscription; safe to listen to after data has
  /// already arrived.
  Stream<List<int>> get stream;

  /// Outbound bytes; [StreamSink.close] sends channel EOF without closing the
  /// read side.
  StreamSink<List<int>> get sink;

  /// Completes when the channel is closed in both directions.
  Future<void> get done;

  /// Sends channel EOF and closes the channel, bounded to the close timeout.
  Future<void> close();
}

/// Maximum bytes retained for one late or paused inbound stream.
const inboundReplayBufferLimit = 4 * 1024 * 1024;

/// dartssh2 channel wrapped as a [ByteDuplex]. Not barrel-exported: the
/// public surface stays free of dartssh2 types.
final class ChannelByteDuplex implements ByteDuplex {
  ChannelByteDuplex(this._socket, {void Function()? onData})
    : _inbound = InboundReplay(
        _socket.stream,
        maxBufferedBytes: inboundReplayBufferLimit,
        onData: onData,
      );

  final SSHSocket _socket;
  final InboundReplay _inbound;
  final _cleanup = SingleFlightCleanup();

  @override
  Stream<List<int>> get stream => _inbound.stream;

  @override
  StreamSink<List<int>> get sink => _socket.sink;

  @override
  Future<void> get done => _socket.done;

  /// EOF and close, bounded like the link's other channel closes. `destroy`
  /// runs last so a peer that never answers the close still frees the handle
  /// once the bound expires.
  @override
  Future<void> close() => _cleanup.run(
    () => runSequentialCleanup(
      [
        _inbound.cancel,
        _socket.close,
        () {
          _socket.destroy();
        },
      ],
      actionTimeout: _closeBound,
      failureMode: CleanupFailureMode.ignore,
    ),
  );
}

/// Per-action bound shared by duplex and process close paths; the link passes
/// its own close timeout to [runSequentialCleanup] when it drives teardown.
const _closeBound = Duration(seconds: 5);

/// Replays a subscribed-at-creation channel stream for a consumer that may
/// listen late, pause, or cancel. Not barrel-exported; shared by
/// [ChannelByteDuplex] and the exec-channel wrapper in `remote_process.dart`.
///
/// The source subscription is taken immediately, so no wire bytes are lost
/// between channel open and the consumer's `listen`. Buffered bytes are
/// bounded by [maxBufferedBytes]. [InboundReplayOverflow.backpressure] pauses
/// the source at the bound, which is exactly what dartssh2 checks before
/// granting window credit. [InboundReplayOverflow.discardOldest] keeps
/// draining instead and retains only the newest bytes. Cancelling a consumer
/// follows the selected policy while the owning channel stays open.
final class InboundReplay {
  InboundReplay(
    Stream<List<int>> source, {
    required this.maxBufferedBytes,
    this.overflow = InboundReplayOverflow.backpressure,
    this.onData,
  }) {
    if (maxBufferedBytes <= 0) {
      throw ArgumentError.value(
        maxBufferedBytes,
        'maxBufferedBytes',
        'Must be positive.',
      );
    }
    _subscription = source.listen(
      _receive,
      onError: _receiveError,
      onDone: _receiveDone,
    );
  }

  /// Maximum bytes retained while the consumer is absent or paused.
  final int maxBufferedBytes;

  /// What happens when buffered input reaches [maxBufferedBytes].
  final InboundReplayOverflow overflow;

  /// Liveness probe wired to the owning link's inbound-byte watch.
  final void Function()? onData;

  late final StreamSubscription<List<int>> _subscription;

  final _pending = Queue<List<int>>();
  var _pendingBytes = 0;
  var _upstreamDone = false;
  var _upstreamPaused = false;
  Object? _error;
  StackTrace? _stackTrace;

  late final StreamController<List<int>> _controller =
      StreamController<List<int>>(
        onListen: _pump,
        onPause: _pauseUpstream,
        onResume: _pump,
        onCancel: _pauseUpstream,
      );

  Stream<List<int>> get stream => _controller.stream;

  /// Stops pulling the source and ends the consumer's stream once the bytes
  /// already buffered are delivered. Used by close paths that already sent
  /// the channel close and no longer need its bytes.
  Future<void> cancel() async {
    await _subscription.cancel();
    _upstreamDone = true;
    _pump();
  }

  void _receive(List<int> data) {
    onData?.call();
    if (_controller.isClosed) return;
    _pending.addLast(data);
    _pendingBytes += data.length;
    _discardOldestOverflow();
    _pauseUpstreamIfFull();
    _pump();
  }

  void _discardOldestOverflow() {
    if (overflow != InboundReplayOverflow.discardOldest ||
        _pendingBytes <= maxBufferedBytes) {
      return;
    }

    var bytesToDiscard = _pendingBytes - maxBufferedBytes;
    while (bytesToDiscard > 0) {
      final first = _pending.removeFirst();
      if (first.length <= bytesToDiscard) {
        _pendingBytes -= first.length;
        bytesToDiscard -= first.length;
        continue;
      }

      // Copy the retained tail so a small slice cannot keep a large source
      // buffer alive.
      final tail = Uint8List(first.length - bytesToDiscard)
        ..setRange(0, first.length - bytesToDiscard, first, bytesToDiscard);
      _pending.addFirst(tail);
      _pendingBytes -= bytesToDiscard;
      bytesToDiscard = 0;
    }
  }

  void _receiveError(Object error, StackTrace stackTrace) {
    _error ??= error;
    _stackTrace ??= stackTrace;
    _pump();
  }

  void _receiveDone() {
    _upstreamDone = true;
    _pump();
  }

  void _pump() {
    if (!_controller.hasListener || _controller.isPaused) return;
    while (_pending.isNotEmpty) {
      _pendingBytes -= _pending.first.length;
      _controller.add(_pending.removeFirst());
    }
    _resumeUpstreamIfDrained();
    if (_pending.isEmpty && !_controller.isClosed) {
      final error = _error;
      if (error != null) {
        final stackTrace = _stackTrace ?? StackTrace.empty;
        _error = null;
        _stackTrace = null;
        _controller.addError(error, stackTrace);
      }
      if (_upstreamDone) unawaited(_controller.close());
    }
  }

  void _pauseUpstreamIfFull() {
    if (_upstreamPaused ||
        overflow != InboundReplayOverflow.backpressure ||
        _pendingBytes < maxBufferedBytes) {
      return;
    }
    _upstreamPaused = true;
    _subscription.pause();
  }

  void _resumeUpstreamIfDrained() {
    // Resume once the backlog is well under the limit, so a consumer
    // dribbling reads does not flap the channel window every event.
    if (!_upstreamPaused ||
        overflow != InboundReplayOverflow.backpressure ||
        _pendingBytes > maxBufferedBytes ~/ 2) {
      return;
    }
    _upstreamPaused = false;
    _subscription.resume();
  }

  void _pauseUpstream() {
    // Discard-oldest mode keeps draining while the consumer is absent or
    // paused so an unread diagnostic stream cannot stall its process.
    if (_upstreamPaused || overflow == InboundReplayOverflow.discardOldest) {
      return;
    }
    _upstreamPaused = true;
    _subscription.pause();
  }
}

/// How [InboundReplay] enforces its byte bound.
enum InboundReplayOverflow {
  /// Pause the source until the consumer drains enough buffered bytes.
  backpressure,

  /// Keep draining and discard the oldest buffered bytes first.
  discardOldest,
}
