import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The running build's version as Settings › About shows it (`1.9.4`), or
/// null when the platform cannot tell.
///
/// Read once, by the app's isolate in `main`, and threaded to the settings
/// dialog.
Future<String?> readAppVersion() async {
  try {
    final version = (await PackageInfo.fromPlatform()).version;
    return version.isEmpty ? null : version;
  } on Exception catch (error) {
    debugPrint('The app version could not be read: $error');
    return null;
  }
}
