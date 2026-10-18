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
  /// and the call throws when the app does not take it. A change the app
  /// takes but cannot save throws [AppearanceNotSavedException] instead,
  /// in the app and, over the link, in the window.
  Future<void> setMode(ThemeModePreference mode);

  /// The Appearance tab's editor (M4 E25): replaces the palette and the
  /// mode at once; a no-op when both are already in force. Throws as
  /// [setMode] does.
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode);
}

/// An appearance change that was applied but not saved: the app is drawn
/// in it now, and it lasts until the app restarts unless a later save
/// carries it. [message] is what the failed save printed.
final class AppearanceNotSavedException implements Exception {
  const AppearanceNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's appearance concern (03 §10.1: one `ChangeNotifier` controller
/// per concern): this device's palette and theme mode as `ghost_theme`'s
/// [AppAppearance], the only input `MaterialApp` rebuilds on.
///
/// The composition root restores it from `settings.json` and saves every
/// change there (`services/stored_appearance.dart`); without a `save`
/// callback, as in most tests, it is held in memory only. A change is
/// applied before it is saved, as Séance's settings backend and
/// Poltergeist's appearance controller do, so the app repaints at once; a
/// failed save keeps the change on screen and throws
/// [AppearanceNotSavedException], so the caller can say it was not saved,
/// and the next save carries it.
final class AppearanceController extends ChangeNotifier
    implements AppearanceSettings {
  /// [initial] is the appearance stored on this device; none starts in the
  /// brand preset, following the system's light or dark.
  AppearanceController({AppAppearance? initial, this._save})
    : _value =
          initial ?? AppAppearance(palette: klabautermannThemePresets.initial);

  AppAppearance _value;
  final Future<void> Function(AppAppearance appearance)? _save;

  /// What the app is drawn in.
  @override
  AppAppearance get value => _value;

  ThemeModePreference get mode => _value.mode;

  /// The Appearance tab's theme-mode switch: keeps the palette and changes
  /// only which of its light and dark themes is drawn; a no-op when [mode]
  /// is already in force. Completes once the change is saved.
  @override
  Future<void> setMode(ThemeModePreference mode) =>
      setAppearance(_value.palette, mode);

  /// Applies the editor's palette and mode, then saves them; a no-op when
  /// both are already in force. Completes once the change is saved.
  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    final next = AppAppearance(palette: palette, mode: mode);
    if (next == _value) return;
    _value = next;
    notifyListeners();
    try {
      await _save?.call(_value);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AppearanceNotSavedException('The theme was not saved: $error'),
        stackTrace,
      );
    }
  }
}
