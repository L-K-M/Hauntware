import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controllers/log_display.dart';
import '../../theme/app_theme.dart';
import 'log_text.dart';

/// Line height as a multiple of the font size.
const double _lineHeightFactor = 1.35;

/// How many glyph advances a journal row's fields are indented by.
const int _fieldIndent = 2;

/// What every row's layout depends on: the theme, the text scale and the
/// locale (a cut line's note), the monospace style and its strut, and the
/// line height and glyph advance measured from them. A new instance means
/// every measured row is stale.
final class TextLayout {
  TextLayout._({
    required this.theme,
    required this.scaler,
    required this.locale,
    required this.fontSize,
    required this.base,
    required this.strut,
    required this.lineHeight,
    required this.advance,
    required this.ellipsis,
  }) : palette = LogPalette.fromTheme(theme);

  /// The layout for [context], or [previous] when nothing it depends on
  /// changed. [textSize] is the device's chosen log text size, or null
  /// for the default.
  static TextLayout of(
    BuildContext context,
    TextLayout? previous,
    int? textSize,
  ) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.localeOf(context);
    final fontSize = (textSize ?? kLogTextSizeDefault).toDouble();
    if (previous != null &&
        previous.theme == theme &&
        previous.scaler == scaler &&
        previous.locale == locale &&
        previous.fontSize == fontSize) {
      return previous;
    }

    final base = monoTextStyle(
      TextStyle(fontSize: fontSize, height: _lineHeightFactor),
    );
    // Every row is a whole number of these lines, whatever glyphs or
    // fallback fonts it holds, so extents can be computed.
    final strut = StrutStyle.fromTextStyle(base, forceStrutHeight: true);
    double measure(String sample, {TextStyle? style, bool height = false}) {
      final painter = TextPainter(
        text: TextSpan(text: sample, style: style ?? base),
        textDirection: TextDirection.ltr,
        strutStyle: strut,
        textScaler: scaler,
      )..layout();
      final value = height ? painter.height : painter.width;
      painter.dispose();
      return value;
    }

    return TextLayout._(
      theme: theme,
      scaler: scaler,
      locale: locale,
      fontSize: fontSize,
      base: base,
      strut: strut,
      lineHeight: measure(' ', height: true),
      // The advance of a Latin-1 glyph in a monospace font, regular or
      // bold; for a proportional fallback, one of its widest.
      advance: math.max(
        measure('W'),
        measure('W', style: base.copyWith(fontWeight: FontWeight.bold)),
      ),
      ellipsis: measure('\u2026'),
    );
  }

  final ThemeData theme;
  final TextScaler scaler;
  final Locale locale;

  /// The log text size before the text scale.
  final double fontSize;
  final LogPalette palette;
  final TextStyle base;
  final StrutStyle strut;
  final double lineHeight;
  final double advance;

  /// The width of the ellipsis that ends a row too wide for the view.
  final double ellipsis;

  double get iconSize => scaler.scale(fontSize);

  /// The level icon's column.
  double get gutter => iconSize + 6;

  /// How far a journal row's fields are indented.
  double get fieldIndent => _fieldIndent * advance;
}
