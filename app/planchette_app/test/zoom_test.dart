import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs;

void main() {
  late DocumentWorkspace workspace;
  setUp(() {
    workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
  });
  tearDown(() => workspace.dispose());

  double fontSize(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
      .style!
      .fontSize!;

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'zoom shortcuts resize every editor and reset to the default',
    (tester) async {
      workspace.newDocument();
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
      );
      await tester.pumpAndSettle();
      expect(fontSize(tester), 14);

      await chord(tester, LogicalKeyboardKey.equal);
      expect(fontSize(tester), 16);
      await chord(tester, LogicalKeyboardKey.numpadAdd);
      expect(fontSize(tester), 18);

      workspace.newDocument();
      await tester.pumpAndSettle();
      expect(fontSize(tester), 18, reason: 'new tabs share the zoom');

      await chord(tester, LogicalKeyboardKey.minus);
      await chord(tester, LogicalKeyboardKey.minus);
      await chord(tester, LogicalKeyboardKey.minus);
      expect(fontSize(tester), 13);

      await chord(tester, LogicalKeyboardKey.digit0);
      expect(fontSize(tester), 14);

      for (var i = 0; i < 20; i++) {
        await chord(tester, LogicalKeyboardKey.minus);
      }
      expect(fontSize(tester), 9, reason: 'zoom stops at the smallest size');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  // Ported from #9, whose zoom this one replaced.
  testWidgets(
    'background tabs follow the zoom, which stops at the largest size',
    (tester) async {
      workspace
        ..newDocument()
        ..newDocument();
      await mount(tester);

      // Many layouts type `+` as Shift+=.
      await chord(tester, LogicalKeyboardKey.equal, shift: true);
      final editors = find.byType(PlanchetteEditor, skipOffstage: false);
      expect(editors, findsNWidgets(2));
      for (final editor in tester.widgetList<PlanchetteEditor>(editors)) {
        expect(editor.textStyle.fontSize, 16);
      }
      // The rendered text keeps the platform's family and line height.
      final rendered = tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('planchette.document')),
              matching: find.byType(EditableText),
            ),
          )
          .style;
      expect(
        rendered.fontFamily,
        editorMonospaceFor(defaultTargetPlatform).fontFamily,
      );
      expect(rendered.fontSize, 16);
      expect(rendered.height, 1.35);

      for (var i = 0; i < 20; i++) {
        await chord(tester, LogicalKeyboardKey.equal);
      }
      expect(fontSize(tester), 48, reason: 'zoom stops at the largest size');

      // Numpad minus and zero have no Linux key code in the test harness.
      if (defaultTargetPlatform != TargetPlatform.linux) {
        await chord(tester, LogicalKeyboardKey.numpadSubtract);
        expect(fontSize(tester), 36);
        await chord(tester, LogicalKeyboardKey.numpad0);
        expect(fontSize(tester), 14);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'the View menu offers each step only where it would change the size',
    (tester) async {
      workspace.newDocument();
      await mount(tester);
      MenuItemButton item(String label) => tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, label),
      );

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(item('Actual Size').onPressed, isNull);
      await tester.tap(find.text('Zoom In'));
      await tester.pumpAndSettle();
      expect(fontSize(tester), 16);

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actual Size'));
      await tester.pumpAndSettle();
      expect(fontSize(tester), 14);

      for (var i = 0; i < 10; i++) {
        await chord(tester, LogicalKeyboardKey.minus);
      }
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(item('Zoom Out').onPressed, isNull);
      expect(item('Zoom In').onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    // macOS shows these items in the native menu bar instead.
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );
}
