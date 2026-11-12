import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/menus/app_commands.dart';
import 'package:klabautermann_app/ui/menus/app_menu_host.dart';

/// 03 §8.13: the app lock covers the Flutter tree, but macOS menu items
/// and their key equivalents are native, so the menu host itself holds
/// commands back while the app is locked. The lock is a plain notifier
/// here: KlabautermannApp hands the host its controller's `locked`.
void main() {
  late List<String> runs;
  late ValueNotifier<bool> locked;

  setUp(() {
    runs = [];
    locked = ValueNotifier(true);
  });
  tearDown(() => locked.dispose());

  AppCommand command(
    String id, {
    required int order,
    List<ShortcutActivator> keys = const [],
  }) => AppCommand(
    id: id,
    label: (_) => id,
    activators: (_) => keys,
    run: (_) async => runs.add(id),
    menuPlacement: CommandMenuPlacement(menu: AppMenuId.edit, order: order),
  );

  Future<void> pump(WidgetTester tester) async {
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
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: defaultTargetPlatform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppMenuHost(
          locked: () => locked.value,
          listenable: locked,
          commands: [
            command(
              kEditUndoCommandId,
              order: 10,
              keys: [
                SingleActivator(
                  LogicalKeyboardKey.keyZ,
                  meta: defaultTargetPlatform == TargetPlatform.macOS,
                  control: defaultTargetPlatform != TargetPlatform.macOS,
                ),
              ],
            ),
            command(kAppSettingsCommandId, order: 20),
          ],
          child: const Scaffold(body: Text('fleet content')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  PlatformMenuItem item(WidgetTester tester, String label) {
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    PlatformMenuItem? search(List<PlatformMenuItem> items) {
      for (final item in items) {
        if (item.label == label && item is! PlatformMenu) return item;
        final children = switch (item) {
          PlatformMenu(:final menus) => menus,
          PlatformMenuItemGroup(:final members) => members,
          _ => const <PlatformMenuItem>[],
        };
        if (search(children) case final found?) return found;
      }
      return null;
    }

    return search(bar.menus)!;
  }

  testWidgets('macOS: while locked the native items are disabled but '
      'Settings, and come back on unlock', (tester) async {
    await pump(tester);

    expect(item(tester, kEditUndoCommandId).onSelected, isNull);
    // Settings shows its own locked notice in its window.
    item(tester, kAppSettingsCommandId).onSelected!();
    await tester.pump();
    expect(runs, [kAppSettingsCommandId]);

    locked.value = false;
    await tester.pumpAndSettle();
    item(tester, kEditUndoCommandId).onSelected!();
    await tester.pump();
    expect(runs, [kAppSettingsCommandId, kEditUndoCommandId]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a command chord runs nothing while locked, and runs once '
      'unlocked', (tester) async {
    await pump(tester);

    Future<void> undo() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await undo();
    expect(runs, isEmpty);

    locked.value = false;
    await tester.pump();
    await undo();
    expect(runs, [kEditUndoCommandId]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
