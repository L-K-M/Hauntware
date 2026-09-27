import 'package:flutter/widgets.dart';

/// The editor's monospace font family for [platform], with fallbacks.
///
/// Flutter hands `fontFamily: 'monospace'` to the platform font manager as an
/// ordinary family name. Only fontconfig (Linux) and Android's font aliases
/// treat it as the generic monospace family. Skia's CoreText manager maps it
/// to Courier on Apple platforms, and DirectWrite has no such family, so
/// Windows falls back to its proportional UI font. Name real families there.
TextStyle editorMonospaceFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.iOS => const TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Monaco', 'Courier New', 'monospace'],
  ),
  TargetPlatform.windows => const TextStyle(
    fontFamily: 'Cascadia Mono',
    fontFamilyFallback: ['Consolas', 'Courier New', 'monospace'],
  ),
  TargetPlatform.linux ||
  TargetPlatform.android ||
  TargetPlatform.fuchsia => const TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: [
      'DejaVu Sans Mono',
      'Liberation Mono',
      'Noto Sans Mono',
      'Droid Sans Mono',
    ],
  ),
};
