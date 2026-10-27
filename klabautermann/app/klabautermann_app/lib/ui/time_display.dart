import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:klabautermann_core/klabautermann_core.dart' show HostProfile;

import '../controllers/time_display.dart';
import 'jobs_view.dart' show wallAt;

/// The device's time display for every route (A11Y-07), with each
/// server's zone offset as its probe last read it; absent in tests that
/// leave it out, where every time shows in the device's zone.
class TimeDisplayScope extends StatefulWidget {
  const TimeDisplayScope({
    super.key,
    required this.display,
    required this.serverProfile,
    required this.child,
  });

  final TimeDisplaySettings display;

  /// A server's probe findings, whose zone offset its times show at; the
  /// scope follows the profile of each server a screen asks about, so a
  /// zone read after the screen built rebuilds it.
  final ValueListenable<HostProfile?> Function(String serverId) serverProfile;

  final Widget child;

  /// The offset [serverId]'s times show at, which rebuilds [context] when
  /// the display or that server's zone changes: the server's zone offset
  /// when the user picked server times and its probe read one, or null
  /// for this device's zone.
  static Duration? serverOffsetOf(BuildContext context, String serverId) =>
      context
          .dependOnInheritedWidgetOfExactType<_TimeDisplayInherited>()
          ?.notifier
          ?.offsetFor(serverId);

  @override
  State<TimeDisplayScope> createState() => _TimeDisplayScopeState();
}

class _TimeDisplayScopeState extends State<TimeDisplayScope> {
  late _ZoneWatch _watch = _ZoneWatch(widget.display, widget.serverProfile);

  @override
  void didUpdateWidget(TimeDisplayScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.display, oldWidget.display) &&
        widget.serverProfile == oldWidget.serverProfile) {
      return;
    }
    _watch.dispose();
    _watch = _ZoneWatch(widget.display, widget.serverProfile);
  }

  @override
  void dispose() {
    _watch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _TimeDisplayInherited(notifier: _watch, child: widget.child);
}

class _TimeDisplayInherited extends InheritedNotifier<_ZoneWatch> {
  const _TimeDisplayInherited({
    required _ZoneWatch super.notifier,
    required super.child,
  });
}

/// Notifies when the display changes, or when the profile of a server a
/// screen asked about does: few servers show at once, and a zone changes
/// rarely, so every dependent rebuilding then costs little.
final class _ZoneWatch extends ChangeNotifier {
  _ZoneWatch(this._display, this._serverProfile) {
    _display.addListener(notifyListeners);
  }

  final TimeDisplaySettings _display;
  final ValueListenable<HostProfile?> Function(String serverId) _serverProfile;
  final Map<String, ValueListenable<HostProfile?>> _watched = {};

  Duration? offsetFor(String serverId) {
    if (_display.value != TimeDisplay.server) return null;

    final profile = _watched.putIfAbsent(serverId, () {
      final profile = _serverProfile(serverId);
      profile.addListener(notifyListeners);
      return profile;
    });
    return profile.value?.serverZone?.offset;
  }

  @override
  void dispose() {
    _display.removeListener(notifyListeners);
    for (final profile in _watched.values) {
      profile.removeListener(notifyListeners);
    }
    super.dispose();
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
