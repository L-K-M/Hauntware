import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

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

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1000, 720),
  }) async {
    await tester.binding.setSurfaceSize(size);
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
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  void expectVisibleTab(WidgetTester tester, DocumentTab tab) {
    final strip = tester.getRect(
      find.ancestor(
        of: find.byTooltip(tab.path ?? tab.name),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        ),
      ),
    );
    final bounds = tester.getRect(find.byTooltip(tab.path ?? tab.name));
    final close = tester.getRect(find.byKey(ValueKey('close-${tab.id}')));
    expect(bounds.left, greaterThanOrEqualTo(strip.left));
    expect(bounds.right, lessThanOrEqualTo(strip.right));
    expect(strip.contains(close.center), isTrue);
  }

  testWidgets(
    'overflow tabs stay visible through document and keyboard commands',
    (tester) async {
      for (var index = 0; index < 15; index++) {
        workspace.newDocument();
      }
      final first = workspace.documents.first;
      final last = workspace.active!;
      await mount(tester, size: const Size(640, 400));
      expectVisibleTab(tester, last);

      await chord(tester, LogicalKeyboardKey.tab);
      expect(workspace.active, first);
      expectVisibleTab(tester, first);
      expect(first.editor.editorFocus.hasFocus, isTrue);

      await chord(tester, LogicalKeyboardKey.tab, shift: true);
      expect(workspace.active, last);
      expectVisibleTab(tester, last);
      expect(last.editor.editorFocus.hasFocus, isTrue);

      await chord(tester, LogicalKeyboardKey.keyN);
      final created = workspace.active!;
      expectVisibleTab(tester, created);
      expect(created.editor.editorFocus.hasFocus, isTrue);

      store.files[testPath('opened.txt')] = document('opened.txt', 'on disk');
      dialogs.openPaths = [testPath('opened.txt')];
      await chord(tester, LogicalKeyboardKey.keyO);
      expect(workspace.active!.path, testPath('opened.txt'));
      expectVisibleTab(tester, workspace.active!);
      expect(workspace.active!.editor.editorFocus.hasFocus, isTrue);

      await chord(tester, LogicalKeyboardKey.keyW);
      expect(workspace.active, created);
      expectVisibleTab(tester, created);
      expect(created.editor.editorFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets('long dirty tab keeps its close control visible after resize', (
    tester,
  ) async {
    final name = '${'long-filename-' * 12}.txt';
    store.files[testPath(name)] = document(name, 'on disk');
    for (var index = 0; index < 8; index++) {
      workspace.newDocument();
    }
    await workspace.open(testPath(name));
    final tab = workspace.active!..editor.text.text = 'changed';
    await mount(tester, size: const Size(1200, 720));
    expectVisibleTab(tester, tab);

    await tester.binding.setSurfaceSize(const Size(640, 400));
    await tester.pumpAndSettle();
    expectVisibleTab(tester, tab);
    expect(find.byTooltip(testPath(name)), findsOneWidget);

    dialogs.choices.add(CloseChoice.cancel);
    await tester.tap(find.byKey(ValueKey('close-${tab.id}')));
    await tester.pumpAndSettle();
    expect(dialogs.asked, [name]);
    expect(workspace.active, tab);
    expect(tab.editor.isDirty, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('text scaling keeps the active tab visible', (tester) async {
    for (var index = 0; index < 15; index++) {
      workspace.newDocument();
    }
    await mount(tester, size: const Size(640, 400));
    expectVisibleTab(tester, workspace.active!);

    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    await tester.pumpAndSettle();
    expectVisibleTab(tester, workspace.active!);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
}
