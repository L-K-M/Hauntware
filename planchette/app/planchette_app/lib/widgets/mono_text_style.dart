import 'package:flutter/painting.dart';
import 'package:ghost_fonts/ghost_fonts.dart'
    show ghostMonoFontFamilies, ghostMonoFontFamily;

/// Host-key fingerprints, key paths and remote paths: the bundled code
/// stack, as Séance and Poltergeist pass, since a bare 'monospace' draws
/// the proportional system font on macOS, iOS and Windows.
const TextStyle monoTextStyle = TextStyle(
  fontFamily: ghostMonoFontFamily,
  fontFamilyFallback: ghostMonoFontFamilies,
);
