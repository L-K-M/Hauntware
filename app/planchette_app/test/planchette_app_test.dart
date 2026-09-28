import 'dart:async';
import 'dart:io';

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
    bool alt = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
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
    'Tab indents the document while Ctrl+Tab still switches tabs',
    (tester) async {
      final first = workspace.newDocument()!;
      workspace.newDocument();
      workspace.select(first);
      await mount(tester);
      first.editor.editorFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(first.editor.text.text, '    ');
      expect(first.editor.editorFocus.hasFocus, isTrue);

      await chord(tester, LogicalKeyboardKey.tab);
      expect(workspace.active, isNot(first));
      expect(first.editor.text.text, '    ');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    // Next Tab is Control+Tab on every platform, including macOS.
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
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
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
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

  testWidgets('untitled documents get a ghost line, opened files do not', (
    tester,
  ) async {
    final first = workspace.newDocument()!;
    store.files[testPath('empty.txt')] = document('empty.txt', '');
    await mount(tester);
    TextField field(DocumentTab tab) =>
        tester.widget<TextField>(editorField(tab));

    expect(field(first).decoration!.hintText, ghostLineFor(first.id));
    expect(ghostLineFor(first.id), startsWith('Start typing.'));
    final second = workspace.newDocument()!;
    await tester.pumpAndSettle();
    expect(field(second).decoration!.hintText, ghostLineFor(second.id));
    expect(ghostLineFor(second.id), isNot(ghostLineFor(first.id)));

    await workspace.open(testPath('empty.txt'));
    await tester.pumpAndSettle();
    expect(field(workspace.active!).decoration!.hintText, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('the ghost line hides while the workspace is locked', (
    tester,
  ) async {
    final empty = workspace.newDocument()!;
    workspace.newDocument()!.editor.text.text = 'unsaved';
    dialogs.choiceGate = Completer<CloseChoice>();
    await mount(tester);
    // The quit prompt activates the dirty tab, so the empty one is offstage.
    String? hint() => tester
        .widget<TextField>(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                identical(widget.controller, empty.editor.text),
            skipOffstage: false,
          ),
        )
        .decoration!
        .hintText;
    expect(hint(), ghostLineFor(empty.id));

    final quitting = workspace.confirmQuit();
    await tester.pump();
    expect(workspace.interactionLocked, isTrue);
    expect(hint(), isNull);

    dialogs.choiceGate!.complete(CloseChoice.cancel);
    expect(await quitting, isFalse);
    await tester.pumpAndSettle();
    expect(hint(), ghostLineFor(empty.id));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets(
    'Close Tab stays available while a document is loading',
    (tester) async {
      store.files[testPath('slow.txt')] = document('slow.txt', 'slow');
      store.loadGate = Completer<void>();
      await mount(tester);
      final opening = workspace.open(testPath('slow.txt'));
      // pump only: the loading spinner never lets pumpAndSettle finish.
      await tester.pump();
      expect(workspace.active!.editor.isLoading, isTrue);
      await tester.tap(find.text('File'));
      await tester.pump();
      final item = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Close Tab'),
      );
      expect(item.onPressed, isNotNull);
      // The tab's × follows the same availability rule as the menu command.
      expect(
        tester
            .widget<IconButton>(
              find.byKey(ValueKey('close-${workspace.active!.id}')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Close Tab'));
      await tester.pump();
      expect(workspace.documents, isEmpty);
      expect(workspace.active, isNull);
      store.loadGate!.complete();
      await opening;
      expect(workspace.documents, isEmpty);
      expect(workspace.active, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Close Tab stays available after a reload error',
    (tester) async {
      store.files[testPath('gone.txt')] = document('gone.txt', 'ok');
      await mount(tester);
      await workspace.open(testPath('gone.txt'));
      await tester.pumpAndSettle();
      store.files.remove(testPath('gone.txt'));
      await workspace.active!.editor.reload();
      await tester.pumpAndSettle();
      expect(workspace.active!.editor.error, isNotNull);
      await tester.tap(find.text('File'));
      await tester.pump();
      final item = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Close Tab'),
      );
      expect(item.onPressed, isNotNull);
      // The tab's × follows the same availability rule as the menu command.
      expect(
        tester
            .widget<IconButton>(
              find.byKey(ValueKey('close-${workspace.active!.id}')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Close Tab'));
      await tester.pump();
      expect(workspace.documents, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'line commands run once from the Edit menu and the keyboard',
    (tester) async {
      final tab = workspace.newDocument()!..editor.text.text = 'one\ntwo';
      await mount(tester);
      tab.editor.text.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move Line Down'));
      await tester.pumpAndSettle();
      expect(tab.editor.text.text, 'two\none');

      tab.editor.editorFocus.requestFocus();
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyD, shift: true);
      expect(tab.editor.text.text, 'two\none\none');
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

  testWidgets('the error banner announces itself as a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await mount(tester);
    await workspace.open(testPath('missing.txt'));
    await tester.pumpAndSettle();

    final message = find.textContaining('Could not open');
    expect(message, findsOneWidget);
    final banner = find.byKey(const ValueKey('workspace-error-banner'));
    expect(tester.getSemantics(banner), isSemantics(isLiveRegion: true));
    semantics.dispose();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('a retried save retires its error banner in the UI', (
    tester,
  ) async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final tab = workspace.active!..editor.text.text = 'edited';
    store.writeError = const FileSystemException('Disk full');
    await mount(tester);

    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final banner = find.byKey(const ValueKey('workspace-error-banner'));
    expect(banner, findsOneWidget);
    expect(find.textContaining('Disk full'), findsOneWidget);

    store.writeError = null;
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(tab.editor.isDirty, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
  testWidgets(
    'menu Save All writes every dirty document',
    (tester) async {
      store.files[testPath('one.txt')] = document('one.txt', 'original one');
      store.files[testPath('two.txt')] = document('two.txt', 'original two');
      await workspace.open(testPath('one.txt'));
      final first = workspace.active!;
      await workspace.open(testPath('two.txt'));
      final second = workspace.active!;
      await mount(tester);

      // Nothing is dirty, so the command offers nothing to do.
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      final saveAllButton = find.ancestor(
        of: find.text('Save All'),
        matching: find.byType(MenuItemButton),
      );
      expect(tester.widget<MenuItemButton>(saveAllButton).onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      first.editor.text.text = 'edited one';
      second.editor.text.text = 'edited two';
      await tester.pumpAndSettle();

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save All'));
      await tester.pumpAndSettle();
      expect(store.files[testPath('one.txt')]!.text, 'edited one');
      expect(store.files[testPath('two.txt')]!.text, 'edited two');
      expect(first.editor.isDirty, isFalse);
      expect(second.editor.isDirty, isFalse);
      expect(workspace.error, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'review fix: Ctrl+Alt+S is left to AltGr text off macOS',
    (tester) async {
      // Windows reports AltGr as Ctrl+Alt, so a Ctrl+Alt+S binding would
      // swallow characters such as Polish AltGr+S, and Save it instead.
      store.files[testPath('one.txt')] = document('one.txt', 'original one');
      store.files[testPath('two.txt')] = document('two.txt', 'original two');
      await workspace.open(testPath('one.txt'));
      final first = workspace.active!;
      await workspace.open(testPath('two.txt'));
      final second = workspace.active!;
      first.editor.text.text = 'edited one';
      second.editor.text.text = 'edited two';
      await mount(tester);

      await chord(tester, LogicalKeyboardKey.keyS, alt: true);
      expect(store.files[testPath('one.txt')]!.text, 'original one');
      expect(store.files[testPath('two.txt')]!.text, 'original two');
      expect(workspace.documents.every((tab) => tab.editor.isDirty), isTrue);

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      final saveAllButton = find.ancestor(
        of: find.text('Save All'),
        matching: find.byType(MenuItemButton),
      );
      expect(tester.widget<MenuItemButton>(saveAllButton).shortcut, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets('the Save All accelerator is Command+Option+S on macOS', (
    tester,
  ) async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    await workspace.open(testPath('one.txt'));
    workspace.active!.editor.text.text = 'edited one';
    await mount(tester);

    // macOS shortcuts live on the native menu, which intercepts no widget
    // events, so the accelerator is asserted on the registered menu item
    // and exercised through its own selection.
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final file = bar.menus.whereType<PlatformMenu>().firstWhere(
      (menu) => menu.label == 'File',
    );
    final saveAll = file.menus
        .whereType<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .firstWhere((item) => item.label == 'Save All');
    // SingleActivator has no value equality, so the binding is compared
    // field by field.
    final shortcut = saveAll.shortcut;
    expect(shortcut, isA<SingleActivator>());
    final keys = shortcut! as SingleActivator;
    expect(keys.trigger, LogicalKeyboardKey.keyS);
    expect(keys.meta, isTrue);
    expect(keys.alt, isTrue);
    expect(keys.control, isFalse);
    expect(keys.shift, isFalse);
    saveAll.onSelected!();
    await tester.pumpAndSettle();

    expect(store.files[testPath('one.txt')]!.text, 'edited one');
    expect(workspace.active!.editor.isDirty, isFalse);
    expect(workspace.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets(
    'switching back to a tab restores find-field focus',
    (tester) async {
      final first = workspace.newDocument()!;
      final second = workspace.newDocument()!;
      await mount(tester);
      workspace.select(first);
      await tester.pumpAndSettle();
      first.editor.openSearch();
      await tester.pumpAndSettle();
      expect(first.editor.searchFocus.hasFocus, isTrue);
      workspace.select(second);
      await tester.pumpAndSettle();
      expect(first.editor.searchFocus.hasFocus, isFalse);
      workspace.select(first);
      await tester.pumpAndSettle();
      expect(first.editor.searchFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'switching back after the find bar closed restores document focus',
    (tester) async {
      final first = workspace.newDocument()!;
      final second = workspace.newDocument()!;
      await mount(tester);
      workspace.select(first);
      await tester.pumpAndSettle();
      first.editor.openSearch();
      await tester.pumpAndSettle();
      expect(first.editor.searchFocus.hasFocus, isTrue);
      first.editor.closeSearch();
      await tester.pumpAndSettle();
      workspace.select(second);
      await tester.pumpAndSettle();
      workspace.select(first);
      await tester.pumpAndSettle();
      expect(first.editor.editorFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'switching back to a tab restores replacement-field focus',
    (tester) async {
      final first = workspace.newDocument()!;
      final second = workspace.newDocument()!;
      await mount(tester);
      workspace.select(first);
      await tester.pumpAndSettle();
      first.editor.openSearch(replace: true);
      await tester.pumpAndSettle();
      first.editor.replacementFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(first.editor.replacementFocus.hasFocus, isTrue);
      workspace.select(second);
      await tester.pumpAndSettle();
      workspace.select(first);
      await tester.pumpAndSettle();
      expect(first.editor.replacementFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'collapsing replace moves focus back to the find field',
    (tester) async {
      workspace.newDocument();
      await mount(tester);
      final editor = workspace.active!.editor;
      editor.openSearch(replace: true);
      await tester.pumpAndSettle();
      editor.replacementFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(editor.replacementFocus.hasFocus, isTrue);
      editor.toggleReplace();
      await tester.pumpAndSettle();
      expect(editor.searchFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'collapsing replace does not steal focus it no longer holds',
    (tester) async {
      workspace.newDocument();
      await mount(tester);
      final editor = workspace.active!.editor;
      editor.openSearch(replace: true);
      await tester.pumpAndSettle();
      editor.replacementFocus.requestFocus();
      await tester.pumpAndSettle();
      // The field was the last focused node, but focus moved on before the
      // collapse — a host may share the focus scope, so nothing is stolen.
      editor.replacementFocus.unfocus();
      await tester.pumpAndSettle();
      editor.toggleReplace();
      await tester.pumpAndSettle();
      expect(editor.searchFocus.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Go to Matching Bracket runs once from the Find menu and the keyboard',
    (tester) async {
      final tab = workspace.newDocument()!..editor.text.text = 'f(a, b)';
      await mount(tester);
      tab.editor.text.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      await tester.tap(find.text('Find'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go to Matching Bracket'));
      await tester.pumpAndSettle();
      expect(tab.editor.text.selection.extentOffset, 6);

      // Both the document and the menu bind the chord; a second run would
      // jump straight back.
      tab.editor.editorFocus.requestFocus();
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyB, shift: true);
      expect(
        tab.editor.text.selection,
        const TextSelection(baseOffset: 6, extentOffset: 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets('native text menus target the focused Go to Line field', (
    tester,
  ) async {
    final tab = workspace.newDocument()!..editor.text.text = 'document text';
    await mount(tester);
    tab.editor.openGoToLine();
    await tester.pumpAndSettle();
    tab.editor.goToLineInput.text = '12';
    tab.editor.goToLineInput.selection = const TextSelection.collapsed(
      offset: 1,
    );
    tab.editor.goToLineFocus.requestFocus();
    await tester.pump();
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final edit = bar.menus.whereType<PlatformMenu>().firstWhere(
      (menu) => menu.label == 'Edit',
    );
    final selectAll = edit.menus
        .whereType<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .firstWhere((item) => item.label == 'Select All');

    selectAll.onSelected!();
    await tester.pump();
    // Select All acts on the field that has focus, not the document.
    expect(
      tab.editor.goToLineInput.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    expect(tab.editor.goToLineFocus.hasFocus, isTrue);
    expect(tab.editor.text.selection.isCollapsed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
}
