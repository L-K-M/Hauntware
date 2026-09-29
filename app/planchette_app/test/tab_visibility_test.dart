// Ported from #11, whose tab visibility the tab strip took over: the active
// tab stays in view through commands, resizing and text scaling.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;
import 'services/memory_settings.dart';

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

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1000, 720),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
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
    // The trailing slot holds the close button, or a dirty tab's dot.
    final trailing = find.byKey(ValueKey('close-${tab.id}'));
    final slot = tester.getRect(
      trailing.evaluate().isEmpty
          ? find.byKey(ValueKey('dirty-${tab.id}'))
          : trailing,
    );
    expect(bounds.left, greaterThanOrEqualTo(strip.left));
    expect(bounds.right, lessThanOrEqualTo(strip.right));
    expect(strip.contains(slot.center), isTrue);
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
      // Typed into, so the open below does not replace it (#56).
      created.editor.text.text = 'kept';

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
    // A dirty tab offers its close button under the pointer.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byTooltip(testPath(name))));
    await tester.pumpAndSettle();
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

  testWidgets('a tab renamed by Save As stays in view', (tester) async {
    for (var index = 0; index < 15; index++) {
      workspace.newDocument();
    }
    final tab = workspace.active!..editor.text.text = 'named at last';
    await mount(tester, size: const Size(640, 400));
    expectVisibleTab(tester, tab);

    dialogs.savePath = testPath('${'a-much-longer-name-' * 6}.txt');
    expect(await workspace.save(tab, saveAs: true), isTrue);
    await tester.pumpAndSettle();
    expectVisibleTab(tester, tab);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
