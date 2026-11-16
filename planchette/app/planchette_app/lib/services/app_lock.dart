import 'package:flutter/foundation.dart';
import 'package:ghost_keystore/app_lock.dart' show AppLockController;

import 'app_settings.dart';
import 'device_authenticator.dart';
import 'template_strings.dart';

/// The app lock both entry points share, over the stored setting: off
/// unless the user turned it on, and saved through [settings] only once
/// the device authentication the change needs has passed. Every window's
/// gate and the remote catalog's credential reads go through it.
AppLockController openAppLock(SettingsController settings) => AppLockController(
  authenticator: LocalDeviceAuthenticator(
    // The catalog is English only; read when the prompt opens, so a
    // later catalog locale needs no change here.
    reason: () => templateStrings().appLockReason,
  ),
  supported: appLockSupportedOn(defaultTargetPlatform),
  enabled: settings.value.appLock,
  save: settings.saveAppLock,
);
