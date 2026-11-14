import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import 'persisted_value_controller.dart';
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
/// ([PersistedValueController]).
final class AppearanceController extends PersistedValueController<AppAppearance>
    implements AppearanceSettingsModel {
  AppearanceController({
    AppAppearance? initial,
    Future<void> Function(AppAppearance appearance)? save,
  }) : super(initial ?? poltergeistInitialAppearance, save);

  @override
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode) =>
      write(AppAppearance(palette: palette, mode: mode));
}
