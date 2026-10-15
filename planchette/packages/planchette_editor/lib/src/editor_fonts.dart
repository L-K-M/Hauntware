import 'package:flutter/widgets.dart';
import 'package:ghost_fonts/ghost_fonts.dart';

/// The editor's monospace family: bundled JetBrains Mono everywhere, so the
/// document looks the same on every platform and draws ligatures. The
/// fallbacks start with it too, so a host family that is not installed
/// lands on it, then name the faces [platform] has for characters it lacks.
/// Pass the operating system ([defaultTargetPlatform]), not a theme's
/// platform: installed fonts follow the OS.
///
/// Flutter hands `fontFamily: 'monospace'` to the platform font manager as an
/// ordinary family name. Only fontconfig (Linux) and Android's font aliases
/// treat it as the generic monospace family. CoreText and DirectWrite have no
/// family by that name, so the paragraph skips it and falls back to the
/// system UI font, which is proportional on macOS and Windows. Name real
/// families there.
TextStyle editorMonospaceFor(TargetPlatform platform) {
  final bundled = BundledMonoFont.jetBrainsMono.family;
  return TextStyle(
    fontFamily: bundled,
    fontFamilyFallback: [
      bundled,
      ...switch (platform) {
        TargetPlatform.macOS ||
        TargetPlatform.iOS => const ['Menlo', 'Monaco', 'Courier New'],
        TargetPlatform.windows => const [
          'Cascadia Mono',
          'Consolas',
          'Courier New',
        ],
        TargetPlatform.linux ||
        TargetPlatform.android ||
        TargetPlatform.fuchsia => const [
          'DejaVu Sans Mono',
          'Liberation Mono',
          'Noto Sans Mono',
          'Droid Sans Mono',
        ],
      },
      'monospace',
    ],
  );
}
