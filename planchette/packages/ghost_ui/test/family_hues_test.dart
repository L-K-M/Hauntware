// Ported from Poltergeist
// app/poltergeist_app/test/ui/family_hues_test.dart, pared to what the
// shared package owns: the surfaces under test are the shared chrome
// defaults ([SidebarThemeTokens.fallback]) plus the rest of the sibling
// neutral table the apps draw glyphs on; the app-specific surfaces (the
// inspector's own wash) stay covered in the hosts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

/// 02 §13's non-text floor the family hues are held to.
const double _minimumNonTextContrast = 3.0;

/// The shared neutral table both sibling themes resolve their chrome
/// from: the surfaces a family glyph can sit on.
final _surfaces = <Brightness, List<(String, Color)>>{
  Brightness.dark: [
    ('listing', const Color(0xFF232932)),
    ('sidebar', const Color(0xFF2A313B)),
    ('header', const Color(0xFF2D3440)),
    ('inspector', const Color(0xFF2A313B)),
    ('toolbar capsule', const Color(0xFF353D49)),
  ],
  Brightness.light: [
    ('listing', const Color(0xFFFFFFFF)),
    ('sidebar', const Color(0xFFF1F2F4)),
    ('header', const Color(0xFFF6F6F8)),
    ('inspector', const Color(0xFFF1F2F4)),
    ('toolbar capsule', const Color(0xFFEBECEF)),
  ],
};

void main() {
  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      final tokens = SidebarThemeTokens.fallback(
        brightness,
        TargetPlatform.macOS,
      );
      final palette = FamilyPalette.forBrightness(brightness);

      test('every glyph hue stays ≥ 3:1 on every chrome surface', () {
        final states = <(String, Color)>[
          for (final (name, surface) in _surfaces[brightness]!) ...[
            (name, surface),
            ('$name hovered', Color.alphaBlend(tokens.hoverFill, surface)),
            (
              '$name neutral selection',
              Color.alphaBlend(tokens.inactiveSelectionFill, surface),
            ),
          ],
        ];
        for (final hue in FamilyHue.values) {
          for (final (state, surface) in states) {
            expect(
              contrastRatio(palette.glyph(hue), surface),
              greaterThanOrEqualTo(_minimumNonTextContrast),
              reason: '${hue.name} glyph on $state (${brightness.name})',
            );
          }
        }
      });

      test('a hue\'s glyph stays ≥ 3:1 on a wash of its own colour', () {
        // A phone listing's kind badge and a Home row's mark sit their
        // glyph on a disc of the hue's own tint.
        for (final hue in FamilyHue.values) {
          final glyph = palette.glyph(hue);
          for (final (name, surface) in _surfaces[brightness]!) {
            final wash = Color.alphaBlend(
              glyph.withValues(alpha: FamilyPalette.discWashAlpha),
              surface,
            );
            expect(
              contrastRatio(glyph, wash),
              greaterThanOrEqualTo(_minimumNonTextContrast),
              reason: '${hue.name} on its $name disc (${brightness.name})',
            );
          }
        }
      });

      test('graphite is the neutrals\' secondary text', () {
        expect(palette.glyph(FamilyHue.graphite), tokens.secondaryText);
      });

      test('FamilyPalette.of falls back to the theme\'s brightness', () {
        expect(
          FamilyPalette.forBrightness(brightness).glyph(FamilyHue.blue),
          palette.glyph(FamilyHue.blue),
        );
      });
    });
  }

  test('every tile glyph stays ≥ 3:1 on both ends of its fill', () {
    for (final hue in FamilyHue.values) {
      for (final (end, fill) in [
        ('sheen', hue.tileSheen),
        ('fill', hue.tileFill),
      ]) {
        expect(
          contrastRatio(hue.onTile, fill),
          greaterThanOrEqualTo(_minimumNonTextContrast),
          reason: '${hue.name} tile glyph on its $end',
        );
      }
    }
  });

  testWidgets('a tile paints its glyph in the on-tile colour', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: FamilyHueTile(
            hue: FamilyHue.blue,
            glyph: Icons.home,
            extent: 32,
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(FamilyHueTile)), const Size(32, 32));
    final icon = tester.widget<Icon>(find.byIcon(Icons.home));
    expect(icon.color, FamilyHue.blue.onTile);
    expect(icon.size, 20);
  });

  testWidgets('FamilyPalette.of resolves the extension else its '
      'brightness\'s defaults', (tester) async {
    FamilyPalette? seen;
    Widget host(ThemeData theme) => Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          seen = FamilyPalette.of(context);
          return const SizedBox();
        },
      ),
    );

    await tester.pumpWidget(host(ThemeData(brightness: Brightness.light)));
    expect(seen, same(FamilyPalette.light));
    await tester.pumpWidget(host(ThemeData(brightness: Brightness.dark)));
    expect(seen, same(FamilyPalette.dark));
    await tester.pumpWidget(
      host(
        ThemeData(
          brightness: Brightness.light,
          extensions: const [FamilyPalette.dark],
        ),
      ),
    );
    expect(seen, same(FamilyPalette.dark));
  });
}
