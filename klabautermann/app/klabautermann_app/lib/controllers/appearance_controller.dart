import 'package:flutter/foundation.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../theme/app_theme.dart';

/// What the Appearance tab reads and changes, apart from where it runs:
/// [AppearanceController] in the app, and a copy kept over the settings
/// link in the desktop settings window, whose isolate shares no memory
/// with the app's (`services/settings_window/`). [value] is the appearance
/// the app is drawn in.
abstract interface class AppearanceSettings
    implements ValueListenable<AppAppearance> {
  /// Switches between the palette's light and dark themes, or back to
  /// following the system; a no-op when [mode] is already in force. In the
  /// settings window [value] trails the call by a round trip to the app,
  /// and the call throws when the app does not take it.
  Future<void> setMode(ThemeModePreference mode);
}

/// The app's appearance concern (03 §10.1: one `ChangeNotifier` controller
/// per concern): this device's palette and theme mode as `ghost_theme`'s
/// [AppAppearance], the only input `MaterialApp` rebuilds on.
///
/// Held in memory only: a launch starts in the brand preset, following the
/// system's light or dark. Persistence arrives with the device settings
/// store in a later PR.
final class AppearanceController extends ChangeNotifier
    implements AppearanceSettings {
  AppAppearance _value = AppAppearance(
    palette: klabautermannThemePresets.initial,
  );

  /// What the app is drawn in.
  @override
  AppAppearance get value => _value;

  ThemeModePreference get mode => _value.mode;

  /// The Appearance tab's theme-mode switch: keeps the palette and changes
  /// only which of its light and dark themes is drawn.
  @override
  Future<void> setMode(ThemeModePreference mode) async {
    if (mode == _value.mode) return;
    _value = AppAppearance(palette: _value.palette, mode: mode);
    notifyListeners();
  }
}
