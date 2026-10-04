import 'package:flutter/widgets.dart';

/// The editor's monospace font family for [platform], with fallbacks. Pass
/// the operating system ([defaultTargetPlatform]), not a theme's platform:
/// installed fonts follow the OS.
///
/// Flutter hands `fontFamily: 'monospace'` to the platform font manager as an
/// ordinary family name. Only fontconfig (Linux) and Android's font aliases
/// treat it as the generic monospace family. CoreText and DirectWrite have no
/// family by that name, so the paragraph skips it and falls back to the
/// system UI font, which is proportional on macOS and Windows. Name real
/// families there.
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
    // The alias again last: a host family replaces it as the first choice.
    fontFamilyFallback: [
      'DejaVu Sans Mono',
      'Liberation Mono',
      'Noto Sans Mono',
      'Droid Sans Mono',
      'monospace',
    ],
  ),
};
