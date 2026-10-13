import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// The widget tests' [EngineClient]: records every request the app sends and
/// lets a test push events back (03 §10.1's "narrow delegate seams per
/// surface so widget tests need no full app"). No isolate, no transport.
final class FakeEngineClient implements EngineClient {
  final List<EngineRequest> sent = [];
  final StreamController<EngineEvent> _events =
      StreamController<EngineEvent>.broadcast();
  bool _closed = false;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  void send(EngineRequest request) {
    if (_closed) {
      throw StateError('the engine client is shut down');
    }
    sent.add(request);
  }

  @override
  Future<void> shutdown() => close();

  /// Pushes [event] to every listener, as the engine isolate would.
  void emit(EngineEvent event) => _events.add(event);

  /// The requests of one runtime type, in order.
  List<EngineRequest> sentOfType<T extends EngineRequest>() =>
      sent.whereType<T>().toList();

  Future<void> close() async {
    _closed = true;
    await _events.close();
  }
}
