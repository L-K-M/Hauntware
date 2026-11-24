import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// What the app did about an engine that stopped by itself.
enum EngineRecovery {
  /// A new engine is starting; nothing is told yet.
  restarting,

  /// A new engine runs, with new controllers over it.
  restarted,

  /// No new engine runs: one would not start, or engines kept stopping.
  gaveUp,
}

/// An engine that stopped by itself, with the unhandled error it stopped
/// on where it reported one, and what the app did about it.
@immutable
final class EngineStopped {
  const EngineStopped({this.error, this.recovery = EngineRecovery.gaveUp});

  /// The error's text, in English, for a bug report; null when the engine
  /// exited without one.
  final String? error;

  final EngineRecovery recovery;
}

/// What the engine told the app about its own health during this launch
/// (ENG-4, ENG-6): the errors it caught at its last-resort boundary and
/// went on from, and the last time it stopped by itself, which the
/// [EngineRestarter](engine_restarter.dart) reports. The app's notice
/// shows both; each is also printed for a debug log.
///
/// It lasts the launch, across engine restarts, and also keeps what the
/// notice already told: the notice remounts with the app's tree when an
/// engine restarts, and must not tell the same thing twice.
final class EngineHealth extends ChangeNotifier {
  StreamSubscription<EngineEvent>? _events;
  int _faults = 0;
  EngineFault? _lastFault;
  EngineStopped? _stopped;
  int _faultsTold = 0;
  DateTime? _faultToldAt;
  EngineStopped? _stopTold;

  /// How many errors the engine caught and went on from.
  int get faultCount => _faults;

  /// The newest of them, or null.
  EngineFault? get lastFault => _lastFault;

  /// The last stop of an engine that was not asked to; null while the
  /// first one runs.
  EngineStopped? get stopped => _stopped;

  /// Follows [engine]'s faults, instead of the previous engine's. Call it
  /// in the same turn as the controllers over [engine] are built, so it
  /// hears the engine's first events too.
  void follow(EngineClient engine) {
    unawaited(_events?.cancel());
    _events = engine.events.listen((event) {
      if (event is EngineFault) reportFault(event);
    });
  }

  /// Counts [fault], an error the engine caught and went on from.
  void reportFault(EngineFault fault) {
    debugPrint('The engine caught an error: ${fault.error}\n${fault.stack}');
    _faults++;
    _lastFault = fault;
    notifyListeners();
  }

  /// Records that the engine stopped by itself, and how far its restart
  /// got.
  void reportStopped(EngineStopped stopped) {
    _stopped = stopped;
    notifyListeners();
  }

  /// Whether faults came since the notice last looked and one should be
  /// told now: at most once per [interval], so an error that repeats in a
  /// timer is told once and again only after the user had quiet.
  bool takeFaultNotice(DateTime now, Duration interval) {
    if (_faults <= _faultsTold) return false;
    _faultsTold = _faults;
    final last = _faultToldAt;
    if (last != null && now.difference(last) < interval) return false;
    _faultToldAt = now;
    return true;
  }

  /// The stop to tell now, once: none while its restart runs.
  EngineStopped? takeStopNotice() {
    final stopped = _stopped;
    if (stopped == null || identical(stopped, _stopTold)) return null;
    if (stopped.recovery == EngineRecovery.restarting) return null;
    _stopTold = stopped;
    return stopped;
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }
}
