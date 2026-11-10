import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostUndoableChange;
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart' show PaneVisibility;
import 'package:seance_app/ui/app_commands.dart';
import 'package:seance_app/ui/header_toolbar.dart';
import 'package:seance_core/seance_core.dart' show ProbeService;

/// The least [AppState] needs: its settings, the save they call, and the
/// probe service its dispose touches.
class _Services implements AppServices {
  @override
  final AppSettings settings = AppSettings();

  @override
  final ProbeService probe = ProbeService();

  @override
  Future<void> saveSettings() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The ☰ button (`SeanceMenuButton`): the app's commands as a popup on the
/// platforms with no native menu bar, and absent on macOS where the native
/// menu covers them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> pumpHeader(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    final state = AppState(_Services());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: platform),
        builder: (context, child) => AppScope(state: state, child: child!),
        home: const Scaffold(
          body: HeaderToolbar(sidebar: PaneVisibility.shown),
        ),
      ),
    );
    // Settle the theme animation, so a second pump of another platform
    // really rebuilds the header.
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> openButton(WidgetTester tester) async {
    await tester.tap(find.byKey(SeanceMenuButton.buttonKey));
    await tester.pumpAndSettle();
  }

  Future<void> openSubmenu(WidgetTester tester, String title) async {
    await tester.tap(
      find
          .ancestor(of: find.text(title), matching: find.byType(SubmenuButton))
          .last,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the header carries the ☰ off macOS and hides it there', (
    tester,
  ) async {
    await pumpHeader(tester, TargetPlatform.linux);
    expect(find.byKey(SeanceMenuButton.buttonKey), findsOneWidget);

    await pumpHeader(tester, TargetPlatform.macOS);
    expect(find.byKey(SeanceMenuButton.buttonKey), findsNothing);
  });

  testWidgets('the ☰ opens the menus and runs a command', (tester) async {
    await pumpHeader(tester, TargetPlatform.linux);

    await openButton(tester);
    for (final title in ['File', 'Edit', 'View', 'Terminal', 'Help']) {
      expect(find.text(title), findsOneWidget);
    }

    await openSubmenu(tester, 'Help');
    await tester.tap(find.text('Check for Updates…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.text(
        'No newer version was found. If you’re offline, try again later.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the wide header lists the pane toggles; the narrow button '
      'drops them', (tester) async {
    await pumpHeader(tester, TargetPlatform.linux);
    await openButton(tester);
    await openSubmenu(tester, 'View');
    expect(find.text('Hide Sidebar'), findsOneWidget);
    expect(find.text('Command Palette…'), findsOneWidget);
  });

  testWidgets('the ☰ Edit rows follow the undo history', (tester) async {
    final state = await pumpHeader(tester, TargetPlatform.linux);
    await openButton(tester);
    await openSubmenu(tester, 'Edit');

    state.undoHistory.record(
      GhostUndoableChange(
        name: 'Delete snippet',
        undo: () async {},
        redo: () async {},
      ),
    );
    await tester.pump();

    final undo = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('menu.item.edit.undo')),
    );
    expect(undo.onPressed, isNotNull);
    expect(find.text('Undo Delete snippet'), findsOneWidget);
    final redo = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('menu.item.edit.redo')),
    );
    expect(redo.onPressed, isNull);
    expect(find.text('Redo'), findsOneWidget);
  });

  testWidgets('a narrow ☰ keeps the commands that need no panes', (
    tester,
  ) async {
    final state = AppState(_Services());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.android),
        builder: (context, child) => AppScope(state: state, child: child!),
        home: const Scaffold(body: SeanceMenuButton(wide: false)),
      ),
    );

    await openButton(tester);
    await openSubmenu(tester, 'View');

    expect(find.text('Command Palette…'), findsOneWidget);
    expect(find.text('Hide Sidebar'), findsNothing);
  });
}
