import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// What a [LogStreams] stream tells its owner, in engine order. Nothing
/// arrives after [LogStreamHandle.close], after a [LogStreamEnded] status,
/// or after [onLogRejected].
abstract interface class LogStreamListener {
  void onLogBatch(LogBatch batch);

  void onLogStatus(LogStreamStatus status);

  /// The engine refused the open outright ([RequestRejected]), or has
  /// stopped and will answer nothing.
  void onLogRejected();
}

/// One stream [LogStreams.open] opened.
final class LogStreamHandle {
  LogStreamHandle._(this._streams, this.id);

  final LogStreams _streams;

  /// The [OpenLogStream.streamId].
  final String id;

  /// Sends [CloseStream] unless the stream already ended or was refused.
  void close() => _streams._close(id);
}

/// The app's log streams for one engine run (03 §10.1): mints stream ids
/// never reused, sends [OpenLogStream] and [CloseStream], and hands each
/// stream's events to its listener, a Logs panel stream or a bounded
/// `LogRead`. Also follows each server's journal access from the probe
/// for LOG-04's notice.
///
/// A [RequestRejected] names no stream, so a rejection of [OpenLogStream]
/// goes to the oldest open with no event yet. That is sound only because
/// the engine handles requests in order and its log service must answer
/// each open it accepts with a [LogStreamState] before the next request
/// ([OpenLogStream]), so the first event of any stream also answers every
/// open before it. It also needs every [OpenLogStream] the app sends to
/// go through here: a second sender with its own queue would take each
/// rejection as its own as well.
final class LogStreams {
  LogStreams(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  int _count = 0;
  bool _stopped = false;

  final Map<String, LogStreamListener> _listeners = {};

  /// Ids sent with no event yet, oldest first; a closed one stays until
  /// answered, so its rejection is not taken for a later open's.
  final _unanswered = ListQueue<String>();

  final Map<String, ValueNotifier<bool?>> _journalLimited = {};

  /// The fleet's ids from the last [CatalogReplaced] seen, as in
  /// `MonitoringController`.
  Set<String>? _fleetIds;

  /// Whether only the user's own journal entries are visible on
  /// [serverId] ([AccessReport.journalLimited], LOG-04): null until the
  /// probe answers, or when the host has no journal.
  ValueListenable<bool?> journalLimitedFor(String serverId) =>
      _limited(serverId);

  ValueNotifier<bool?> _limited(String serverId) =>
      _journalLimited.putIfAbsent(serverId, () => ValueNotifier(null));

  LogStreamHandle open(LogStreamSpec spec, LogStreamListener listener) {
    final id = 'log-${_count++}';
    _listeners[id] = listener;
    if (_send(OpenLogStream(streamId: id, spec: spec))) {
      _unanswered.add(id);
    } else {
      scheduleMicrotask(() => _listeners.remove(id)?.onLogRejected());
    }
    return LogStreamHandle._(this, id);
  }

  void _close(String id) {
    if (_listeners.remove(id) == null) return;
    _send(CloseStream(id));
  }

  /// Sends [request]; false when the engine has stopped.
  bool _send(EngineRequest request) {
    if (_stopped) return false;
    try {
      _engine.send(request);
      return true;
    } on StateError {
      _stopped = true;
      return false;
    }
  }

  void _onEvent(EngineEvent event) {
    switch (event) {
      case LogBatch(:final streamId):
        _answered(streamId);
        _listeners[streamId]?.onLogBatch(event);
      case LogStreamState(:final streamId, :final status):
        _answered(streamId);
        final listener = status is LogStreamEnded
            ? _listeners.remove(streamId)
            : _listeners[streamId];
        listener?.onLogStatus(status);
      case RequestRejected(:final requestName)
          when requestName == '$OpenLogStream' && _unanswered.isNotEmpty:
        _listeners.remove(_unanswered.removeFirst())?.onLogRejected();
      case HostProfileChanged(:final serverId, :final profile):
        if (_fleetIds case final ids? when !ids.contains(serverId)) return;
        _limited(serverId).value = evaluateAccess(profile).journalLimited;
      case CatalogReplaced(:final entries):
        // SYN-08: a server leaving the fleet takes its access with it.
        final ids = _fleetIds = {for (final entry in entries) entry.serverId};
        _journalLimited.removeWhere((serverId, limited) {
          if (ids.contains(serverId)) return false;
          limited.dispose();
          return true;
        });
      case EngineEvent():
        break;
    }
  }

  /// A stopped engine answers nothing more, so every stream still open
  /// is refused, as `FleetController` ends a pending import.
  void _onEngineDone() {
    _stopped = true;
    _unanswered.clear();
    final listeners = [..._listeners.values];
    _listeners.clear();
    for (final listener in listeners) {
      listener.onLogRejected();
    }
  }

  /// [id]'s first event answers it and every open sent before it.
  void _answered(String id) {
    if (!_unanswered.contains(id)) return;
    while (_unanswered.removeFirst() != id) {}
  }

  void dispose() {
    unawaited(_events.cancel());
    _stopped = true;
    _listeners.clear();
    for (final limited in _journalLimited.values) {
      limited.dispose();
    }
  }
}
