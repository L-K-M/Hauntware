import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// An engine that stopped by itself, with the unhandled error it stopped
/// on where it reported one.
@immutable
final class EngineStopped {
  const EngineStopped({this.error});

  /// The error's text, in English, for a bug report; null when the engine
  /// exited without one.
  final String? error;
}

/// What the engine told the app about its own health during this launch
/// (ENG-4, ENG-6): the errors it caught at its last-resort boundary and
/// went on from, and whether it stopped by itself. The app's notice shows
/// both; each is also printed for a debug log.
final class EngineHealth extends ChangeNotifier {
  StreamSubscription<EngineEvent>? _events;
  bool _disposed = false;
  int _faults = 0;
  EngineFault? _lastFault;
  EngineStopped? _stopped;

  /// How many errors the engine caught and went on from.
  int get faultCount => _faults;

  /// The newest of them, or null.
  EngineFault? get lastFault => _lastFault;

  /// Set once the engine stopped without being asked to; null while it
  /// runs.
  EngineStopped? get stopped => _stopped;

  /// Follows [engine]'s faults and its exit. Call it after the
  /// controller that needs the startup fleet has subscribed: the client
  /// holds its first events for its first listener only.
  ///
  /// [expected] says whether an exit is the app's own doing, a quit's
  /// [EngineClient.shutdown]; such an exit is not reported.
  void follow(IsolateEngineClient engine, {required bool Function() expected}) {
    unawaited(_events?.cancel());
    _events = engine.events.listen((event) {
      if (event is EngineFault) reportFault(event);
    });
    unawaited(
      engine.exited.then((exit) {
        if (_disposed || expected()) return;
        debugPrint('The engine stopped: ${exit.error}\n${exit.stack ?? ''}');
        reportStopped(EngineStopped(error: exit.error));
      }),
    );
  }

  /// Counts [fault], an error the engine caught and went on from.
  void reportFault(EngineFault fault) {
    debugPrint('The engine caught an error: ${fault.error}\n${fault.stack}');
    _faults++;
    _lastFault = fault;
    notifyListeners();
  }

  /// Records that the engine stopped by itself.
  void reportStopped(EngineStopped stopped) {
    _stopped = stopped;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_events?.cancel());
    super.dispose();
  }
}
