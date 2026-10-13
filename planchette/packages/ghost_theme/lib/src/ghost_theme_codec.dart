import 'dart:convert';

import 'package:flutter/painting.dart' show Color;

import 'ghost_theme_presets.dart';
import 'ghost_theme_style.dart';
import 'theme_palette.dart';

/// The stored and pasted form of a [ThemePalette], bound to the host's
/// [GhostThemeStyle].
///
/// The behaviours are Séance's `ThemePalette` statics, moved verbatim, with
/// the one per-app fork — [GhostThemeStyle.hasTerminal] — carrying the
/// difference the two apps already had: Séance reads and writes the
/// `terminal` block, an app without a themed terminal reads past it and
/// never writes one. Getting that flag wrong on either side changes the
/// bytes one app stores, so it gates [fromJson], [tryParse] and the
/// value-key gate together.
final class GhostThemeCodec {
  const GhostThemeCodec(this.style);

  final GhostThemeStyle style;

  /// A palette from [json], leniently: a missing or unreadable accent or
  /// corner scale takes the brand preset's, a missing or unreadable
  /// Automatic-able colour is Automatic, and a terminal block is taken
  /// whole or not at all ([ThemeTerminalColors.fromJson]) — when
  /// [GhostThemeStyle.hasTerminal], otherwise the key is ignored. The gaps
  /// fill from the brand preset rather than from [GhostThemeStyle.initial]
  /// because the brand preset is the one whose colours are all Automatic,
  /// so a partial theme completes as one look. A blank or missing name is
  /// whatever the values match ([GhostThemePresets.relabel]), so a
  /// hand-written theme that says nothing but a preset's colours is that
  /// preset.
  ThemePalette fromJson(Map<String, Object?> json) {
    final presets = GhostThemePresets(style);
    final fallback = presets.brand;
    final name = json['name'];
    final named = name is String && name.trim().isNotEmpty;
    final family = json['fontFamily'];
    final corners = json['cornerScale'];
    Color? color(ThemeSlot slot) => parseThemeColor(json[slot.name]);
    final palette = ThemePalette(
      name: named ? name : ThemePalette.customName,
      accent: parseThemeColor(json['accent']) ?? fallback.accent,
      surface: color(ThemeSlot.surface),
      sidebar: color(ThemeSlot.sidebar),
      raised: color(ThemeSlot.raised),
      text: color(ThemeSlot.text),
      secondaryText: color(ThemeSlot.secondaryText),
      hairline: color(ThemeSlot.hairline),
      selection: color(ThemeSlot.selection),
      online: color(ThemeSlot.online),
      offline: color(ThemeSlot.offline),
      connecting: color(ThemeSlot.connecting),
      unknown: color(ThemeSlot.unknown),
      terminal: style.hasTerminal
          ? ThemeTerminalColors.fromJson(json['terminal'])
          : null,
      fontFamily: family is String ? family : null,
      cornerScale: corners is num ? corners.toDouble() : fallback.cornerScale,
    );
    return named ? palette : presets.relabel(palette);
  }

  /// The palette a settings file holds under its key: the initial preset
  /// when it holds nothing usable, which includes a map that names none
  /// of a palette's values. Never throws — a theme is not worth a failed
  /// launch.
  ThemePalette decodeStored(Object? json) {
    final presets = GhostThemePresets(style);
    if (json is! Map || !json.keys.any(_valueKeys.contains)) {
      return presets.initial;
    }
    try {
      return fromJson(json.cast<String, Object?>());
    } catch (_) {
      // Nothing under fromJson throws today; this keeps the promise if
      // something there ever does.
      return presets.initial;
    }
  }

  /// A palette from text someone pasted, or null when the text is not a
  /// theme at all: not JSON, not an object, or an object that names none
  /// of a palette's keys. Past that it is as lenient as [fromJson], so a
  /// theme from a newer build, or one trimmed by hand, still pastes.
  ///
  /// The `terminal` key counts as a value only where
  /// [GhostThemeStyle.hasTerminal]: a clipboard holding nothing but that
  /// block is a theme for Séance and not for an app without a themed
  /// terminal, the behavioral difference the flag exists to keep.
  ThemePalette? tryParse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || !decoded.keys.any(_valueKeys.contains)) {
      return null;
    }
    return decodeStored(decoded);
  }

  /// Every key but `name`: a name alone says nothing about how anything
  /// looks, and `{"name": "x"}` is more likely a stray clipboard than a
  /// theme. `terminal` is left out where the host has none, so a block
  /// holding only it changes nothing.
  Set<String> get _valueKeys => {
    'accent',
    for (final slot in ThemeSlot.values) slot.name,
    if (style.hasTerminal) 'terminal',
    'fontFamily',
    'cornerScale',
  };
}
