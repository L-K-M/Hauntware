import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:klabautermann_app/app_identity.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/ui/menus/app_commands.dart';
import 'package:klabautermann_app/ui/menus/app_menu_host.dart';
import 'package:klabautermann_app/ui/menus/app_menus.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/fake_ssh_config.dart';
import 'support/harness.dart';

const _config = 'Host web-1\n  HostName web-1.example\n';
const _version = '1.2.3';
const _licence =
    "Klabautermann's own code is public domain (Unlicense). It includes "
    'third-party components that keep their own licenses, listed under View '
    'licenses.';
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
      appVersion: _version,
      requestClose: requestClose,
    );

    List<String> ids(List<AppCommand> commands) => [
      for (final command in commands) command.id,
    ];

    test('holds only commands with a real action on each platform', () {
      expect(ids(commands(TargetPlatform.macOS)), [
        kAppAboutCommandId,
        kFleetImportSshConfigCommandId,
        kAppSettingsCommandId,
      ]);
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        expect(ids(commands(platform)), [
          kAppAboutCommandId,
          kFleetImportSshConfigCommandId,
          kAppSettingsCommandId,
          kAppQuitCommandId,
        ], reason: '$platform');
      }
      // Without an ssh_config source (phones) there is nothing to import,
      // and no About: phones reach the dialog from Settings > General.
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        expect(ids(commands(platform, on: fleet())), [
          kAppSettingsCommandId,
        ], reason: '$platform');
      }
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
      engine.emit(
        const SshConfigImported(importedCount: 1, skippedCount: 0, saved: true),
      );
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

        expect(titles(menus), [
          'Klabautermann $kPreviewLabel',
          'File',
          'View',
          'Window',
        ]);
        // The app's own About leads, in place of AppKit's panel, which
        // shows CFBundleName without the preview label (M16).
        expect(rows(menus[0]), [
          ['About Klabautermann'],
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
        expect([
          for (final menu in menus) ...rows(menu).expand((group) => group),
        ], isNot(contains(PlatformProvidedMenuItemType.about)));
      });

      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        test('${platform.name}: File, with Settings… and Quit in its last '
            'section, Help with About, and no AppKit rows', () {
          final menus = buildAppMenus(
            commands: commands(platform),
            l10n: l10n,
            platform: platform,
          );

          expect(titles(menus), ['File', 'Help']);
          expect(rows(menus[0]), [
            ['Import from ~/.ssh/config'],
            ['Settings…', 'Quit'],
          ]);
          expect(rows(menus[1]), [
            ['About Klabautermann'],
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
        ).first;
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

    testWidgets(
      'Linux and Windows: Help ▸ About shows the version, the licence and '
      'the preview label',
      (tester) async {
        await pumpApp(
          tester,
          sshConfig: FakeSshConfigSource.text(_config),
          appVersion: _version,
        );

        await tester.tap(find.text('Help'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('About Klabautermann'));
        await tester.pumpAndSettle();

        _expectAboutDialog(version: 'Version $_version');
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.linux,
        TargetPlatform.windows,
      }),
    );

    testWidgets('About says so when the version is unknown', (tester) async {
      await pumpApp(tester, sshConfig: FakeSshConfigSource.text(_config));

      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Klabautermann'));
      await tester.pumpAndSettle();

      _expectAboutDialog(version: 'Version unknown');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

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
        [
          'Klabautermann $kPreviewLabel',
          'File',
          'Edit',
          'View',
          'Window',
          'Help',
        ],
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

    testWidgets('macOS: About Klabautermann opens the app\'s About dialog, '
        'not AppKit\'s panel', (tester) async {
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
      await pumpApp(
        tester,
        sshConfig: FakeSshConfigSource.text(_config),
        appVersion: _version,
      );

      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      // AppKit gets no About row of its own to show.
      expect(
        _providedTypes(bar.menus),
        isNot(contains(PlatformProvidedMenuItemType.about)),
      );
      _item(bar, 'About Klabautermann').onSelected!();
      await tester.pumpAndSettle();

      _expectAboutDialog(version: 'Version $_version');
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
        const SshConfigImported(importedCount: 1, skippedCount: 0, saved: true),
      );
      await tester.pumpAndSettle();
      expect(importItem().onSelected, isNotNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a disabled command never runs from its shortcut', (
      tester,
    ) async {
      // No registered command is both disableable and bound to a chord
      // yet, so the host's own check is all that stands between a chord
      // and a disabled command.
      final runs = <String>[];
      AppCommand command(
        String id,
        LogicalKeyboardKey key, {
        required bool enabled,
        required int order,
      }) => AppCommand(
        id: id,
        label: (_) => id,
        menuPlacement: CommandMenuPlacement(menu: AppMenuId.file, order: order),
        enabled: () => enabled,
        activators: (_) => [SingleActivator(key, control: true)],
        run: (_) async => runs.add(id),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppMenuHost(
            commands: [
              command(
                'test.disabled',
                LogicalKeyboardKey.keyK,
                enabled: false,
                order: 0,
              ),
              command(
                'test.enabled',
                LogicalKeyboardKey.keyJ,
                enabled: true,
                order: 10,
              ),
            ],
            child: const SizedBox.expand(),
          ),
        ),
      );

      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      await press(LogicalKeyboardKey.keyK);
      await press(LogicalKeyboardKey.keyJ);

      // The enabled command shows the chords reach the host.
      expect(runs, ['test.enabled']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

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

/// Every AppKit-provided row anywhere in [items].
List<PlatformProvidedMenuItemType> _providedTypes(
  List<PlatformMenuItem> items,
) => [
  for (final item in items)
    ...switch (item) {
      PlatformProvidedMenuItem(:final type) => [type],
      PlatformMenu(:final menus) => _providedTypes(menus),
      PlatformMenuItemGroup(:final members) => _providedTypes(members),
      _ => const <PlatformProvidedMenuItemType>[],
    },
];

/// The About dialog (M16) is showing, with the app title's preview label,
/// [version] and the licence.
void _expectAboutDialog({required String version}) {
  expect(find.byType(AboutDialog), findsOneWidget);
  final dialog = find.descendant(
    of: find.byType(AboutDialog),
    matching: find.byType(Text),
  );
  final texts = [
    for (final element in dialog.evaluate())
      (element.widget as Text).data ?? '',
  ];
  expect(
    texts,
    containsAll(['Klabautermann $kPreviewLabel', version, _licence]),
  );
}

/// Quit never reads its context.
final class _NoContext extends Fake implements BuildContext {}
