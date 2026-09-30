import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs;
import 'services/memory_settings.dart';

void main() {
  late MemoryDocuments store;
  late DocumentWorkspace workspace;
  setUp(() {
    store = MemoryDocuments();
    workspace = DocumentWorkspace(store: store, dialogs: FakeDialogs());
  });
  tearDown(() {
    workspace.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    SettingsController? settings,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: settings ?? testSettings()),
    );
    await tester.pumpAndSettle();
  }

  PlatformMenuItem item(WidgetTester tester, String menuLabel, String label) {
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final menu = bar.menus.whereType<PlatformMenu>().firstWhere(
      (menu) => menu.label == menuLabel,
    );
    // Item labels live one level down inside PlatformMenuItemGroups and,
    // for a submenu, inside a nested PlatformMenu.
    Iterable<PlatformMenuItem> leaves(Iterable<PlatformMenuItem> items) =>
        items.expand(
          (item) => switch (item) {
            PlatformMenuItemGroup(:final members) => leaves(members),
            PlatformMenu(:final menus) => leaves(menus),
            _ => [item],
          },
        );
    return leaves(menu.menus).firstWhere((item) => item.label == label);
  }

  testWidgets('the Text menu runs a tool on the active document', (
    tester,
  ) async {
    final tab = workspace.newDocument()!..editor.text.text = 'b\na';
    await mount(tester);
    tab.editor.text.selection = const TextSelection.collapsed(offset: 0);

    item(tester, 'Text', 'Remove Blank Lines').onSelected!();
    // The run waits out the undo-history merge window before it applies.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(tab.editor.toolReport?.tool.id, 'removeBlankLines');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a tool with options opens the tool bar, not a run', (
    tester,
  ) async {
    final tab = workspace.newDocument()!..editor.text.text = 'b\na';
    await mount(tester);
    tab.editor.text.selection = const TextSelection.collapsed(offset: 0);

    item(tester, 'Text', 'Sort Lines…').onSelected!();
    await tester.pump();
    expect(tab.editor.toolBarOpen, isTrue);
    expect(tab.editor.text.text, 'b\na');

    await tester.tap(find.text('Apply'));
    // The run waits out the undo-history merge window before it applies.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(tab.editor.text.text, 'a\nb');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the Text menu greys out with no editable document', (
    tester,
  ) async {
    await mount(tester);
    expect(workspace.active, isNull);
    expect(item(tester, 'Text', 'Sort Lines…').onSelected, isNull);
    expect(item(tester, 'Text', 'Repeat').onSelected, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'the palette offers text tools',
    (tester) async {
      final tab = workspace.newDocument()!..editor.text.text = 'b\na';
      await mount(tester);
      tab.editor.text.selection = const TextSelection.collapsed(offset: 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('planchette.palette.query')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('planchette.palette.query')),
        'sort lines',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      // Sort Lines has options: the palette opens the tool bar, whose
      // Apply is what runs.
      await tester.pumpAndSettle();
      expect(tab.editor.toolBarOpen, isTrue);
      await tester.tap(find.text('Apply'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(tab.editor.text.text, 'a\nb');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  // The generated Text menu leads with Repeat and Recent, then groups the
  // built tools into one submenu per populated catalog group.
  testWidgets('the Text menu groups tools into submenus', (tester) async {
    await mount(tester);
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final text = bar.menus.whereType<PlatformMenu>().firstWhere(
      (menu) => menu.label == 'Text',
    );
    final submenus = [
      for (final item in text.menus)
        if (item case PlatformMenuItemGroup(:final members))
          for (final member in members)
            if (member case PlatformMenu(:final label)) label,
    ];
    expect(submenus, [
      'Recent',
      'Lines',
      'Case',
      'Whitespace',
      'Clean Up',
      'Wrap',
    ]);

    final lines = text.menus
        .whereType<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .whereType<PlatformMenu>()
        .firstWhere((menu) => menu.label == 'Lines');
    final leaves = [
      for (final item in lines.menus)
        if (item case PlatformMenuItemGroup(:final members))
          for (final member in members) member.label,
    ];
    // An option tool's label ends in an ellipsis: it opens the tool bar.
    expect(leaves, [
      'Sort Lines…',
      'Remove Duplicate Lines…',
      'Remove Blank Lines',
      'Prefix/Suffix Lines…',
      'Number Lines…',
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  // The palette runs a command by id against the menu that is current
  // when the user picks it — a document closed while the palette was
  // open leaves the command disabled.
  testWidgets('a palette entry re-checks whether the command is enabled', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('planchette.palette.query')),
      'sort lines',
    );
    await tester.pump();

    // 'Sort Lines' is greyed: no document is open.
    expect(find.textContaining('Sort Lines'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // Enter on a disabled row is declined and the palette stays open.
    expect(
      find.byKey(const ValueKey('planchette.palette.query')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('Repeat re-runs the latest tool with its options', (
    tester,
  ) async {
    final tab = workspace.newDocument()!..editor.text.text = 'a\nb';
    await mount(tester);
    tab.editor.text.selection = const TextSelection.collapsed(offset: 0);

    workspace.toolHistory.record('sortLines', {'order': 'descending'});
    await tester.pump();
    item(tester, 'Text', 'Repeat Sort Lines (Z to A)').onSelected!();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(tab.editor.text.text, 'b\na');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the Recent submenu lists stored runs and re-runs one', (
    tester,
  ) async {
    final tab = workspace.newDocument()!..editor.text.text = 'b\na';
    await mount(tester);
    tab.editor.text.selection = const TextSelection.collapsed(offset: 0);

    workspace.toolHistory
      ..record('sortLines', {'order': 'descending'})
      ..record('uppercase', {});
    await tester.pump();
    expect(item(tester, 'Text', 'UPPERCASE').onSelected, isNotNull);
    expect(item(tester, 'Text', 'Sort Lines (Z to A)').onSelected, isNotNull);

    item(tester, 'Text', 'Sort Lines (Z to A)').onSelected!();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(tab.editor.text.text, 'b\na');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a run writes its record into the saved settings', (
    tester,
  ) async {
    final settings = testSettings();
    final tab = workspace.newDocument()!..editor.text.text = 'b\na';
    await mount(tester, settings: settings);
    tab.editor.text.selection = const TextSelection.collapsed(offset: 0);

    final run = tab.editor.runTextTool('sortLines');
    await tester.pump(const Duration(milliseconds: 600));
    await run;
    await tester.pumpAndSettle();

    expect(settings.value.recentTextTools, [containsPair('id', 'sortLines')]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
