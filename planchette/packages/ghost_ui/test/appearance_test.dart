import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

void main() {
  test('automaticBrightness follows the mode, system being the platform', () {
    for (final platform in Brightness.values) {
      expect(
        automaticBrightness(platform, ThemeModePreference.system),
        platform,
      );
      expect(
        automaticBrightness(platform, ThemeModePreference.light),
        Brightness.light,
      );
      expect(
        automaticBrightness(platform, ThemeModePreference.dark),
        Brightness.dark,
      );
    }
  });

  test('surfaceBrightness is the framework estimate', () {
    expect(surfaceBrightness(const Color(0xFFFFFFFF)), Brightness.light);
    expect(surfaceBrightness(const Color(0xFF000000)), Brightness.dark);
    // The doc's edge: a mid grey at ~0.4 luminance is light, so the
    // neutrals it chooses bring the dark text with them.
    expect(surfaceBrightness(const Color(0xFF9E9E9E)), Brightness.light);
  });
}
