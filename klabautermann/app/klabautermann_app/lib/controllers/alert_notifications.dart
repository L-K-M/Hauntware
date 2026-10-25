import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../services/system_notifications.dart';

/// What turning alert notifications on came to.
enum AlertNotificationsOutcome {
  /// They are on, and saved.
  enabled,

  /// The system refused the app; they stay off.
  denied,

  /// This device has no system notifications the app can post; they stay
  /// off.
  unavailable,
}

/// A notification's words for one raise, which the composition root
/// builds in the device's locale with the server's name.
typedef AlertNotificationText = ({String title, String body});

/// The system-notification sink of ALR-01 (03 §7.19): while the user has
/// it on, each alert the engine raises posts a notification, and its
/// clear withdraws it. Like the alert center it follows one engine run,
/// and posts only while Klabautermann is open, which every notification
/// says (Y3). The switch is device-local, kept in settings.json.
final class AlertNotificationsController extends ChangeNotifier {
  AlertNotificationsController(
    EngineClient engine, {
    required SystemNotifications? notifications,
    required this._textOf,
    bool enabled = false,
    this._save,
  }) : _notifications = notifications,
       _enabled = enabled && notifications != null {
    _events = engine.events.listen(_onEngineEvent);
  }

  final SystemNotifications? _notifications;
  final AlertNotificationText Function(LocalAlertChanged raise) _textOf;
  final Future<void> Function(bool enabled)? _save;
  late final StreamSubscription<EngineEvent> _events;
  bool _enabled;

  /// The raised alerts' notification ids, so a clear withdraws only what
  /// this run posted.
  final Set<int> _posted = {};

  /// Whether this device can post system notifications at all.
  bool get available => _notifications != null;

  /// Whether raised alerts post notifications now.
  bool get enabled => _enabled;

  /// Turns the notifications on, asking the system first, or off. A value
  /// that applied but was not saved lasts until the app restarts, and the
  /// save's error is rethrown.
  Future<AlertNotificationsOutcome> setEnabled(bool enabled) async {
    final notifications = _notifications;
    if (enabled) {
      if (notifications == null) return AlertNotificationsOutcome.unavailable;
      if (!await notifications.requestPermission()) {
        return AlertNotificationsOutcome.denied;
      }
    }
    if (enabled != _enabled) {
      _enabled = enabled;
      notifyListeners();
    }
    await _save?.call(enabled);
    return AlertNotificationsOutcome.enabled;
  }

  /// One id per rule and server, stable within the run.
  static int _idOf(String ruleId, String serverId) =>
      Object.hash(ruleId, serverId) & 0x7fffffff;

  void _onEngineEvent(EngineEvent event) {
    if (event is! LocalAlertChanged) return;
    final notifications = _notifications;
    if (notifications == null) return;

    final id = _idOf(event.ruleId, event.serverId);
    if (!event.raised) {
      if (_posted.remove(id)) unawaited(_quietly(notifications.cancel(id)));
      return;
    }
    if (!_enabled) return;
    final text = _textOf(event);
    _posted.add(id);
    unawaited(
      _quietly(notifications.show(id, title: text.title, body: text.body)),
    );
  }

  /// A post the system refused costs the notification, not the alert,
  /// which the alert center still shows.
  static Future<void> _quietly(Future<void> post) async {
    try {
      await post;
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          context: ErrorDescription('while posting an alert notification'),
        ),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }
}
