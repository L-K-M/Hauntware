import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// A phone's time in the background (03 §9.5 item 6): from [start] to
/// [end] by this device's clock, which paused sampling [serverIds], the
/// servers the engine was sampling, or said it paused, whose screen was
/// open at the return.
@immutable
final class BackgroundPause {
  BackgroundPause({
    required this.start,
    required this.end,
    required Set<String> serverIds,
  }) : serverIds = Set.unmodifiable(serverIds);

  final DateTime start, end;
  final Set<String> serverIds;
}

/// The return banner's pause state: when the background began, which
/// servers the engine had sampling then or said it paused since, and the
/// pause shown until dismissed or its server leaves. The owner feeds it
/// the app's activity and every sampling phase; callbacks read the owner's
/// open servers and currently sampling servers, so this tracker keeps none
/// of the controller's bookkeeping itself.
final class BackgroundPauseNotifier extends ChangeNotifier
    implements ValueListenable<BackgroundPause?> {
  /// The first callback reads the monitoring clock, the second answers the
  /// ids currently in their sampling phase, and the third whether a view
  /// holds a server open.
  BackgroundPauseNotifier(this._now, this._samplingServers, this._isOpen);

  final DateTime Function() _now;
  final Set<String> Function() _samplingServers;
  final bool Function(String serverId) _isOpen;

  DateTime? _backgroundSince;
  Set<String> _pausedServers = {};
  BackgroundPause? _value;

  @override
  BackgroundPause? get value => _value;

  /// Notes a changed app activity. Going away clears the banner and keeps
  /// when it happened; coming back shows the pause for the servers still
  /// open that had been sampling.
  void noteActivity(AppActivity activity) {
    final now = _now();
    switch (activity) {
      case AppActivity.background:
        _backgroundSince = now;
        _pausedServers = _samplingServers();
        _set(null);
      case AppActivity.foreground:
        final since = _backgroundSince;
        _backgroundSince = null;
        final shown = _pausedServers.where(_isOpen).toSet();
        if (since == null || shown.isEmpty) return;
        _set(BackgroundPause(start: since, end: now, serverIds: shown));
    }
  }

  /// Notes the engine's latest sampling [phase] of [serverId]: one the
  /// engine says it paused while the app was away counts as paused even if
  /// it was not sampling when the app went away.
  void notePhase(String serverId, SamplingPhase phase) {
    if (_backgroundSince != null && phase == SamplingPhase.pausedInBackground) {
      _pausedServers.add(serverId);
    }
  }

  /// The return banner tells of the screen open at the return only.
  void forget(String serverId) {
    final pause = _value;
    if (pause == null || !pause.serverIds.contains(serverId)) return;
    final rest = pause.serverIds.difference({serverId});
    _set(
      rest.isEmpty
          ? null
          : BackgroundPause(
              start: pause.start,
              end: pause.end,
              serverIds: rest,
            ),
    );
  }

  void dismiss() => _set(null);

  void _set(BackgroundPause? value) {
    if (identical(_value, value)) return;
    _value = value;
    notifyListeners();
  }
}
