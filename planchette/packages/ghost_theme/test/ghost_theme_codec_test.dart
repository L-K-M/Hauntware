import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'support/host_styles.dart';

/// The one per-app fork in the stored and pasted form: whether a palette
/// carries a `terminal` block. Both shapes are pinned here because the
/// bytes one app writes depend on the flag, and the seam exists so the two
/// apps keep the exact behaviours they had.
void main() {
  group('a host with a terminal (Séance)', () {
    test('a terminal-only clipboard is a theme', () {
      final text = jsonEncode({
        'terminal': seancePresets.solarized.terminal!.toJson(),
      });
      final palette = seanceCodec.tryParse(text);
      expect(palette, isNotNull);
      expect(palette!.terminal, seancePresets.solarized.terminal);
    });

    test('the terminal key is written only when one is set', () {
      expect(seancePresets.brand.toJson().containsKey('terminal'), isFalse);
      expect(seancePresets.paper.toJson().containsKey('terminal'), isTrue);
    });
  });

  group('a host without one (Poltergeist)', () {
    test('a terminal-only clipboard is not a theme', () {
      final text = jsonEncode({
        'terminal': seancePresets.solarized.terminal!.toJson(),
      });
      expect(poltergeistCodec.tryParse(text), isNull);
    });

    test('a Séance theme reads its palette and ignores the block', () {
      final json = seancePresets.solarized.toJson();
      expect(json.containsKey('terminal'), isTrue);
      final palette = poltergeistCodec.fromJson(json);
      expect(palette.surface, seancePresets.solarized.surface);
      expect(palette.accent, seancePresets.solarized.accent);
      expect(palette.terminal, isNull);
      expect(palette.toJson().containsKey('terminal'), isFalse);
    });

    test('its presets never carry a terminal block', () {
      for (final preset in poltergeistPresets.all) {
        expect(preset.terminal, isNull, reason: preset.name);
      }
    });
  });
}
