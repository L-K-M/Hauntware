import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/compare_view.dart';
import 'package:poltergeist_app/ui/shell/keyboard_shortcuts_dialog.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

RegisteredCommand _command(
  String id,
  String label,
  List<ShortcutActivator>? activators, {
  AppMenuId? menu,
}) => RegisteredCommand(
  id: id,
  scope: CommandScope.app,
  label: (_) => label,
  activators: activators == null ? null : (_) => activators,
  menuPlacement: menu == null
      ? null
      : CommandMenuPlacement(menu: menu, order: 10),
  run: (_) async {},
);

/// Opens the dialog from a button, as the Help command does.
Future<void> _open(
  WidgetTester tester,
  TargetPlatform platform,
  void Function(BuildContext context) open,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists every chorded command under its menu, macOS glyphs', (
    tester,
  ) async {
    final commands = [
      _command(
        'tab.new',
        'New Tab',
        const [SingleActivator(LogicalKeyboardKey.keyT, meta: true)],
        menu: AppMenuId.file,
      ),
      _command(
        'view.refresh',
        'Refresh',
        const [SingleActivator(LogicalKeyboardKey.keyR, meta: true)],
        menu: AppMenuId.view,
      ),
      _command('app.noChord', 'No Chord', null, menu: AppMenuId.file),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showKeyboardShortcutsDialog(context, commands),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('help.shortcuts.dialog')), findsOneWidget);
    expect(find.text('New Tab'), findsOneWidget);
    expect(find.text('⌘T'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    // A command without a chord has nothing to teach here.
    expect(find.text('No Chord'), findsNothing);
  });

  testWidgets('lists a view\'s own keys under it, after the menus', (
    tester,
  ) async {
    final commands = [
      _command('tab.new', 'New Tab', const [
        SingleActivator(LogicalKeyboardKey.keyT, meta: true),
      ], menu: AppMenuId.file),
      _command('app.loose', 'Loose', const [
        SingleActivator(LogicalKeyboardKey.keyL, meta: true),
      ]),
    ];
    await _open(
      tester,
      TargetPlatform.macOS,
      (context) => showKeyboardShortcutsDialog(
        context,
        commands,
        views: [compareViewShortcuts],
      ),
    );

    expect(find.text('Next change'), findsOneWidget);
    expect(find.text('N'), findsOneWidget);
    expect(find.text('Previous change'), findsOneWidget);
    expect(find.text('⇧N'), findsOneWidget);
    // Menus first, then the view, then the commands no menu holds.
    final file = tester.getTopLeft(find.text('File')).dy;
    final compare = tester.getTopLeft(find.text('Compare')).dy;
    final other = tester.getTopLeft(find.text('Other')).dy;
    expect(file, lessThan(compare));
    expect(compare, lessThan(other));
  });

  testWidgets('spells view keys out off macOS', (tester) async {
    await _open(
      tester,
      TargetPlatform.windows,
      (context) => showKeyboardShortcutsDialog(
        context,
        const [],
        views: [compareViewShortcuts],
      ),
    );

    expect(find.text('Compare'), findsOneWidget);
    expect(find.text('Shift+N'), findsOneWidget);
  });

  testWidgets('Help ▸ Keyboard Shortcuts lists the compare view keys', (
    tester,
  ) async {
    final lanes = controller_test.FakePaneLanes();
    final workspace = WorkspaceController(
      left: testPaneStrip(PaneController(paneTabId: 'pane.left', lanes: lanes)),
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    addTearDown(workspace.dispose);
    final help = buildShellCommands(
      workspace: workspace,
      dropDelegate: () => null,
      openConnect: () async {},
      allCommands: () => const [],
      openUrl: (_) async {},
      fileOps: () => null,
      reportFailure: (_) {},
      locationLabel: (_) => 'this computer',
    ).singleWhere((command) => command.id == kHelpKeyboardShortcutsCommandId);

    await _open(tester, TargetPlatform.macOS, help.run);

    expect(find.text('Compare'), findsOneWidget);
    expect(find.text('Next change'), findsOneWidget);
  });
}
