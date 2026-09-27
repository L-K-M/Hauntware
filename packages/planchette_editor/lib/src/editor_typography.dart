import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Typography defaults for the editing surface.
///
/// 'monospace' is a CSS generic family, not an installed font: only Linux
/// fontconfig and Android's family alias resolve it. On macOS and Windows
/// Flutter silently falls back to the platform's default proportional font,
/// which is wrong for code. Each platform therefore starts from a real
/// monospace family it ships, with a shared fallback chain that still ends
/// in the generic name.
final class EditorTypography {
  const EditorTypography._();

  /// Gutter and editor text size when the host supplies no style.
  static const double defaultFontSize = 14;

  /// Line height applied to the same default style.
  static const double defaultLineHeight = 1.35;

  /// Families tried when [monospace]'s primary family is missing, in order.
  static const List<String> monospaceFallbacks = [
    'Menlo',
    'Consolas',
    'Cascadia Mono',
    'DejaVu Sans Mono',
    'Noto Sans Mono',
    'Liberation Mono',
    'Ubuntu Mono',
    'Courier New',
    'monospace',
  ];

  /// The monospace default for [platform], sized with [defaultFontSize] and
  /// [defaultLineHeight].
  static TextStyle monospace(TargetPlatform platform) => switch (platform) {
    // Apple platforms ship Menlo everywhere the editor runs.
    TargetPlatform.macOS ||
    TargetPlatform.iOS => _style(fontFamily: 'Menlo'),
    // Consolas is present on every supported Windows release; Cascadia Mono
    // covers newer installs through the fallback chain.
    TargetPlatform.windows => _style(fontFamily: 'Consolas'),
    // fontconfig and Android resolve the generic name natively.
    TargetPlatform.android ||
    TargetPlatform.fuchsia ||
    TargetPlatform.linux => _style(fontFamily: 'monospace'),
  };

  static TextStyle _style({required String fontFamily}) => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: monospaceFallbacks,
    fontSize: defaultFontSize,
    height: defaultLineHeight,
  );
}
