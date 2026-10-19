import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The running build's version as the About dialog shows it (`1.9.1`), or
/// null when the platform cannot tell.
///
/// Read once, by the app's isolate in `main`. The desktop settings
/// window's engine registers no plugins (D32), so the window gets the
/// version in the settings link's snapshot instead.
Future<String?> readAppVersion() async {
  try {
    final version = (await PackageInfo.fromPlatform()).version;
    return version.isEmpty ? null : version;
  } on Exception catch (error) {
    debugPrint('The app version could not be read: $error');
    return null;
  }
}
