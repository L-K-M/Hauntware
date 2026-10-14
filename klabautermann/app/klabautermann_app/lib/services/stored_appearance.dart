import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show DeviceSettingsStore;

import '../controllers/appearance_controller.dart';
import '../theme/app_theme.dart';

/// The palette's stored form, bound to Klabautermann's style.
const _themeCodec = GhostThemeCodec(klabautermannThemeStyle);

/// The keys of the appearance object in `settings.json`.
enum _AppearanceKey { palette, mode }

/// The app's appearance over [settings]: restored from what the file holds,
/// and saved there on every change. The composition root builds it once;
/// whoever changes the theme, the Settings route or (over the settings
/// link) the desktop settings window, goes through this controller and so
/// through the app's own store.
AppearanceController appearanceFromSettings(DeviceSettingsStore settings) =>
    AppearanceController(
      initial: decodeStoredAppearance(settings.appearance),
      save: (appearance) =>
          settings.setAppearance(encodeStoredAppearance(appearance)),
    );

/// The appearance [json] holds, leniently, as Poltergeist reads its own:
/// no object is the brand preset following the system, a damaged palette
/// costs at most its own bad values ([GhostThemeCodec.decodeStored]), and
/// an unknown mode reads as following the system. A theme is not worth a
/// failed launch.
AppAppearance decodeStoredAppearance(Map<String, Object?>? json) {
  final mode = json?[_AppearanceKey.mode.name];
  return AppAppearance(
    palette: _themeCodec.decodeStored(json?[_AppearanceKey.palette.name]),
    mode:
        ThemeModePreference.values.asNameMap()[mode] ??
        ThemeModePreference.system,
  );
}

/// The inverse of [decodeStoredAppearance]: the palette in `ghost_theme`'s
/// stored form and the mode by name.
Map<String, Object?> encodeStoredAppearance(AppAppearance appearance) => {
  _AppearanceKey.palette.name: appearance.palette.toJson(),
  _AppearanceKey.mode.name: appearance.mode.name,
};
