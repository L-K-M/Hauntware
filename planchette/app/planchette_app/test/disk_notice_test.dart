import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;
import 'services/memory_settings.dart';

// Adapted from #26: the notice for a file another program changed or removed.
void main() {
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  final path = testPath('notice.txt');
  final field = find.byKey(const ValueKey('planchette.document'));

  setUp(() {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
  });
  tearDown(() => workspace.dispose());

  Future<DocumentTab> mount(WidgetTester tester, String text) async {
    store.files[path] = document('notice.txt', text, digest: 'v1');
    await workspace.open(path);
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpAndSettle();
    return workspace.active!;
  }

  void changeOnDisk(String text, {String digest = 'v2'}) =>
      store.files[path] = document('notice.txt', text, digest: digest);

  Future<void> undo(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester, String text) async {
    // Two settled edits: a single undo entry cannot be undone.
    await tester.enterText(field, '$text.');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(field, text);
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('a tab without edits reloads in place, for good', (tester) async {
    final lines = List.generate(400, (i) => 'line $i').join('\n');
    final tab = await mount(tester, lines);
    await edit(tester, lines);
    expect(tab.editor.isDirty, isFalse);
    tab.editor.goToLine(300, column: 3);
    await tester.pumpAndSettle();
    final caret = tab.editor.text.selection;
    final offset = tab.editor.scroll.offset;
    expect(offset, greaterThan(0));

    changeOnDisk('$lines\nline 400');
    await workspace.checkDisk();
    await tester.pumpAndSettle();
    expect(tab.editor.text.text, endsWith('line 400'));
    expect(find.textContaining('changed on disk'), findsNothing);
    expect(tab.editor.text.selection, caret);
    expect(tab.editor.scroll.offset, offset);

    // The reader did not choose it, but the outside version is the file's
    // text now: Undo stops there rather than reviving the old one.
    await undo(tester);
    expect(tab.editor.text.text, endsWith('line 400'));
    expect(tab.editor.isDirty, isFalse);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('Reload takes the outside version for good', (tester) async {
    final tab = await mount(tester, 'original');
    await edit(tester, 'mine');
    changeOnDisk('theirs');
    await workspace.checkDisk();
    await tester.pumpAndSettle();
    expect(find.textContaining('notice.txt changed on disk'), findsOneWidget);
    expect(find.text('Keep Mine'), findsOneWidget);

    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(dialogs.revertAsked, isFalse);
    expect(tab.editor.text.text, 'theirs');
    expect(find.textContaining('changed on disk'), findsNothing);
    await undo(tester);
    expect(tab.editor.text.text, 'theirs');
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('Keep Mine retires the notice and keeps the edits unsaved', (
    tester,
  ) async {
    final tab = await mount(tester, 'original');
    await edit(tester, 'mine');
    changeOnDisk('theirs');
    await workspace.checkDisk();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep Mine'));
    await tester.pumpAndSettle();
    expect(find.textContaining('changed on disk'), findsNothing);
    expect(tab.editor.text.text, 'mine');
    expect(tab.editor.isDirty, isTrue);
    expect(await workspace.save(tab), isTrue);
    expect(store.files[path]!.text, 'mine');
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('the notice waits while the tab is busy', (tester) async {
    final tab = await mount(tester, 'original');
    await edit(tester, 'mine');
    changeOnDisk('theirs');
    await workspace.checkDisk();
    await tester.pumpAndSettle();

    ButtonStyleButton button(String label) => tester.widget(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    tab.busy = true;
    workspace.clearError();
    await tester.pump();
    expect(button('Keep Mine').onPressed, isNull);
    expect(button('Reload').onPressed, isNull);
    tab.busy = false;
    workspace.clearError();
    await tester.pump();
    expect(button('Keep Mine').onPressed, isNotNull);
    expect(button('Reload').onPressed, isNotNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('the notice is announced, keyboard reachable, and never '
      'takes focus', (tester) async {
    final handle = tester.ensureSemantics();
    final tab = await mount(tester, 'original');
    await tester.showKeyboard(field);
    await edit(tester, 'mine');
    changeOnDisk('theirs');
    await workspace.checkDisk();
    await tester.pumpAndSettle();

    // Typing carries on in the document while the notice appears.
    expect(tab.editor.editorFocus.hasFocus, isTrue);
    expect(
      tester.getSemantics(find.byKey(ValueKey('disk-notice-${tab.id}'))),
      matchesSemantics(
        isLiveRegion: true,
        label:
            'notice.txt changed on disk. Reload it, or keep your edits '
            'and replace it when you save.',
      ),
    );

    // Tab from the top of the window reaches the notice before the
    // document, whose Tab key indents.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    bool onKeepMine() =>
        Focus.of(tester.element(find.text('Keep Mine'))).hasPrimaryFocus;
    for (var presses = 0; presses < 40 && !onKeepMine(); presses++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(onKeepMine(), isTrue);
    expect(tab.editor.text.text, 'mine');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Keep Mine'), findsNothing);
    expect(tab.editor.isDirty, isTrue);
    handle.dispose();
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('a deleted file offers Save, which creates it again', (
    tester,
  ) async {
    final tab = await mount(tester, 'original');
    store.files.remove(path);
    await workspace.checkDisk();
    await tester.pumpAndSettle();
    expect(
      find.text('notice.txt was deleted or moved. Save to create it again.'),
      findsOneWidget,
    );

    // A deleted file has no saved version to go back to.
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Revert to Saved'),
          )
          .onPressed,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(store.files[path]!.text, 'original');
    expect(store.writes.last.digest, isNull);
    expect(tab.disk, DiskState.current);
    expect(find.textContaining('deleted or moved'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
