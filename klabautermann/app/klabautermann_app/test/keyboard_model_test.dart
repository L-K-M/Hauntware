// PLT-06 (03 §10.6): the lists' single keys, the keyboard map, the tab
// commands and Esc going back.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/keyboard_map.dart';
import 'package:klabautermann_app/ui/menus/app_commands.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart';
import 'package:klabautermann_app/ui/sortable_table.dart';

import 'support/fake_engine.dart';

const _tableId = 'names';
const _names = ['alpha', 'beta', 'gamma'];

Finder _row(String name) => find.byKey(ValueKey('$_tableId.row.$name'));

/// Whether [row] draws the keyboard ring.
bool _ringed(WidgetTester tester, Finder row) => find
    .descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (widget) => widget is Container && widget.foregroundDecoration != null,
      ),
    )
    .evaluate()
    .isNotEmpty;

Widget _app(Widget home, {List<KeyboardMapEntry> commandKeys = const []}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => EscapeGoesBack(child: child!),
      home: KeyboardMapScope(commandKeys: (_) => commandKeys, child: home),
    );

Future<FocusNode> _pumpTable(
  WidgetTester tester, {
  List<String> ran = const [],
  bool Function(String row)? restartApplies,
}) async {
  final filter = FocusNode();
  addTearDown(filter.dispose);
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: Column(
          children: [
            TextField(focusNode: filter),
            Expanded(
              child: SortableTable<String>(
                tableId: _tableId,
                columns: [
                  SortableTableColumn(
                    id: 'name',
                    label: 'Name',
                    text: (name) => name,
                  ),
                ],
                rows: _names,
                rowKey: (name) => name,
                onRowActivated: (_) {},
                filterFocus: filter,
                keyActions: [
                  TableKeyAction(
                    key: LogicalKeyboardKey.keyL,
                    label: 'Show logs',
                    run: (name) => ran.add('logs $name'),
                  ),
                  TableKeyAction(
                    key: LogicalKeyboardKey.keyR,
                    label: 'Restart',
                    appliesTo: restartApplies,
                    run: (name) => ran.add('restart $name'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      commandKeys: const [KeyboardMapEntry('Ctrl+K', 'Command Palette…')],
    ),
  );
  await tester.tap(_row('alpha'));
  await tester.pumpAndSettle();
  return filter;
}

void main() {
  group('a list', () {
    testWidgets('j and k move the active row', (tester) async {
      await _pumpTable(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row('beta')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row('beta')), isTrue);
    });

    testWidgets('a single key runs its verb on the active row, and only '
        'where the verb applies', (tester) async {
      final ran = <String>[];
      await _pumpTable(
        tester,
        ran: ran,
        restartApplies: (name) => name != 'beta',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pumpAndSettle();
      expect(ran, ['logs alpha', 'restart alpha']);
    });

    testWidgets('/ moves focus to the filter field, where letters type', (
      tester,
    ) async {
      final ran = <String>[];
      final filter = await _pumpTable(tester, ran: ran);

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(filter.hasFocus, isTrue);

      await tester.enterText(find.byType(TextField), 'l');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pumpAndSettle();
      expect(ran, isEmpty, reason: 'a field keeps its letters');
    });

    testWidgets("? shows the list's keys over the window's", (tester) async {
      await _pumpTable(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(find.text('In this list'), findsOneWidget);
      expect(find.text('Move between rows'), findsOneWidget);
      expect(find.text('Show logs'), findsOneWidget);
      expect(find.text('Filter the list'), findsOneWidget);
      expect(find.text('Everywhere'), findsOneWidget);
      expect(find.text('Command Palette…'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsNothing);
    });
  });

  group('Esc', () {
    Future<NavigatorState> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(_app(const Scaffold(body: Text('home'))));
      return tester.state<NavigatorState>(find.byType(Navigator));
    }

    testWidgets('pops the page on top, and the home page stays', (
      tester,
    ) async {
      final navigator = await pumpHome(tester);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('page')),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('page'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('closes a dialog Esc dismisses, but not one it does not', (
      tester,
    ) async {
      final navigator = await pumpHome(tester);
      final context = navigator.context;

      showDialog<void>(context: context, builder: (_) => const Text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('open'), findsNothing);

      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Text('held'),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('held'), findsOneWidget);
    });
  });

  group('the tab commands', () {
    late FakeEngineClient engine;
    late FleetController fleet;

    setUp(() {
      engine = FakeEngineClient();
      fleet = FleetController(engine);
    });

    tearDown(() async {
      fleet.dispose();
      await engine.close();
    });

    List<AppCommand> commands(
      TargetPlatform platform, {
      void Function(BuildContext context, ServerPanel panel)? onOpenPanel,
    }) => buildAppCommands(
      platform: platform,
      fleet: fleet,
      onOpenSettings: () {},
      appVersion: null,
      onOpenPanel: onOpenPanel ?? (_, _) {},
      onShowKeyboardMap: (_) async {},
    );

    test('take ⌘1 to ⌘8 on macOS and Ctrl+1 to Ctrl+8 elsewhere, in tab '
        'order, and wait for a selected server', () {
      for (final (platform, meta) in [
        (TargetPlatform.macOS, true),
        (TargetPlatform.linux, false),
      ]) {
        final byId = {for (final c in commands(platform)) c.id: c};
        for (final panel in ServerPanel.values) {
          final command = byId[viewPanelCommandId(panel)]!;
          final activator =
              command.activators(platform).single as SingleActivator;
          expect(activator.meta, meta);
          expect(activator.control, !meta);
          expect(activator.trigger.keyLabel, '${panel.index + 1}');
          expect(command.enabled(), isFalse);
        }
        expect(byId[kAppKeyboardShortcutsCommandId], isNotNull);
      }
    });

    test('leave phones without them', () {
      final ids = {for (final c in commands(TargetPlatform.iOS)) c.id};
      expect(ids, isNot(contains(viewPanelCommandId(ServerPanel.overview))));
      expect(ids, isNot(contains(kAppKeyboardShortcutsCommandId)));
    });

    test('the keyboard map lists each command with its keys, and Esc', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final map = commandKeyboardMap(
        l10n,
        TargetPlatform.linux,
        commands(TargetPlatform.linux),
      );
      expect(
        map.map((entry) => '${entry.keys} ${entry.action}'),
        containsAll([
          'Ctrl+1 Go to Overview',
          'Ctrl+8 Go to Access',
          'Ctrl+/ Keyboard Shortcuts',
          'Ctrl+, Settings…',
          'Esc Close the dialog, sheet or page on top',
        ]),
      );
    });
  });
}
