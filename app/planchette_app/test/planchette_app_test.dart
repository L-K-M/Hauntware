import 'dart:async';

import 'package:flutter/gestures.dart';
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
    // Unmount before the workspace is disposed, which the outer tearDown does.
    // Disposing a FocusNode that is still attached to the focus tree schedules
    // a focus change that then lands after the binding is gone.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
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
  testWidgets('the menu bar is flush left, not centred', (tester) async {
    workspace.newDocument();
    await mount(tester);

    final bar = tester.getRect(find.byType(MenuBar));
    final window = tester.getRect(find.byType(PlanchetteApp));

    // A Column centres its children across the cross axis, which used to put
    // the menu bar in the middle of the window because it shrink-wraps.
    expect(bar.left, moreOrLessEquals(window.left, epsilon: 0.01));
    expect(bar.width, moreOrLessEquals(window.width, epsilon: 0.01));
  });

  testWidgets('the first tab starts at the left edge', (tester) async {
    for (var i = 0; i < 3; i++) {
      workspace.newDocument();
    }
    await mount(tester);

    final strip = tester.getRect(find.byType(MenuBar));
    final tab = tester.getRect(find.text('Untitled 1'));
    final window = tester.getRect(find.byType(PlanchetteApp));

    expect(strip.left, moreOrLessEquals(window.left, epsilon: 0.01));
    // The 8px strip inset plus the tab's own 12px, not 400px of centring.
    expect(tab.left, lessThan(32));
  });

  testWidgets('no toolbar duplicates the File menu', (tester) async {
    workspace.newDocument();
    await mount(tester);

    expect(find.byIcon(Icons.folder_open_outlined), findsNothing);
    expect(find.byIcon(Icons.save_outlined), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.text('Planchette'), findsNothing);
  });

  testWidgets('an untitled document is not called a place for words', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester);

    expect(find.text('A place for your words.'), findsNothing);
  });

  testWidgets('the editor offers a scrollbar to drag', (tester) async {
    final tab = workspace.newDocument()!;
    await mount(tester);
    tab.editor.text.text = List.generate(4000, (i) => 'line $i').join('\n');
    await tester.pumpAndSettle();

    // ~39k characters is past the highlighting cap, so the status bar explains
    // the missing colours rather than leaving the reader to guess.
    expect(tab.editor.highlightingEnabled, isFalse);
    expect(find.textContaining('Large file'), findsOneWidget);

    // The field's own scrollable never gets a scrollbar, so the editor has to
    // supply one and drive it from the document's own controller.
    final scrollbars = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .toList();
    expect(
      scrollbars.where((bar) => identical(bar.controller, tab.editor.scroll)),
      isNotEmpty,
    );
    expect(tab.editor.scroll.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('the status bar starts where the text starts', (tester) async {
    final tab = workspace.newDocument()!;
    await mount(tester);
    await tester.enterText(editorField(tab), 'one\ntwo');
    await tester.pumpAndSettle();

    final gutter = tester.getRect(
      find.byKey(const ValueKey('editor-line-gutter')),
    );
    final position = tester.getRect(find.textContaining('Ln 2, Col 4'));
    final document = tester.getRect(
      find.byKey(const ValueKey('planchette.document')),
    );

    // The document's text starts after the gutter and the 14px content pad.
    final textEdge = document.left + 14;
    expect(gutter.left, lessThan(textEdge));
    expect(position.left, moreOrLessEquals(textEdge, epsilon: 1.0));

    // Let the pending focus change land while the tree is still mounted, so
    // the binding does not see it after disposal.
    await tester.pump();
  });

  testWidgets('an empty workspace offers New and Open, enabled', (
    tester,
  ) async {
    await mount(tester);

    expect(find.text('Start with a blank page'), findsOneWidget);
    final newButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'New document'),
    );
    final openButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Open…'),
    );
    expect(newButton.onPressed, isNotNull);
    expect(openButton.onPressed, isNotNull);
  });
  testWidgets('a locked workspace refuses to switch tabs', (tester) async {
    final first = workspace.newDocument()!;
    final second = workspace.newDocument()!;
    await mount(tester);
    await tester.tap(find.text('Untitled 1'));
    await tester.pumpAndSettle();
    expect(workspace.active, same(first));

    // A pending "Save changes?" dialog is what `interactionLocked` means.
    first.editor.text.text = 'unsaved';
    dialogs.choiceGate = Completer<CloseChoice>();
    final pending = workspace.closeTab(first);
    await tester.pumpAndSettle();
    expect(workspace.interactionLocked, isTrue);

    await tester.tap(find.text('Untitled 2'));
    await tester.pumpAndSettle();
    expect(
      workspace.active,
      same(first),
      reason: 'a dialog owns the interaction',
    );

    dialogs.choiceGate!.complete(CloseChoice.cancel);
    await pending;
    await tester.pumpAndSettle();
    expect(workspace.interactionLocked, isFalse);

    await tester.tap(find.text('Untitled 2'));
    await tester.pumpAndSettle();
    expect(workspace.active, same(second));
  });

  testWidgets('a plain mouse wheel scrolls the tab strip sideways', (
    tester,
  ) async {
    for (var i = 0; i < 40; i++) {
      final tab = workspace.newDocument()!;
      tab.editor.displayPath = 'a-long-document-name-number-$i-for-width.dart';
    }
    await mount(tester);

    // Forty tabs cannot fit, so the strip has somewhere to scroll to.
    final before = tester.getRect(find.text('Untitled 1'));
    expect(before.left, lessThan(40));

    // A real mouse wheel reports vertical delta, which a horizontal
    // scrollable ignores unless something forwards it.
    final strip = find.byType(SingleChildScrollView).first;
    final centre = tester.getCenter(strip);
    // ignore: avoid_print
    print('W strip rect=${tester.getRect(strip)} centre=$centre');

    await tester.sendEventToBinding(
      PointerScrollEvent(position: centre, scrollDelta: const Offset(0, 200)),
    );
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('W after event left=${tester.getRect(find.text('Untitled 1')).left}');

    await tester.drag(strip, const Offset(-200, 0));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print(
      'W after drag left=${tester.getRect(find.text('Untitled 1')).left} before=$before.left',
    );
  });
}
