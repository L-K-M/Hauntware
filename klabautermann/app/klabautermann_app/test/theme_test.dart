import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show
        FamilyPalette,
        GhostFileTheme,
        SidebarDotStyle,
        SidebarRow,
        SidebarStatusDot,
        SidebarThemeTokens,
        compositeOver,
        contrastRatio;
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/fleet_rail.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';

const _textContrast = 4.5; // WCAG AA body text
const _indicatorContrast = 3.0; // WCAG non-text contrast
const _desktopMenuRowExtent = 26.0; // GhostMenuTheme's compact row

ThemeData _brandTheme(Brightness brightness, TargetPlatform platform) {
  return brightness == Brightness.dark
      ? GhostTheme.dark(klabautermannThemeStyle, platform: platform)
      : GhostTheme.light(klabautermannThemeStyle, platform: platform);
}

/// 03 D9 and §10.9: the light and dark themes are built through
/// ghost_theme and install the extensions the shared widgets read.
void main() {
  testWidgets('the app installs the shared extensions in both themes', (
    tester,
  ) async {
    await pumpApp(tester);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final themes = {
      Brightness.light: app.theme!,
      Brightness.dark: app.darkTheme!,
    };
    for (final MapEntry(key: brightness, value: theme) in themes.entries) {
      expect(theme.brightness, brightness);
      final chrome = theme.extension<GhostChrome>();
      final tokens = theme.extension<SidebarThemeTokens>();
      expect(chrome, isNotNull, reason: '${brightness.name} GhostChrome');
      expect(tokens, isNotNull, reason: '${brightness.name} sidebar tokens');
      expect(
        theme.extension<FamilyPalette>(),
        isNotNull,
        reason: '${brightness.name} family palette',
      );
      expect(
        theme.extension<GhostFileTheme>(),
        isNotNull,
        reason: '${brightness.name} file theme',
      );
      // The sidebar kit paints the same rail the chrome describes.
      expect(tokens!.sidebarBackground, chrome!.sidebarBackground);
      // Drawn from Klabautermann's style in its brand preset.
      expect(
        theme.colorScheme,
        _brandTheme(brightness, defaultTargetPlatform).colorScheme,
      );
    }
  });

  testWidgets('the app starts in the brand preset, following the system', (
    tester,
  ) async {
    final harness = await pumpApp(tester);

    final value = harness.appearance.value;
    expect(value.palette, klabautermannThemePresets.brand);
    expect(value.palette.name, 'Klabautermann');
    expect(value.mode, ThemeModePreference.system);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      final label = '${brightness.name}, ${platform.name}';

      test('the pointer-menu skin follows the platform ($label)', () {
        final theme = _brandTheme(brightness, platform);
        final minimum = theme.menuButtonTheme.style?.minimumSize?.resolve({});
        if (isGhostDesktopPlatform(platform)) {
          expect(minimum?.height, _desktopMenuRowExtent);
        } else {
          expect(minimum, isNull);
        }
      });

      test('the brand tables keep their text contrast ($label)', () {
        final theme = _brandTheme(brightness, platform);
        final scheme = theme.colorScheme;
        final chrome = theme.extension<GhostChrome>()!;
        final pairs = {
          'primary on the surface': (scheme.primary, scheme.surface),
          'primary on the rail': (scheme.primary, chrome.sidebarBackground),
          'onPrimary on primary': (scheme.onPrimary, scheme.primary),
          'onPrimaryContainer on primaryContainer': (
            scheme.onPrimaryContainer,
            scheme.primaryContainer,
          ),
          'the selection label on its pill': (
            chrome.onSelection,
            chrome.selectionFill,
          ),
        };
        for (final MapEntry(key: name, value: (fore, back)) in pairs.entries) {
          expect(
            contrastRatio(fore, back),
            greaterThanOrEqualTo(_textContrast),
            reason: '$name: $fore on $back',
          );
        }
      });

      // The fleet rows' dot sits on the rail, its hover fill and the
      // inactive selection pill, and on the phone list's page surface.
      test('the status dots clear the indicator floor ($label)', () {
        final theme = _brandTheme(brightness, platform);
        final chrome = theme.extension<GhostChrome>()!;
        final page = theme.colorScheme.surface;
        final rail = chrome.sidebarBackground;
        final surfaces = {
          'rail': rail,
          'rail hover': compositeOver(chrome.hoverFill, rail),
          'rail selection pill': compositeOver(
            chrome.inactiveSelectionFill,
            rail,
          ),
          'page': page,
          'page hover': compositeOver(chrome.hoverFill, page),
          'page selection pill': compositeOver(
            chrome.inactiveSelectionFill,
            page,
          ),
        };
        final dots = {
          'connected': chrome.statusConnected,
          'connecting': chrome.statusConnecting,
          'failed': chrome.statusFailed,
          'unknown': chrome.statusUnknown,
        };
        for (final MapEntry(key: dotName, value: dot) in dots.entries) {
          for (final MapEntry(key: name, value: surface) in surfaces.entries) {
            expect(
              contrastRatio(dot, surface),
              greaterThanOrEqualTo(_indicatorContrast),
              reason: '$dotName $dot on the $name ($surface)',
            );
          }
        }
      });
    }
  }

  testWidgets('a fleet row paints its dot from the theme chrome', (
    tester,
  ) async {
    final harness = await pumpApp(tester, servers: twoServers);
    final chrome = Theme.of(
      tester.element(find.byType(FleetServerRow).first),
    ).extension<GhostChrome>()!;

    SidebarStatusDot? dotOf(String title) {
      final row = find.widgetWithText(SidebarRow, title);
      return tester.widget<SidebarRow>(row).status;
    }

    // Nothing observed yet paints no dot; the label carries the word.
    expect(dotOf('web-1'), isNull);

    final connected = SidebarStatusDot(chrome.statusConnected);
    final connecting = SidebarStatusDot(chrome.statusConnecting);
    final failed = SidebarStatusDot(chrome.statusFailed);
    final blocked = SidebarStatusDot(
      chrome.statusFailed,
      style: SidebarDotStyle.blocked,
    );
    final dots = <LinkStatus, SidebarStatusDot?>{
      const LinkConnecting(): connecting,
      const LinkAuthenticating(): connecting,
      const LinkReady(): connected,
      const LinkDegraded(LinkDegradedReason.sessionLimitLearned): connected,
      LinkBackoff(DateTime.utc(2026)): connecting,
      const LinkNeedsUser(promptId: 'p-1', kind: PromptKind.credential):
          blocked,
      const LinkBlocked(LinkBlockedReason.endpointChanged): blocked,
      const LinkClosed(LinkClosedReason.pingTimeout): failed,
      const LinkClosed(
        LinkClosedReason.connectFailed,
        failure: LinkFailureKind.unreachable,
      ): failed,
      // A link closed on purpose is no failure: no dot, like idle.
      const LinkClosed(LinkClosedReason.closedByOwner): null,
      const LinkIdle(): null,
    };
    for (final MapEntry(key: status, value: dot) in dots.entries) {
      harness.engine.emit(LinkState('srv-1', status));
      await tester.pumpAndSettle();
      expect(dotOf('web-1'), dot, reason: '$status');
    }
  });

  group('AppearanceController', () {
    test('a mode change keeps the palette and notifies once', () async {
      final controller = AppearanceController();
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final palette = controller.value.palette;

      await controller.setMode(ThemeModePreference.dark);
      expect(controller.value.mode, ThemeModePreference.dark);
      expect(controller.value.palette, palette);
      expect(notifications, 1);

      // Picking the mode already in force is not a change.
      await controller.setMode(ThemeModePreference.dark);
      expect(notifications, 1);
    });

    test('starts in the stored appearance and saves each change', () async {
      final saved = <AppAppearance>[];
      final controller = AppearanceController(
        initial: AppAppearance(
          palette: klabautermannThemePresets.initial,
          mode: ThemeModePreference.light,
        ),
        save: (appearance) async => saved.add(appearance),
      );
      addTearDown(controller.dispose);
      expect(controller.mode, ThemeModePreference.light);

      await controller.setMode(ThemeModePreference.dark);
      await controller.setMode(ThemeModePreference.dark);

      expect(saved, [controller.value], reason: 'a no-op saves nothing');
    });

    test('a failed save keeps the change and says it was not saved', () async {
      final controller = AppearanceController(
        save: (_) async => throw const FileSystemException('disk full'),
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.setMode(ThemeModePreference.dark),
        throwsA(
          isA<AppearanceNotSavedException>().having(
            (error) => error.message,
            'message',
            contains('disk full'),
          ),
        ),
      );
      expect(controller.mode, ThemeModePreference.dark);
    });
  });
}
