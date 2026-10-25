import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The system notifications raised alerts post (ALR-01), apart from the
/// plugin, so widget tests can stand in a fake.
abstract interface class SystemNotifications {
  /// Asks the system to let the app post notifications, where it asks at
  /// all; true when it may.
  Future<bool> requestPermission();

  /// Posts (or replaces) the notification [id].
  Future<void> show(int id, {required String title, required String body});

  /// Withdraws the notification [id], if it still shows.
  Future<void> cancel(int id);
}

/// The words a notification and its channel carry, which the composition
/// root resolves for the device's locale.
typedef NotificationChannelWords = ({
  String channelName,
  String channelDescription,
  String openAction,
});

/// [SystemNotifications] over `flutter_local_notifications`. Notifications
/// post only while the app runs, so none is scheduled and no tap is
/// routed: tapping one brings the app forward, as the system does.
final class LocalSystemNotifications implements SystemNotifications {
  LocalSystemNotifications._(this._plugin, this._words);

  /// The plugin, set up once for this run; null where it has no
  /// implementation or failed to start, and then nothing posts.
  static Future<LocalSystemNotifications?> start(
    NotificationChannelWords words,
  ) async {
    final plugin = FlutterLocalNotificationsPlugin();
    try {
      final started = await plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings(_androidIcon),
          // Asked for when the user turns notifications on, never at start.
          iOS: const DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: const DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(
            defaultActionName: words.openAction,
          ),
          windows: const WindowsInitializationSettings(
            appName: _windowsAppName,
            appUserModelId: _windowsAppUserModelId,
            guid: _windowsGuid,
          ),
        ),
      );
      if (started == false) return null;
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          context: ErrorDescription('while starting system notifications'),
        ),
      );
      return null;
    }
    return LocalSystemNotifications._(plugin, words);
  }

  /// The launcher icon, which every Android build carries.
  static const _androidIcon = '@mipmap/ic_launcher';

  /// The app's name and Windows identity for its toasts: the application
  /// id the other platforms use (04 §12.3), and a GUID fixed for this
  /// app, which Windows keys the toasts' activation on.
  static const _windowsAppName = 'Klabautermann';
  static const _windowsAppUserModelId = 'ch.lkmc.klabautermann';
  static const _windowsGuid = '5b0e8d0c-7f43-4c55-9a1e-2f6b7a3d9c41';

  /// The Android channel raised alerts post on.
  static const _channelId = 'alerts';

  final FlutterLocalNotificationsPlugin _plugin;
  final NotificationChannelWords _words;

  @override
  Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true) ??
          false;
    }
    if (Platform.isMacOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true) ??
          false;
    }
    // Linux and Windows ask nothing of the app.
    return true;
  }

  @override
  Future<void> show(int id, {required String title, required String body}) =>
      _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _words.channelName,
            channelDescription: _words.channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
          ),
          macOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
          ),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
      );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
