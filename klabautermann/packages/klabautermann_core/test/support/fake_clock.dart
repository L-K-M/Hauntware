// A clock whose timers fire only when the test lets time pass, for the
// sampling scheduler's cadence tests.
import 'dart:async';

import 'package:test/test.dart';

final class FakeClock {
  static final start = DateTime.utc(2026, 10, 15, 12);

  DateTime now = start;
  final List<_FakeTimer> _timers = [];

  /// Time since [start], as a monotonic clock reads it.
  Duration get elapsed => now.difference(start);

  Timer startTimer(Duration duration, void Function() callback) {
    final timer = _FakeTimer(now.add(duration), callback);
    _timers.add(timer);
    return timer;
  }

  /// Lets [duration] pass, firing due timers in order (the first started
  /// among equals, as real timers fire) and letting the event queue run
  /// after each.
  Future<void> elapse(Duration duration) async {
    final end = now.add(duration);
    while (true) {
      await pumpEventQueue();
      _timers.removeWhere((t) => !t.isActive);
      final due = _timers.where((t) => !t.due.isAfter(end));
      if (due.isEmpty) break;
      final next = due.reduce((a, b) => b.due.isBefore(a.due) ? b : a);
      now = next.due;
      next.fire();
    }
    now = end;
    await pumpEventQueue();
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.due, this._callback);

  final DateTime due;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
