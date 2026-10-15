import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/chart_strings.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';

/// The chart words the app ships, in English.
final ChartStrings testChartStrings = klabautermannChartStrings(
  AppLocalizationsEn(),
);

/// Loads the date formats behind the chart strings' times, which the app's
/// Material localizations load at start.
Future<void> loadChartDateFormats() => initializeDateFormatting('en');

/// The brand theme a chart test draws in: the Linux build's, so the golden
/// scenes match the platform that compares them. Built once per variant,
/// so pumping a new frame does not start the app's theme animation.
ThemeData chartTheme(Brightness brightness, {String? fontFamily}) =>
    _themes.putIfAbsent((brightness, fontFamily), () {
      final theme = brightness == Brightness.dark
          ? GhostTheme.dark(
              klabautermannThemeStyle,
              platform: TargetPlatform.linux,
            )
          : GhostTheme.light(
              klabautermannThemeStyle,
              platform: TargetPlatform.linux,
            );
      if (fontFamily == null) return theme;
      return theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: fontFamily),
      );
    });

final _themes = <(Brightness, String?), ThemeData>{};

/// [child] on the brand theme's surface, centred.
Widget chartFrame(
  Widget child, {
  Brightness brightness = Brightness.light,
  String? fontFamily,
}) {
  final theme = chartTheme(brightness, fontFamily: fontFamily);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Material(
      color: theme.colorScheme.surface,
      child: Center(child: child),
    ),
  );
}

/// Goldens compare on the Linux CI runner only (03 §11.1): other hosts
/// rasterize text differently.
final bool goldensCompareHere = Platform.isLinux;

/// The family the goldens draw text in.
const goldenFontFamily = 'Roboto';

/// Loads the fonts the goldens draw with: Roboto and Material's icons from
/// the pinned Flutter SDK, so every runner draws the same glyphs (the test
/// default draws boxes, and system fonts differ per runner). Fails rather
/// than comparing against boxes when the SDK lacks them.
Future<void> loadGoldenFonts() async {
  // `flutter test` exports the SDK root.
  final fonts =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

  ByteData load(String name) {
    final file = File('$fonts/$name');
    if (!file.existsSync()) {
      throw StateError(
        'The golden font $name is missing from $fonts; '
        'run `flutter precache` to fetch the SDK fonts.',
      );
    }
    final bytes = file.readAsBytesSync();
    return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
  }

  await (FontLoader(goldenFontFamily)
        ..addFont(Future.value(load('Roboto-Regular.ttf')))
        ..addFont(Future.value(load('Roboto-Medium.ttf'))))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(Future.value(load('MaterialIcons-Regular.otf')))).load();
}
