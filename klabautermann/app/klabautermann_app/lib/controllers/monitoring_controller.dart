import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// The monitoring concern (03 §10.1): sampler subscriptions and the
/// per-server `ValueListenable` that keeps sample updates local to the
/// surfaces painting them (a whole-app `notifyListeners` would rebuild the
/// shell on every 1 to 5 s tick, which §10.1 forbids).
final class MonitoringController extends ChangeNotifier {
  MonitoringController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  final Map<String, ValueNotifier<OverviewSnapshot?>> _samples = {};
  final Map<String, int> _lastSeq = {};

  /// The live snapshot holder for [serverId], created on first use. A
  /// surface listens to this one box instead of the whole controller.
  ValueListenable<OverviewSnapshot?> snapshotFor(String serverId) {
    return _samples.putIfAbsent(
      serverId,
      () => ValueNotifier<OverviewSnapshot?>(null),
    );
  }

  /// Which servers this controller asked the engine to sample (the
  /// monitor-set bookkeeping lives in the engine; this mirrors what the
  /// UI sent for its own view).
  final Set<String> _subscribed = {};

  bool isSubscribed(String serverId) => _subscribed.contains(serverId);

  /// Starts the engine's sampler tick for [serverId] (03 §10.1).
  void subscribe(String serverId, Set<Collector> collectors, Duration cadence) {
    _subscribed.add(serverId);
    _engine.send(
      Subscribe(serverId: serverId, collectors: collectors, cadence: cadence),
    );
  }

  void unsubscribe(String serverId) {
    if (!_subscribed.remove(serverId)) return;
    _engine.send(Unsubscribe(serverId));
  }

  void _onEngineEvent(EngineEvent event) {
    if (event is! Sample) return;
    final last = _lastSeq[event.serverId];
    if (last != null && event.seq <= last) return;
    _lastSeq[event.serverId] = event.seq;
    _samples
            .putIfAbsent(
              event.serverId,
              () => ValueNotifier<OverviewSnapshot?>(null),
            )
            .value =
        event.snapshot;
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    for (final notifier in _samples.values) {
      notifier.dispose();
    }
    super.dispose();
  }
}
