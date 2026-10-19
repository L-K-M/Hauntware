import 'package:flutter/widgets.dart';
import 'package:ghost_fonts/ghost_fonts.dart';

/// Whether the editor's font joins character pairs such as `->` and `!=`
/// into one symbol. Only fonts that draw ligatures change, and the bundled
/// ones keep every character on its own cell either way, so carets and
/// selections stay where they were. Each app stores the choice itself.
enum EditorLigatures {
  off,
  on;

  /// The choice a settings file stored as [name] ('off'). Anything else,
  /// missing or from a newer version, is [on], the default.
  static EditorLigatures named(Object? name) =>
      values.firstWhere((value) => value.name == name, orElse: () => on);

  /// Preserve host styling while applying the selected font's ligature sets.
  TextStyle applyTo(TextStyle style) {
    final features = (this == on ? MonoLigatures.on : MonoLigatures.off)
        .featuresFor(style.fontFamily);
    if (features.isEmpty) return style;

    return style.copyWith(fontFeatures: [...?style.fontFeatures, ...features]);
  }
}

/// The bundled face the editor draws in when its host names no other, and
/// the one a font menu marks as the default.
const BundledMonoFont editorDefaultFont = BundledMonoFont.jetBrainsMono;

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
  final bundled = editorDefaultFont.family;
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
