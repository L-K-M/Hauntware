import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

void main() {
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  setUp(() {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
  });
  tearDown(() {
    workspace.dispose();
  });

  Finder editorField(DocumentTab tab) => find.byWidgetPredicate(
    (widget) =>
        widget is TextField && identical(widget.controller, tab.editor.text),
  );

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
    bool meta = false,
  }) async {
    await tester.sendKeyDownEvent(
      meta ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
    );
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(
      meta ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'tab switches retain undo, selection and search state',
    (tester) async {
      final first = workspace.newDocument()!;
      await mount(tester);
      await tester.enterText(editorField(first), 'first version');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(editorField(first), 'second version');
      await tester.pump(const Duration(milliseconds: 600));
      first.editor.text.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 7,
      );
      first.editor.search.text = 'version';
      final second = workspace.newDocument()!;
      await tester.pumpAndSettle();
      await tester.enterText(editorField(second), 'other document');
      await tester.pump(const Duration(milliseconds: 600));
      workspace.select(first);
      await tester.pumpAndSettle();
      expect(
        first.editor.text.selection,
        const TextSelection(baseOffset: 2, extentOffset: 7),
      );
      expect(first.editor.search.text, 'version');
      first.editor.undoController.undo();
      await tester.pump();
      expect(first.editor.text.text, 'first version');
      expect(second.editor.text.text, 'other document');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'document shortcuts save the active tab and create another',
    (tester) async {
      final first = workspace.newDocument()!;
      dialogs.savePath = testPath('shortcut.txt');
      await mount(tester);
      await tester.enterText(editorField(first), 'shortcut text');
      await chord(tester, LogicalKeyboardKey.keyS);
      expect(store.files[testPath('shortcut.txt')]!.text, 'shortcut text');
      expect(first.editor.isDirty, isFalse);
      await chord(tester, LogicalKeyboardKey.keyN);
      expect(workspace.documents.length, 2);
      expect(workspace.active, isNot(first));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'New and Open shortcuts remain available after closing the last tab',
    (tester) async {
      workspace.newDocument();
      store.files[testPath('reopen.txt')] = document('reopen.txt', 'on disk');
      dialogs.openPaths = [testPath('reopen.txt')];
      await mount(tester);

      await chord(tester, LogicalKeyboardKey.keyW);
      expect(workspace.documents, isEmpty);
      await chord(tester, LogicalKeyboardKey.keyN);
      expect(workspace.documents, hasLength(1));

      await chord(tester, LogicalKeyboardKey.keyW);
      expect(workspace.documents, isEmpty);
      await chord(tester, LogicalKeyboardKey.keyO);
      expect(workspace.documents, hasLength(1));
      expect(workspace.active!.editor.text.text, 'on disk');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'menu Save As uses the active document',
    (tester) async {
      final tab = workspace.newDocument()!..editor.text.text = 'menu text';
      dialogs.savePath = testPath('menu.txt');
      await mount(tester);
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save As…'));
      await tester.pumpAndSettle();
      expect(tab.path, testPath('menu.txt'));
      expect(tab.editor.isDirty, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'quit Save succeeds with the mounted editor locked',
    (tester) async {
      final tab = workspace.newDocument()!
        ..editor.text.text = 'save before closing';
      dialogs.choiceGate = Completer<CloseChoice>();
      dialogs.savePath = testPath('closing.txt');
      await mount(tester);
      final quitting = workspace.confirmQuit();
      await tester.pump();
      expect(tester.widget<TextField>(editorField(tab)).readOnly, isTrue);
      dialogs.choiceGate!.complete(CloseChoice.save);
      await tester.pumpAndSettle();
      expect(await quitting, isTrue);
      expect(store.files[testPath('closing.txt')]!.text, 'save before closing');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );
  testWidgets(
    'native text menus target the focused search field and lock for close',
    (tester) async {
      final tab = workspace.newDocument()!..editor.text.text = 'document text';
      dialogs.choiceGate = Completer<CloseChoice>();
      await mount(tester);
      tab.editor.openSearch();
      await tester.pumpAndSettle();
      tab.editor.search.text = 'needle';
      tab.editor.search.selection = const TextSelection.collapsed(offset: 2);
      tab.editor.searchFocus.requestFocus();
      await tester.pump();
      PlatformMenuItem item(String menuLabel, String label) {
        final bar = tester.widget<PlatformMenuBar>(
          find.byType(PlatformMenuBar),
        );
        final menu = bar.menus.whereType<PlatformMenu>().firstWhere(
          (menu) => menu.label == menuLabel,
        );
        return menu.menus
            .whereType<PlatformMenuItemGroup>()
            .expand((group) => group.members)
            .firstWhere((item) => item.label == label);
      }

      item('Edit', 'Select All').onSelected!();
      await tester.pump();
      expect(
        tab.editor.search.selection,
        const TextSelection(baseOffset: 0, extentOffset: 6),
      );
      expect(tab.editor.text.text, 'document text');
      final closing = workspace.closeTab(tab);
      await tester.pump();
      expect(item('File', 'Save').onSelected, isNull);
      expect(item('Edit', 'Undo').onSelected, isNull);
      dialogs.choiceGate!.complete(CloseChoice.cancel);
      await tester.pumpAndSettle();
      expect(await closing, isFalse);
      expect(item('File', 'Save').onSelected, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'view zoom adjusts every open editor and resets',
    (tester) async {
      final mac = defaultTargetPlatform == TargetPlatform.macOS;
      Future<void> zoomIn() =>
          chord(tester, LogicalKeyboardKey.equal, shift: true, meta: mac);
      Future<void> zoomOut() =>
          chord(tester, LogicalKeyboardKey.minus, meta: mac);
      workspace.newDocument();
      await mount(tester);
      Finder editors() => find.byType(PlanchetteEditor);
      double size() => tester
          .widget<PlanchetteEditor>(editors().first)
          .textStyle
          .fontSize!;
      TextStyle rendered() => tester
          .widget<EditableText>(
            find.descendant(
              of: editors().first,
              matching: find.byType(EditableText),
            ),
          )
          .style;

      expect(size(), 14);
      await zoomIn();
      expect(size(), 15);
      // The editor merges the zoom size into its own monospace default.
      expect(rendered().fontFamily, 'monospace');
      expect(rendered().height, 1.35);
      expect(rendered().fontSize, 15);
      await zoomOut();
      await zoomOut();
      expect(size(), 13);
      // Numpad +/- bindings ship too, but stay untested: synthesizing them
      // throws in flutter_test (numpad keys have no linux keyCode mapping;
      // event_simulation asserts 'not found in linux keyCode map').

      // A second tab opens at the current zoom and tracks later changes.
      workspace.newDocument();
      await tester.pumpAndSettle();
      for (final editor in tester.widgetList<PlanchetteEditor>(editors())) {
        expect(editor.textStyle.fontSize, 13);
      }
      await zoomIn();
      for (final editor in tester.widgetList<PlanchetteEditor>(editors())) {
        expect(editor.textStyle.fontSize, 14);
      }

      // Both clamps hold.
      for (var i = 0; i < 30; i++) {
        await zoomOut();
      }
      expect(size(), 8);
      for (var i = 0; i < 40; i++) {
        await zoomIn();
      }
      expect(size(), 32);

      // Reset goes through the app menu bar, which macOS replaces with
      // native menus that widget tests cannot tap.
      if (!mac) {
        for (var i = 0; i < 17; i++) {
          await zoomOut();
        }
        expect(size(), 15);
        await tester.tap(find.text('View'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reset Zoom'));
        await tester.pumpAndSettle();
        expect(size(), 14);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );
}
