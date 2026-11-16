import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/system_notifications.dart';
import 'alert_center.dart';
import 'alert_notifications.dart';

/// The number the app icon shows (ALR-02, decision Q3): the raised alerts
/// the user has not seen yet, and none while alert notifications are off.
int appBadgeCount({required int unseenRaised, required bool notificationsOn}) =>
    notificationsOn ? unseenRaised : 0;

/// Keeps the app icon badge at [appBadgeCount] of [alerts] and
/// [notifications]. The first count goes out at once, which clears a badge
/// a previous run left, since alerts last one run; later ones only when
/// the count changes. [SystemNotifications.setBadge] sets it on iOS and
/// macOS and does nothing elsewhere.
final class AppBadgeController {
  AppBadgeController({
    required this._alerts,
    required this._notifications,
    required this._sink,
  }) {
    _alerts.addListener(_update);
    _notifications.addListener(_update);
    _update();
  }

  final AlertCenter _alerts;
  final AlertNotificationsController _notifications;
  final SystemNotifications _sink;

  /// The count last sent, or null before the first.
  int? _sent;

  void _update() {
    final count = appBadgeCount(
      unseenRaised: _alerts.unseenRaised,
      notificationsOn: _notifications.enabled,
    );
    if (count == _sent) return;
    _sent = count;
    unawaited(_quietly(_sink.setBadge(count)));
  }

  /// A badge the system refused costs the badge, not the alert.
  static Future<void> _quietly(Future<void> update) async {
    try {
      await update;
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          context: ErrorDescription('while setting the app icon badge'),
        ),
      );
    }
  }

  void dispose() {
    _alerts.removeListener(_update);
    _notifications.removeListener(_update);
  }
}
