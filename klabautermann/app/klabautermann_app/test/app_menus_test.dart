import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/ui/menus/app_commands.dart';
import 'package:klabautermann_app/ui/menus/app_menus.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/fake_ssh_config.dart';
import 'support/harness.dart';

const _config = 'Host web-1\n  HostName web-1.example\n';
const _desktopPlatforms = [
  TargetPlatform.macOS,
  TargetPlatform.linux,
  TargetPlatform.windows,
];

/// The menus of 03 §10.2 from one command registry: which commands exist
/// where, how they render on each platform, their enablement and
/// shortcuts, and that a menu row and its shortcut run the same command.
void main() {
  final l10n = AppLocalizationsEn();

  group('the registry', () {
    late FakeEngineClient engine;

    setUp(() => engine = FakeEngineClient());
    tearDown(() => engine.close());

    FleetController fleet({FakeSshConfigSource? sshConfig}) {
      final controller = FleetController(engine, sshConfig: sshConfig);
      addTearDown(controller.dispose);
      return controller;
    }

    List<AppCommand> commands(
      TargetPlatform platform, {
      FleetController? on,
      VoidCallback? onOpenSettings,
      Future<void> Function()? requestClose,
    }) => buildAppCommands(
      platform: platform,
      fleet: on ?? fleet(sshConfig: FakeSshConfigSource.text(_config)),
      onOpenSettings: onOpenSettings ?? () {},
      requestClose: requestClose,
    );

    List<String> ids(List<AppCommand> commands) => [
      for (final command in commands) command.id,
    ];

    test('holds only commands with a real action on each platform', () {
      expect(ids(commands(TargetPlatform.macOS)), [
        kFleetImportSshConfigCommandId,
        kAppSettingsCommandId,
      ]);
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        expect(ids(commands(platform)), [
          kFleetImportSshConfigCommandId,
          kAppSettingsCommandId,
          kAppQuitCommandId,
        ], reason: '$platform');
      }
      // Without an ssh_config source (phones) there is nothing to import.
      expect(ids(commands(TargetPlatform.android, on: fleet())), [
        kAppSettingsCommandId,
      ]);
    });

    test('Settings… takes ⌘, on macOS and Ctrl+, elsewhere', () {
      AppCommand settings(TargetPlatform platform) => commands(
        platform,
      ).singleWhere((command) => command.id == kAppSettingsCommandId);

      final mac = settings(
        TargetPlatform.macOS,
      ).activators(TargetPlatform.macOS);
      expect(mac, hasLength(1));
      expect(formatShortcutActivator(mac.single, TargetPlatform.macOS), '⌘,');
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        final keys = settings(platform).activators(platform);
        expect(keys, hasLength(1));
        expect(formatShortcutActivator(keys.single, platform), 'Ctrl+,');
      }
    });

    test('binds no shortcut twice, nor one the platform or the settings '
        'window already owns', () {
      SingleActivator meta(LogicalKeyboardKey key, {bool shift = false}) =>
          SingleActivator(key, meta: true, shift: shift);
      // AppKit's own rows (Quit, Hide, Hide Others, Minimize, Full Screen)
      // and the settings window's ⌘W and ⌘⇧W.
      final reserved = {
        TargetPlatform.macOS: [
          meta(LogicalKeyboardKey.keyQ),
          meta(LogicalKeyboardKey.keyH),
          const SingleActivator(LogicalKeyboardKey.keyH, meta: true, alt: true),
          meta(LogicalKeyboardKey.keyM),
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            meta: true,
            control: true,
          ),
          meta(LogicalKeyboardKey.keyW),
          meta(LogicalKeyboardKey.keyW, shift: true),
        ],
      };
      for (final platform in _desktopPlatforms) {
        final spelled = [
          for (final command in commands(platform))
            for (final key in command.activators(platform))
              formatShortcutActivator(key, platform),
        ];
        expect(spelled.toSet(), hasLength(spelled.length), reason: '$platform');
        for (final key in reserved[platform] ?? const <SingleActivator>[]) {
          expect(
            spelled,
            isNot(contains(formatShortcutActivator(key, platform))),
            reason: '$platform ${formatShortcutActivator(key, platform)}',
          );
        }
      }
    });

    test('the import is disabled while one runs', () async {
      final source = FakeSshConfigSource.text(_config)
        ..gate = Completer<void>();
      final controller = fleet(sshConfig: source);
      final import = commands(
        TargetPlatform.linux,
        on: controller,
      ).singleWhere((command) => command.id == kFleetImportSshConfigCommandId);
      expect(import.enabled(), isTrue);

      final running = controller.importSshConfig();
      await Future<void>.delayed(Duration.zero);
      expect(import.enabled(), isFalse);

      source.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      engine.emit(const SshConfigImported(importedCount: 1, skippedCount: 0));
      await running;
      expect(import.enabled(), isTrue);
    });

    test('Quit asks the window to close, the close button\'s path', () async {
      var closes = 0;
      final quit = commands(
        TargetPlatform.linux,
        requestClose: () async => closes++,
      ).singleWhere((command) => command.id == kAppQuitCommandId);

      await quit.run(_NoContext());

      expect(closes, 1);
    });

    group('rendered as menus', () {
      List<String> titles(List<GhostMenu> menus) => [
        for (final menu in menus) menu.title,
      ];
      List<List<Object>> rows(GhostMenu menu) => [
        for (final group in menu.groups)
          [
            for (final row in group)
              switch (row) {
                GhostCommandRow(:final command) => command.label,
                GhostProvidedRow(:final type) => type,
                GhostSubmenuRow(:final title) => title,
              },
          ],
      ];

      test('macOS: the application menu in AppKit\'s order, File, and the '
          'View and Window menus with AppKit\'s rows', () {
        final menus = buildAppMenus(
          commands: commands(TargetPlatform.macOS),
          l10n: l10n,
          platform: TargetPlatform.macOS,
        );

        expect(titles(menus), ['Klabautermann', 'File', 'View', 'Window']);
        expect(rows(menus[0]), [
          [PlatformProvidedMenuItemType.about],
          ['Settings…'],
          [PlatformProvidedMenuItemType.servicesSubmenu],
          [
            PlatformProvidedMenuItemType.hide,
            PlatformProvidedMenuItemType.hideOtherApplications,
            PlatformProvidedMenuItemType.showAllApplications,
          ],
          [PlatformProvidedMenuItemType.quit],
        ]);
        expect(rows(menus[1]), [
          ['Import from ~/.ssh/config'],
        ]);
        expect(rows(menus[2]), [
          [PlatformProvidedMenuItemType.toggleFullScreen],
        ]);
        expect(rows(menus[3]), [
          [
            PlatformProvidedMenuItemType.minimizeWindow,
            PlatformProvidedMenuItemType.zoomWindow,
          ],
          [PlatformProvidedMenuItemType.arrangeWindowsInFront],
        ]);
      });

      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        test('${platform.name}: one File menu, with Settings… and Quit in '
            'its last section and no AppKit rows', () {
          final menus = buildAppMenus(
            commands: commands(platform),
            l10n: l10n,
            platform: platform,
          );

          expect(titles(menus), ['File']);
          expect(rows(menus.single), [
            ['Import from ~/.ssh/config'],
            ['Settings…', 'Quit'],
          ]);
        });
      }

      test('a row carries its enablement and its shortcuts', () async {
        final source = FakeSshConfigSource.text(_config)
          ..gate = Completer<void>();
        final controller = fleet(sshConfig: source);
        unawaited(controller.importSshConfig());
        await Future<void>.delayed(Duration.zero);

        final file = buildAppMenus(
          commands: commands(TargetPlatform.linux, on: controller),
          l10n: l10n,
          platform: TargetPlatform.linux,
        ).single;
        final specs = [
          for (final group in file.groups)
            for (final row in group) (row as GhostCommandRow).command,
        ];

        expect(specs.first.id, kFleetImportSshConfigCommandId);
        expect(specs.first.enabled, isFalse);
        expect(specs.first.activators, isEmpty);
        expect(specs[1].id, kAppSettingsCommandId);
        expect(specs[1].enabled, isTrue);
        expect(specs[1].activators, hasLength(1));

        source.gate!.complete();
      });
    });
  });

  group('in the app', () {
    Future<List<SettingsTab>> pumpDesktop(
      WidgetTester tester, {
      List<FleetServer> servers = const [],
    }) async {
      final opened = <SettingsTab>[];
      await pumpApp(
        tester,
        servers: servers,
        sshConfig: FakeSshConfigSource.text(_config),
        openSettingsWindow: (tab) async {
          opened.add(tab);
          return true;
        },
      );
      return opened;
    }

    testWidgets(
      'Linux and Windows: a File menu strip whose rows run their commands',
      (tester) async {
        final opened = await pumpDesktop(tester);

        expect(find.byType(MenuBar), findsOneWidget);
        expect(find.byType(PlatformMenuBar), findsNothing);
        await tester.tap(find.text('File'));
        await tester.pumpAndSettle();

        expect(find.text('Import from ~/.ssh/config'), findsOneWidget);
        expect(find.text('Quit'), findsOneWidget);
        // The row's hint is its shortcut's spelling.
        expect(find.text('Ctrl+,'), findsOneWidget);

        await tester.tap(find.text('Settings…'));
        await tester.pumpAndSettle();
        expect(opened, [SettingsTab.general]);
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.linux,
        TargetPlatform.windows,
      }),
    );

    testWidgets('Linux and Windows: the import row runs the FL-02 import', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        sshConfig: FakeSshConfigSource.text(_config),
      );

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from ~/.ssh/config'));
      await tester.pumpAndSettle();

      final request = harness.engine.sentOfType<ImportSshConfig>().single;
      expect((request as ImportSshConfig).text, _config);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets(
      'the shortcut runs Settings… from wherever focus is in the app',
      (tester) async {
        final opened = await pumpDesktop(tester, servers: twoServers);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(opened, [SettingsTab.general]);

        // Still bound after a row took focus.
        await tester.tap(find.text('web-1'));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(opened, [SettingsTab.general, SettingsTab.general]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets('macOS: the native menu bar, synced once per change', (
      tester,
    ) async {
      final pushes = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.menu,
        (call) async {
          if (call.method == 'Menu.setMenus') pushes.add(call.arguments);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.menu,
          null,
        ),
      );
      final opened = <SettingsTab>[];
      final harness = await pumpApp(
        tester,
        servers: twoServers,
        sshConfig: FakeSshConfigSource.text(_config),
        openSettingsWindow: (tab) async {
          opened.add(tab);
          return true;
        },
      );

      expect(find.byType(MenuBar), findsNothing);
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      expect(
        [for (final menu in bar.menus) (menu as PlatformMenu).label],
        ['Klabautermann', 'File', 'View', 'Window'],
      );
      expect('${pushes.last}', contains('Settings…'));

      final settings = _item(bar, 'Settings…');
      expect(
        settings.shortcut,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true),
      );
      settings.onSelected!();
      await tester.pumpAndSettle();
      expect(opened, [SettingsTab.general]);

      // The fleet notifies, but the menus did not change: the same items
      // stay. PlatformMenuBar re-sends once on its first update (it starts
      // with no items recorded); after that nothing is sent.
      harness.fleet.select('srv-1');
      await tester.pumpAndSettle();
      final settled = pushes.length;
      harness.fleet.select('srv-2');
      await tester.pumpAndSettle();
      final rebuilt = tester.widget<PlatformMenuBar>(
        find.byType(PlatformMenuBar),
      );
      expect(identical(rebuilt.menus, bar.menus), isTrue);
      expect(pushes, hasLength(settled));

      // ⌘, reaches the chord layer first, as the native key equivalent
      // would only after Flutter left it unhandled.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(opened, [SettingsTab.general, SettingsTab.general]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('macOS: a disabled import is a disabled native item', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.menu,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.menu,
          null,
        ),
      );
      final source = FakeSshConfigSource.text(_config)
        ..gate = Completer<void>();
      final harness = await pumpApp(tester, sshConfig: source);

      PlatformMenuItem importItem() => _item(
        tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar)),
        'Import from ~/.ssh/config',
      );
      expect(importItem().onSelected, isNotNull);

      unawaited(harness.fleet.importSshConfig());
      await tester.pump();
      expect(importItem().onSelected, isNull);

      source.gate!.complete();
      await tester.pump();
      harness.engine.emit(
        const SshConfigImported(importedCount: 1, skippedCount: 0),
      );
      await tester.pumpAndSettle();
      expect(importItem().onSelected, isNotNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets(
      'phones and tablets have no menus',
      (tester) async {
        await pumpApp(tester, servers: twoServers);

        expect(find.byType(MenuBar), findsNothing);
        expect(find.byType(PlatformMenuBar), findsNothing);
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  });
}

/// The [PlatformMenuItem] labelled [label], anywhere in [bar].
PlatformMenuItem _item(PlatformMenuBar bar, String label) {
  PlatformMenuItem? find(List<PlatformMenuItem> items) {
    for (final item in items) {
      if (item.label == label && item is! PlatformMenu) return item;
      final children = switch (item) {
        PlatformMenu(:final menus) => menus,
        PlatformMenuItemGroup(:final members) => members,
        _ => const <PlatformMenuItem>[],
      };
      final found = find(children);
      if (found != null) return found;
    }
    return null;
  }

  return find(bar.menus)!;
}

/// Quit never reads its context.
final class _NoContext extends Fake implements BuildContext {}
