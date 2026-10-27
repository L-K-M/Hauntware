import 'package:flutter/widgets.dart';

import '../controllers/time_display.dart';
import 'jobs_view.dart' show wallAt;

/// The device's time display for every route (A11Y-07), with each
/// server's zone offset as its probe last read it; absent in tests that
/// leave it out, where every time shows in the device's zone.
class TimeDisplayScope extends InheritedNotifier<TimeDisplaySettings> {
  const TimeDisplayScope({
    super.key,
    required TimeDisplaySettings display,
    required this.serverZoneOffset,
    required super.child,
  }) : super(notifier: display);

  /// A server's zone offset from UTC, or null until its probe reads it.
  final Duration? Function(String serverId) serverZoneOffset;

  /// The offset [serverId]'s times show at, which rebuilds [context] when
  /// the display changes: the server's zone offset when the user picked
  /// server times and it is known, or null for this device's zone.
  static Duration? serverOffsetOf(BuildContext context, String serverId) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<TimeDisplayScope>();
    if (scope?.notifier?.value != TimeDisplay.server) return null;

    return scope!.serverZoneOffset(serverId);
  }
}

/// [at], a time [serverId] reported, as the time display shows it: a
/// date-time whose fields read the wall clock in the server's zone or in
/// this device's. Format its fields only; its own zone is meaningless.
DateTime displayTime(BuildContext context, String serverId, DateTime at) =>
    switch (TimeDisplayScope.serverOffsetOf(context, serverId)) {
      final offset? => wallAt(at, offset),
      null => at.toLocal(),
    };
