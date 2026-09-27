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
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
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
    'the header names the document, launch copy only when empty',
    (tester) async {
      Finder header() => find.byKey(const ValueKey('active-document-label'));
      String headerText() => tester.widget<Text>(header()).data!;

      await mount(tester);
      expect(headerText(), 'A place for your words.');

      final untitled = workspace.newDocument()!;
      await tester.pumpAndSettle();
      expect(headerText(), untitled.name);

      // Each untitled tab names itself, not the first one.
      final second = workspace.newDocument()!;
      await tester.pumpAndSettle();
      expect(headerText(), second.name);

      store.files[testPath('named.txt')] = document('named.txt', 'on disk');
      await workspace.open(testPath('named.txt'));
      await tester.pumpAndSettle();
      expect(headerText(), testPath('named.txt'));
      // A truncated path is still recoverable: the header's own tooltip
      // carries it, whether or not the tab strip shows the same one.
      expect(
        find
            .ancestor(
              of: header(),
              matching: find.byTooltip(testPath('named.txt')),
            )
            .evaluate()
            .isNotEmpty,
        isTrue,
      );

      // Closing every tab brings the launch copy back.
      for (final tab in workspace.documents) {
        expect(await workspace.closeTab(tab), isTrue);
      }
      await tester.pumpAndSettle();
      expect(headerText(), 'A place for your words.');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'the toolbar Save waits for the document, like the menu Save',
    (tester) async {
      // The toolbar's save button, identified by its icon: find.byTooltip
      // resolves to the Tooltip, which does not carry the enabled state.
      Finder toolbarSave() => find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.icon is Icon &&
            (widget.icon as Icon).icon == Icons.save_outlined,
      );
      VoidCallback? saveHandler() =>
          tester.widget<IconButton>(toolbarSave()).onPressed;

      store.files[testPath('slow.txt')] = document('slow.txt', 'on disk');
      store.loadGate = Completer<void>();
      await mount(tester);

      // A tab is created and activated before its load resolves, so the shell
      // can render a document that is still loading.
      final opening = workspace.open(testPath('slow.txt'));
      await tester.pump();
      expect(workspace.active!.editor.isLoading, isTrue);
      expect(saveHandler(), isNull);

      store.loadGate!.complete();
      await opening;
      await tester.pumpAndSettle();
      expect(workspace.active!.editor.isLoading, isFalse);
      expect(saveHandler(), isNotNull);

    'reopening an open document flashes its tab',
    (tester) async {
      store.files[testPath('flash.txt')] = document('flash.txt', 'on disk');
      await workspace.open(testPath('flash.txt'));
      await mount(tester);
      final tab = workspace.active!;
      final chip = find.byKey(ValueKey('tab-${tab.id}'));
      final surface = Theme.of(tester.element(chip)).colorScheme;
      Color chipColor() =>
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: chip,
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;

      expect(chipColor(), surface.surface);

      // Opening the same path again activates the tab instead of adding one.
      await workspace.open(testPath('flash.txt'));
      await tester.pump();
      expect(workspace.documents, [tab]);
      expect(chipColor(), surface.secondaryContainer);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(chipColor(), surface.surface);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );


  testWidgets('the tab flash respects disabled animation', (tester) async {
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    store.files[testPath('still.txt')] = document('still.txt', 'on disk');
    await workspace.open(testPath('still.txt'));
    await mount(tester);
    final tab = workspace.active!;
    final chip = find.byKey(ValueKey('tab-${tab.id}'));

    await workspace.open(testPath('still.txt'));
    await tester.pump();
    expect(workspace.active, tab);
    final container = find.descendant(
      of: chip,
      matching: find.byType(AnimatedContainer),
    );
    expect(
      (tester.widget<AnimatedContainer>(container).decoration! as BoxDecoration)
          .color,
      Theme.of(tester.element(chip)).colorScheme.surface,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

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
