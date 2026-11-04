import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

void main() {
  test('menu tokens copy and blend their optional indicator', () {
    const first = GhostMenuThemeTokens(indicator: Color(0xFF102030));
    const second = GhostMenuThemeTokens(indicator: Color(0xFF506070));

    expect(first.copyWith().indicator, first.indicator);
    expect(
      first.copyWith(indicator: const Color(0xFFABCDEF)).indicator,
      const Color(0xFFABCDEF),
    );
    expect(
      first.lerp(second, 0.5).indicator,
      Color.lerp(first.indicator, second.indicator, 0.5),
    );
    expect(const GhostMenuThemeTokens().indicator, isNull);
  });

  testWidgets('menu item icons use the host indicator with old fallback', (
    tester,
  ) async {
    const primary = Color(0xFF112233);
    const indicator = Color(0xFFCCDDEE);

    Future<void> pump({GhostMenuThemeTokens? tokens}) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: primary,
          ).copyWith(primary: primary),
          extensions: [?tokens],
        ),
        home: Scaffold(
          body: PopupMenuButton<void>(
            itemBuilder: (context) => [
              GhostMenuItem<void>(
                context: context,
                label: 'Open',
                icon: Icons.folder_open,
              ),
            ],
          ),
        ),
      ),
    );

    await pump();
    await tester.tap(find.byType(PopupMenuButton<void>));
    await tester.pumpAndSettle();
    expect(tester.widget<Icon>(find.byIcon(Icons.folder_open)).color, primary);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await pump(tokens: const GhostMenuThemeTokens(indicator: indicator));
    await tester.tap(find.byType(PopupMenuButton<void>));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.folder_open)).color,
      indicator,
    );
  });

  test('desktop menu panels remain rounded in square-corner themes', () {
    final base = ThemeData(platform: TargetPlatform.macOS);
    final square = GhostMenuTheme.apply(base, cornerScale: 0);
    expect(
      square.popupMenuTheme.shape,
      const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    );
    expect(
      square.menuTheme.style!.shape!.resolve({}),
      square.popupMenuTheme.shape,
    );

    final rounded = GhostMenuTheme.apply(base, cornerScale: 1.4);
    expect(
      rounded.popupMenuTheme.shape,
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(11.2)),
    );
    expect(
      GhostMenuTheme.apply(rounded).popupMenuTheme.shape,
      rounded.popupMenuTheme.shape,
    );
  });

  test('touch themes retain their own component sizing and corners', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      final base = ThemeData(platform: platform);
      expect(GhostMenuTheme.apply(base, cornerScale: 0), same(base));
    }
  });
}
