import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_health.dart';

/// The most restarts in [_restartWindow]: an engine that keeps stopping
/// is left stopped, and the user told to quit, rather than restarted in
/// a loop.
const int _restartBudget = 3;
const Duration _restartWindow = Duration(minutes: 10);

/// One engine run with what the app built over it (D44: controllers last
/// one run, since every run counts its seq from 1).
abstract interface class EngineRun {
  IsolateEngineClient get engine;

  /// Ends what was built over [engine], once the widgets that used it
  /// are gone.
  void dispose();
}

/// Restarts the engine when it stops without being asked to (owner
/// decision 3 of the 2026-11 review, CTL-14): spawns a new one, builds a
/// new run over it, swaps [current] so the app remounts its tree on the
/// new controllers, and disposes the old run after that frame. [health]
/// hears each stop and how its restart went, which the app tells the
/// user.
final class EngineRestarter<R extends EngineRun> {
  EngineRestarter({
    required R first,
    required this._spawn,
    required this._build,
    required this._health,
    required this._quitting,
    @visibleForTesting Future<void> Function()? settled,
    @visibleForTesting this._now = DateTime.now,
  }) : _settled = settled ?? _endOfFrame,
       current = ValueNotifier(first) {
    _follow(first);
  }

  final Future<IsolateEngineClient> Function() _spawn;
  final R Function(IsolateEngineClient engine) _build;
  final EngineHealth _health;
  final bool Function() _quitting;
  final Future<void> Function() _settled;
  final DateTime Function() _now;
  final List<DateTime> _restarts = [];
  bool _disposed = false;

  /// The run the app shows.
  final ValueNotifier<R> current;

  static Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame;

  void _follow(R run) {
    _health.follow(run.engine);
    unawaited(run.engine.exited.then((exit) => _stopped(run, exit)));
  }

  Future<void> _stopped(R run, EngineExit exit) async {
    if (_disposed || _quitting() || !identical(run, current.value)) return;
    debugPrint('The engine stopped: ${exit.error}\n${exit.stack ?? ''}');

    final now = _now();
    _restarts.removeWhere((at) => now.difference(at) >= _restartWindow);
    if (_restarts.length >= _restartBudget) {
      _health.reportStopped(EngineStopped(error: exit.error));
      return;
    }
    _restarts.add(now);
    _health.reportStopped(
      EngineStopped(error: exit.error, recovery: EngineRecovery.restarting),
    );

    final IsolateEngineClient engine;
    try {
      engine = await _spawn();
    } on Object catch (error) {
      debugPrint('The engine did not restart: $error');
      _health.reportStopped(EngineStopped(error: exit.error));
      return;
    }
    if (_disposed || _quitting()) {
      unawaited(engine.shutdown());
      return;
    }

    // Built in this turn, with no await before it: the controllers all
    // hear the new engine's startup events (CTL-01).
    final next = _build(engine);
    current.value = next;
    _follow(next);
    _health.reportStopped(
      EngineStopped(error: exit.error, recovery: EngineRecovery.restarted),
    );

    // The swap's frame unmounts the widgets over the old controllers.
    await _settled();
    run.dispose();
  }

  void dispose() {
    _disposed = true;
    current.dispose();
  }
}
