import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// The monitoring concern (03 §10.1): this app's sampling subscriptions
/// and a `ValueListenable` per server and stream that keeps sample updates
/// local to the surfaces painting them (a whole-app `notifyListeners`
/// would rebuild the shell on every 1 to 5 s tick, which §10.1 forbids).
final class MonitoringController extends ChangeNotifier {
  MonitoringController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  final Map<(String, SampleStream), ValueNotifier<Sample?>> _samples = {};

  /// The highest [Sample.seq] kept per server: the engine counts one
  /// sequence per server across its streams (D44).
  final Map<String, int> _lastSeq = {};

  /// The `(serverId, subscriptionId)` pairs this controller asked the
  /// engine to sample (D45).
  final Set<(String, String)> _subscribed = {};

  /// The latest sample of [serverId]'s [stream], created on first use. A
  /// surface listens to this one box instead of the whole controller.
  ValueListenable<Sample?> sampleFor(String serverId, SampleStream stream) =>
      _box(serverId, stream);

  bool isSubscribed(String serverId, String subscriptionId) =>
      _subscribed.contains((serverId, subscriptionId));

  /// Asks the engine to sample [streams] of [serverId] for the surface
  /// [subscriptionId] (03 §10.1, D45). Each surface holds its own id, so
  /// unsubscribing one leaves the streams of the others running;
  /// subscribing an id again replaces its streams.
  void subscribe(
    String serverId,
    String subscriptionId,
    Set<SampleStream> streams,
  ) {
    assert(streams.isNotEmpty, 'unsubscribe instead of naming no stream');
    _subscribed.add((serverId, subscriptionId));
    _engine.send(
      Subscribe(
        serverId: serverId,
        subscriptionId: subscriptionId,
        streams: Set.unmodifiable(streams),
      ),
    );
  }

  void unsubscribe(String serverId, String subscriptionId) {
    if (!_subscribed.remove((serverId, subscriptionId))) return;
    _engine.send(
      Unsubscribe(serverId: serverId, subscriptionId: subscriptionId),
    );
  }

  void _onEngineEvent(EngineEvent event) {
    if (event is! Sample) return;
    final last = _lastSeq[event.serverId];
    if (last != null && event.seq <= last) return;
    _lastSeq[event.serverId] = event.seq;
    _box(event.serverId, event.stream).value = event;
  }

  ValueNotifier<Sample?> _box(String serverId, SampleStream stream) => _samples
      .putIfAbsent((serverId, stream), () => ValueNotifier<Sample?>(null));

  @override
  void dispose() {
    unawaited(_events.cancel());
    for (final notifier in _samples.values) {
      notifier.dispose();
    }
    super.dispose();
  }
}
