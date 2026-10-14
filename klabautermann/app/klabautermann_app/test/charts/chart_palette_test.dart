import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show contrastRatio;
import 'package:klabautermann_app/ui/charts/charts.dart';

import '../support/charts.dart';

const _indicatorContrast = 3.0; // WCAG 1.4.11 non-text contrast

/// Two marks a chart tells apart by colour stay at least this far apart in
/// CIELAB (CIE76) for every vision below: well past the just-noticeable
/// difference of about 2.3, so thin lines still separate at a glance.
const _distinctDelta = 10.0;

/// Colour-vision deficiencies at full severity, as linear-RGB matrices
/// (Machado, Oliveira and Fernandes 2009), beside normal vision.
const _visions = <String, List<List<double>>>{
  'normal': [
    [1, 0, 0],
    [0, 1, 0],
    [0, 0, 1],
  ],
  'protanopia': [
    [0.152286, 1.052583, -0.204868],
    [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998],
  ],
  'deuteranopia': [
    [0.367322, 0.860646, -0.227968],
    [0.280085, 0.672501, 0.047413],
    [-0.011820, 0.042940, 0.968881],
  ],
  'tritanopia': [
    [1.255528, -0.076749, -0.178779],
    [-0.078411, 0.930809, 0.147602],
    [0.004733, 0.691367, 0.303900],
  ],
};

/// 03 §10.7 and A11Y-04: the severity and series palettes clear the
/// non-text contrast floor on every surface a chart sits on and stay
/// colour-blind-safe, in both brand themes.
void main() {
  for (final brightness in Brightness.values) {
    final theme = chartTheme(brightness);
    final palette = ChartPalette.fromTheme(theme);
    final label = '${brightness.name} theme';

    test('every chart colour clears 3:1 on the chart surfaces ($label)', () {
      final chrome = theme.extension<GhostChrome>()!;
      final surfaces = {
        'surface': theme.colorScheme.surface,
        'container low': theme.colorScheme.surfaceContainerLow,
        'container': theme.colorScheme.surfaceContainer,
        'container high': theme.colorScheme.surfaceContainerHigh,
        'pane': chrome.paneBackground,
        'inspector': chrome.inspectorBackground,
        'rail': chrome.sidebarBackground,
      };
      final colours = {
        for (final (index, colour) in palette.series.indexed)
          'series $index': colour,
        'warning': palette.warning,
        'critical': palette.critical,
        'muted': palette.muted,
      };

      expect(palette.series, hasLength(4));
      for (final MapEntry(key: name, value: colour) in colours.entries) {
        for (final MapEntry(key: surfaceName, value: surface)
            in surfaces.entries) {
          expect(
            contrastRatio(colour, surface),
            greaterThanOrEqualTo(_indicatorContrast),
            reason: '$name $colour on the $surfaceName ($surface)',
          );
        }
      }
    });

    test('every bar fill clears 3:1 on the bar track ($label)', () {
      for (final colour in [
        ...palette.series,
        palette.warning,
        palette.critical,
        palette.muted,
      ]) {
        expect(
          contrastRatio(colour, palette.track),
          greaterThanOrEqualTo(_indicatorContrast),
          reason: '$colour on the track ${palette.track}',
        );
      }
    });

    test('series and severities stay apart in every vision ($label)', () {
      final sets = {
        'series': palette.series,
        'severity': [palette.warning, palette.critical],
      };

      for (final MapEntry(key: setName, value: colours) in sets.entries) {
        for (final MapEntry(key: vision, value: matrix) in _visions.entries) {
          for (var i = 0; i < colours.length; i++) {
            for (var j = i + 1; j < colours.length; j++) {
              expect(
                _labDistance(colours[i], colours[j], matrix),
                greaterThanOrEqualTo(_distinctDelta),
                reason: '$setName $i and $j under $vision',
              );
            }
          }
        }
      }
    });
  }
}

/// The CIE76 distance between [a] and [b] as a viewer with [vision] sees
/// them.
double _labDistance(Color a, Color b, List<List<double>> vision) {
  final first = _lab(_simulate(a, vision));
  final second = _lab(_simulate(b, vision));
  return math.sqrt(
    math.pow(first[0] - second[0], 2) +
        math.pow(first[1] - second[1], 2) +
        math.pow(first[2] - second[2], 2),
  );
}

List<double> _simulate(Color colour, List<List<double>> vision) {
  double linear(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  final rgb = [linear(colour.r), linear(colour.g), linear(colour.b)];
  return [
    for (final row in vision)
      (row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2]).clamp(0.0, 1.0),
  ];
}

/// CIELAB under D65 from linear sRGB.
List<double> _lab(List<double> rgb) {
  final x = 0.4124 * rgb[0] + 0.3576 * rgb[1] + 0.1805 * rgb[2];
  final y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
  final z = 0.0193 * rgb[0] + 0.1192 * rgb[1] + 0.9505 * rgb[2];
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  final fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
