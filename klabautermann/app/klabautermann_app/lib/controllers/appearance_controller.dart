import 'package:flutter/foundation.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../theme/app_theme.dart';

/// The app's appearance concern (03 §10.1: one `ChangeNotifier` controller
/// per concern): this device's palette and theme mode as `ghost_theme`'s
/// [AppAppearance], the only input `MaterialApp` rebuilds on.
///
/// Held in memory only: a launch starts in the brand preset, following the
/// system's light or dark. Persistence arrives with the device settings
/// store in a later PR.
final class AppearanceController extends ChangeNotifier {
  AppAppearance _value = AppAppearance(
    palette: klabautermannThemePresets.initial,
  );

  /// What the app is drawn in.
  AppAppearance get value => _value;

  ThemeModePreference get mode => _value.mode;

  /// The Appearance tab's theme-mode switch: keeps the palette and changes
  /// only which of its light and dark themes is drawn.
  set mode(ThemeModePreference mode) {
    if (mode == _value.mode) return;
    _value = AppAppearance(palette: _value.palette, mode: mode);
    notifyListeners();
  }
}
