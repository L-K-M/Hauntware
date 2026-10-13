import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';

import 'support/host_styles.dart';

/// The brightness half of Séance's appearance-level tests, moved with
/// [resolveBrightness]: a palette's own surface decides, otherwise the mode
/// does, and the system only when the mode defers to it.
void main() {
  test('a surface decides it; otherwise the mode, then the system', () {
    final automatic = seancePresets.brand;
    expect(
      resolveBrightness(automatic, Brightness.dark, ThemeModePreference.system),
      Brightness.dark,
    );
    expect(
      resolveBrightness(automatic, Brightness.dark, ThemeModePreference.light),
      Brightness.light,
    );
    expect(
      resolveBrightness(automatic, Brightness.light, ThemeModePreference.dark),
      Brightness.dark,
    );
    expect(
      resolveBrightness(
        seancePresets.paper,
        Brightness.dark,
        ThemeModePreference.dark,
      ),
      Brightness.light,
    );
    expect(
      resolveBrightness(
        seancePresets.midnight,
        Brightness.light,
        ThemeModePreference.system,
      ),
      Brightness.dark,
    );
    expect(
      resolveBrightness(
        seancePresets.midnight,
        Brightness.light,
        ThemeModePreference.light,
      ),
      Brightness.dark,
    );
  });
}
