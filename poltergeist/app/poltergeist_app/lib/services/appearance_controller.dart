import 'package:ghost_ui/ghost_ui.dart' show PersistedSetting;

import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import 'settings_models.dart';

/// This device's theme in the app's isolate: what the MaterialApp is drawn
/// in, and the model the Appearance section writes through, in the Settings
/// dialog and (over the link) in the Settings window.
///
/// Its own notifier rather than a field the shell reads on rebuild, so the
/// MaterialApp above the whole app rebuilds when the theme changes and for
/// nothing else.
///
/// Applies a change before persisting it, as Séance's settings backend
/// does, rather than persist-first like the General switch
/// ([PersistedSetting]).
final class AppearanceController extends PersistedSetting<AppAppearance>
    implements AppearanceSettingsModel {
  AppearanceController({
    AppAppearance? initial,
    Future<void> Function(AppAppearance appearance)? save,
  }) : _persist = save,
       super(initial ?? poltergeistInitialAppearance);

  final Future<void> Function(AppAppearance appearance)? _persist;

  @override
  Future<void>? save(AppAppearance value) => _persist?.call(value);

  @override
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode) =>
      change(AppAppearance(palette: palette, mode: mode));
}
