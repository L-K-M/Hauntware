import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

/// The seam contract: the fallback is the shared slate/Finder neutrals
/// both apps' chrome defaults resolved to (so a theme carrying no
/// extension draws unchanged), and the extension wins when a host
/// installs one.
void main() {
  group('fallback', () {
    test('dark desktop is the shared slate rail', () {
      final tokens = SidebarThemeTokens.fallback(
        Brightness.dark,
        TargetPlatform.macOS,
      );
      expect(tokens.sidebarBackground, const Color(0xFF2A313B));
      expect(tokens.separator, const Color(0xFF3A424E));
      expect(tokens.hoverFill, const Color(0xFFE7EAEF).withValues(alpha: 0.06));
      expect(tokens.capsuleFill, const Color(0xFF353D49));
      expect(tokens.inactiveSelectionFill, const Color(0xFF3B4452));
      expect(tokens.secondaryText, const Color(0xFFB4BCC8));
      expect(tokens.sidebarRowExtent, 26);
      expect(tokens.cornerScale, 1);
    });

    test('light desktop is the Finder greys', () {
      final tokens = SidebarThemeTokens.fallback(
        Brightness.light,
        TargetPlatform.linux,
      );
      expect(tokens.sidebarBackground, const Color(0xFFF1F2F4));
      expect(tokens.separator, const Color(0xFFDADDE3));
      expect(tokens.hoverFill, const Color(0xFF1C1F24).withValues(alpha: 0.06));
      expect(tokens.capsuleFill, const Color(0xFFEBECEF));
      expect(tokens.inactiveSelectionFill, const Color(0xFFE2E5EA));
      expect(tokens.secondaryText, const Color(0xFF596170));
      expect(tokens.sidebarRowExtent, 26);
    });

    test('a touch platform gets the 40 px compact row', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        expect(
          SidebarThemeTokens.fallback(
            Brightness.light,
            platform,
          ).sidebarRowExtent,
          40,
          reason: platform.name,
        );
      }
    });
  });

  test('corner scales a base radius by cornerScale', () {
    const tokens = SidebarThemeTokens(
      sidebarBackground: Color(0xFF000000),
      separator: Color(0xFF000000),
      hoverFill: Color(0xFF000000),
      capsuleFill: Color(0xFF000000),
      inactiveSelectionFill: Color(0xFF000000),
      secondaryText: Color(0xFF000000),
      sidebarRowExtent: 26,
      cornerScale: 1.4,
    );
    expect(tokens.corner(6), moreOrLessEquals(8.4, epsilon: 1e-9));
    expect(
      const SidebarThemeTokens(
        sidebarBackground: Color(0xFF000000),
        separator: Color(0xFF000000),
        hoverFill: Color(0xFF000000),
        capsuleFill: Color(0xFF000000),
        inactiveSelectionFill: Color(0xFF000000),
        secondaryText: Color(0xFF000000),
        sidebarRowExtent: 26,
      ).corner(6),
      6,
    );
  });

  test('lerp blends the colours and the extents', () {
    final a = SidebarThemeTokens.fallback(
      Brightness.light,
      TargetPlatform.macOS,
    );
    final b = SidebarThemeTokens.fallback(
      Brightness.dark,
      TargetPlatform.macOS,
    );
    final mid = a.lerp(b, 0.5);
    expect(
      mid.sidebarBackground,
      Color.lerp(a.sidebarBackground, b.sidebarBackground, 0.5),
    );
    expect(mid.sidebarRowExtent, (a.sidebarRowExtent + b.sidebarRowExtent) / 2);
    expect(a.lerp(null, 0.5), same(a));
  });

  testWidgets('of resolves the installed extension, else the fallback', (
    tester,
  ) async {
    const installed = SidebarThemeTokens(
      sidebarBackground: Color(0xFF112233),
      separator: Color(0xFF112233),
      hoverFill: Color(0xFF112233),
      capsuleFill: Color(0xFF112233),
      inactiveSelectionFill: Color(0xFF112233),
      secondaryText: Color(0xFF112233),
      sidebarRowExtent: 30,
      cornerScale: 2,
    );
    SidebarThemeTokens? seen;
    Widget host(ThemeData theme) => Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          seen = SidebarThemeTokens.of(context);
          return const SizedBox();
        },
      ),
    );

    // The host-adapter shape: the app's resolved chrome copied
    // field-for-field onto the shared extension.
    await tester.pumpWidget(
      host(
        ThemeData(
          brightness: Brightness.light,
          platform: TargetPlatform.macOS,
          extensions: const [installed],
        ),
      ),
    );
    expect(seen, same(installed));

    // No extension: the brightness/platform the theme reports.
    await tester.pumpWidget(
      host(
        ThemeData(
          brightness: Brightness.dark,
          platform: TargetPlatform.android,
        ),
      ),
    );
    expect(
      seen!.sidebarBackground,
      SidebarThemeTokens.fallback(
        Brightness.dark,
        TargetPlatform.android,
      ).sidebarBackground,
    );
    expect(seen!.sidebarRowExtent, 40);
  });
}
