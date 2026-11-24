import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// What a read whose request the engine's port refused answers.
enum SendFailure {
  /// Only that read answers its no-link value; the others still wait.
  thisRead,

  /// The port is taken for a stopped engine: every waiting read answers,
  /// and later ones answer at once.
  engineStopped,
}

/// The bookkeeping one-shot engine reads share: each [read] sends its
/// request under its own request id and completes with the answer the
/// engine sends for that id, which [answerOf] picks out of the events.
/// A stopped engine, or one that stops before it answers, answers each
/// read's no-link value, as does a [RequestRejected] that names the
/// read's request and id: the engine refused that one read, and nothing
/// else will answer it. One per concern, for one engine run.
final class EngineReads<A> {
  EngineReads(
    this._engine,
    this._answerOf, {
    this.sendFailure = SendFailure.thisRead,
  }) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;

  /// The request id an event answers and its answer; null for any other
  /// event.
  final (String, A)? Function(EngineEvent event) _answerOf;

  /// What a refused send answers.
  final SendFailure sendFailure;
  late final StreamSubscription<EngineEvent> _events;
  // By request id: the request's class name, as the engine names it in a
  // rejection, the read's no-link value, and its answer.
  final Map<String, (String, A Function(), Completer<A>)> _pending = {};
  bool _engineStopped = false;

  /// Sends [request], which carries [requestId], and completes with the
  /// engine's answer, or with [noLink]'s when the engine is or goes away.
  Future<A> read(String requestId, EngineRequest request, A Function() noLink) {
    if (_engineStopped) return Future.value(noLink());
    final answer = Completer<A>();
    _pending[requestId] = ('${request.runtimeType}', noLink, answer);
    try {
      _engine.send(request);
    } on StateError {
      switch (sendFailure) {
        case SendFailure.thisRead:
          _pending.remove(requestId);
          return Future.value(noLink());
        case SendFailure.engineStopped:
          // A closed engine answers every waiting read, this one included.
          _onEngineDone();
      }
    }
    return answer.future;
  }

  void _onEvent(EngineEvent event) {
    if (_answerOf(event) case (final requestId, final answer)) {
      _pending.remove(requestId)?.$3.complete(answer);
      return;
    }
    if (event case RequestRejected(:final requestName, :final requestId?)) {
      // Ids are minted per concern, so the name tells this concern's read
      // from another's with the same id.
      if (_pending[requestId] case (
        final name,
        final noLink,
        final answer,
      ) when name == requestName) {
        _pending.remove(requestId);
        answer.complete(noLink());
      }
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final (_, noLink, answer) in _pending.values) {
      answer.complete(noLink());
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
