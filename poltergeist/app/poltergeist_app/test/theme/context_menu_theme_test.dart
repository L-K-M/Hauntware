import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';

void main() {
  test('desktop popup menus match the pane menu skin', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      final theme = buildPoltergeistThemeFor(
        ThemePresets.vapor,
        Brightness.dark,
        platform: platform,
      );
      expect(
        theme.popupMenuTheme.shape,
        theme.menuTheme.style!.shape!.resolve({}),
      );
      expect(
        theme.popupMenuTheme.menuPadding,
        const EdgeInsets.symmetric(vertical: 4),
      );
      expect(theme.popupMenuTheme.textStyle?.fontSize, 13);
    }
  });
}
