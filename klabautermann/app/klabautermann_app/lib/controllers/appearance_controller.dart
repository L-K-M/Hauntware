import 'package:flutter/foundation.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../theme/app_theme.dart';

/// The app's appearance concern (03 §10.1: one `ChangeNotifier` controller
/// per concern): this device's palette and theme mode as `ghost_theme`'s
/// [AppAppearance], the only input `MaterialApp` rebuilds on.
///
/// The composition root restores it from `settings.json` and saves every
/// change there (`services/stored_appearance.dart`); without a `save`
/// callback, as in most tests, it is held in memory only. A change is
/// applied before it is saved, as Séance's settings backend and
/// Poltergeist's appearance controller do, so the app repaints at once; a
/// failed save keeps the change on screen and throws, so the caller can
/// say it was not saved, and the next save carries it.
final class AppearanceController extends ChangeNotifier {
  /// [initial] is the appearance stored on this device; none starts in the
  /// brand preset, following the system's light or dark.
  AppearanceController({AppAppearance? initial, this._save})
    : _value =
          initial ?? AppAppearance(palette: klabautermannThemePresets.initial);

  AppAppearance _value;
  final Future<void> Function(AppAppearance appearance)? _save;

  /// What the app is drawn in.
  AppAppearance get value => _value;

  ThemeModePreference get mode => _value.mode;

  /// The Appearance tab's theme-mode switch: keeps the palette and changes
  /// only which of its light and dark themes is drawn; a no-op when [mode]
  /// is already in force. Completes once the change is saved.
  Future<void> setMode(ThemeModePreference mode) async {
    if (mode == _value.mode) return;
    _value = AppAppearance(palette: _value.palette, mode: mode);
    notifyListeners();
    await _save?.call(_value);
  }
}
