import 'dart:async';

import 'package:flutter/foundation.dart';

/// How often the monitoring clock ticks: 03 §9.5 item 4 words freshness
/// in seconds ("updated 4 s ago").
const Duration kFreshnessTick = Duration(seconds: 1);

/// The monitoring clock: one timer for every age on screen.
final class FreshnessClock extends ChangeNotifier
    implements ValueListenable<DateTime> {
  FreshnessClock(this._now);

  final DateTime Function() _now;
  Timer? _timer;

  @override
  DateTime get value => _now();

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(kFreshnessTick, (_) {
      notifyListeners();
      // A listener removed during the notification still counted then.
      if (!hasListeners) _stop();
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _stop();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}
