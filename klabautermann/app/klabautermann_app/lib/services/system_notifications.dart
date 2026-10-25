import 'dart:async';
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
  ///
  /// On Linux the plugin talks to the session bus, and its signal
  /// subscription connects in the background with no error handler, so a
  /// desktop without a bus would see an unhandled error, and every later
  /// call on that client would wait for a connection that never comes.
  /// The setup runs in its own error zone, which takes that error, and
  /// asks the notification server for its capabilities: notifications
  /// are unavailable when the bus fails first, the server refuses, or no
  /// answer comes within [_busAnswerTimeout].
  static Future<LocalSystemNotifications?> start(
    NotificationChannelWords words,
  ) async {
    final busFailed = Completer<void>();
    final starting = runZonedGuarded(() => _start(words, busFailed.future), (
      error,
      stackTrace,
    ) {
      _report(error, stackTrace);
      if (!busFailed.isCompleted) busFailed.complete();
    });
    return starting == null ? null : await starting;
  }

  /// How long startup waits for the notification server, which a working
  /// session bus answers in milliseconds; the app's window waits on it.
  static const _busAnswerTimeout = Duration(seconds: 3);

  static Future<LocalSystemNotifications?> _start(
    NotificationChannelWords words,
    Future<void> busFailed,
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
      final linux = plugin
          .resolvePlatformSpecificImplementation<
            LinuxFlutterLocalNotificationsPlugin
          >();
      if (linux != null) {
        final answered = await Future.any([
          linux.getCapabilities().then((_) => true),
          busFailed.then((_) => false),
        ]).timeout(_busAnswerTimeout, onTimeout: () => false);
        if (!answered) return null;
      }
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
      return null;
    }
    return LocalSystemNotifications._(plugin, words);
  }

  static void _report(Object error, StackTrace stackTrace) =>
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          context: ErrorDescription('while starting system notifications'),
        ),
      );

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
