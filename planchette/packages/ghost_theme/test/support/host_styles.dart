import 'package:flutter/painting.dart' show Color;
import 'package:ghost_theme/ghost_theme.dart';

/// Séance's binding of the shared model: the violet seed, the brand name,
/// the Terminal preset a new device starts in, and the terminal block its
/// palettes carry. The palette suite moved here from Séance with these
/// values, so its assertions stay literal.
const GhostThemeStyle seanceStyle = GhostThemeStyle(
  seed: Color(0xFF6B5BD2),
  brand: 'Séance',
  initial: 'Terminal',
  hasTerminal: true,
);

/// Poltergeist's binding: its teal seed, its brand name, the Vapor preset
/// it starts in, and no terminal block — it reads past a pasted one and
/// never writes one.
const GhostThemeStyle poltergeistStyle = GhostThemeStyle(
  seed: Color(0xFF3D8A78),
  brand: 'Poltergeist',
  initial: 'Vapor',
  hasTerminal: false,
);

final GhostThemePresets seancePresets = GhostThemePresets(seanceStyle);
final GhostThemeCodec seanceCodec = GhostThemeCodec(seanceStyle);
final GhostThemePresets poltergeistPresets = GhostThemePresets(
  poltergeistStyle,
);
final GhostThemeCodec poltergeistCodec = GhostThemeCodec(poltergeistStyle);
