import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
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

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
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

    item(tester, 'Text', 'Sort Lines').onSelected!();
    // The run waits out the undo-history merge window before it applies.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(tab.editor.text.text, 'a\nb');
    expect(tab.editor.toolReport?.tool.id, 'sortLines');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the Text menu greys out with no editable document', (
    tester,
  ) async {
    await mount(tester);
    expect(workspace.active, isNull);
    expect(item(tester, 'Text', 'Sort Lines').onSelected, isNull);
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
      // The run waits out the undo-history merge window before it applies.
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

  // The generated Text menu groups the ten built tools into four
  // submenus, one per populated catalog group, in catalog order.
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
    expect(submenus, ['Lines', 'Case', 'Whitespace', 'Clean Up']);

    final lines = text.menus
        .whereType<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .whereType<PlatformMenu>()
        .first;
    final leaves = [
      for (final item in lines.menus)
        if (item case PlatformMenuItemGroup(:final members))
          for (final member in members) member.label,
    ];
    expect(leaves, [
      'Sort Lines',
      'Remove Duplicate Lines',
      'Remove Blank Lines',
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
}
