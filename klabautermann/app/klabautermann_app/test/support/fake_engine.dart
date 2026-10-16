import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// The widget tests' [EngineClient]: records every request the app sends and
/// lets a test push events back (03 §10.1's "narrow delegate seams per
/// surface so widget tests need no full app"). No isolate, no transport.
final class FakeEngineClient implements EngineClient {
  FakeEngineClient() {
    _events = StreamController<EngineEvent>.broadcast(
      onListen: () {
        final waiting = _held;
        _held = null;
        waiting?.forEach(_events.add);
      },
    );
  }

  final List<EngineRequest> sent = [];
  late final StreamController<EngineEvent> _events;

  /// Events emitted before anything listened, held for the first listener
  /// as [EngineClient.events] promises; null once someone has listened.
  List<EngineEvent>? _held = [];
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
  void emit(EngineEvent event) {
    if (_held case final waiting?) {
      waiting.add(event);
    } else {
      _events.add(event);
    }
  }

  /// The requests of one runtime type, in order.
  List<EngineRequest> sentOfType<T extends EngineRequest>() =>
      sent.whereType<T>().toList();

  /// Closes [events], as an engine that stops does. Closing again does
  /// nothing: a test that stopped the engine inside `testWidgets` leaves
  /// its done future in the test's fake zone, which a second close from
  /// the harness's teardown would await forever.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _events.close();
  }
}
