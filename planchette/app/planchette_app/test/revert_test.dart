import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;
import 'services/memory_settings.dart';

// Review fixes for #91's Revert to Saved.
void main() {
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  final path = testPath('draft.txt');

  setUp(() {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
    store.files[path] = document('draft.txt', 'v1 on disk');
  });
  tearDown(() => workspace.dispose());

  Future<DocumentTab> mount(WidgetTester tester) async {
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

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> revertFromMenu(WidgetTester tester) async {
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revert to Saved'));
    await tester.pumpAndSettle();
  }

  testWidgets('a revert is final: Undo cannot bring the edits back', (
    tester,
  ) async {
    final tab = await mount(tester);
    final field = find.byKey(const ValueKey('planchette.document'));
    await tester.enterText(field, 'my edit one');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(field, 'my edit two');
    await tester.pump(const Duration(milliseconds: 600));
    store.files[path] = document('draft.txt', 'v2 from elsewhere');

    await revertFromMenu(tester);
    expect(tab.editor.text.text, 'v2 from elsewhere');
    await chord(tester, LogicalKeyboardKey.keyZ);
    expect(tab.editor.text.text, 'v2 from elsewhere');
    expect(tab.editor.isDirty, isFalse);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('the document stays on screen while a revert reads', (
    tester,
  ) async {
    final tab = await mount(tester);
    tab.editor.text.text = 'mine';
    store.loadGate = Completer<void>();
    final reverting = workspace.revert(tab);
    await tester.pump();
    // The editor itself never loads, so the field is not swapped for a
    // spinner, and a failed read could not hide the buffer.
    expect(tab.editor.isLoading, isFalse);
    expect(find.byKey(const ValueKey('planchette.document')), findsOneWidget);
    store.loadGate!.complete();
    expect(await reverting, isTrue);
    expect(tab.editor.text.text, 'v1 on disk');
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('a failed revert keeps the edits and its error goes with '
      'the tab', (tester) async {
    final tab = await mount(tester);
    tab.editor.text.text = 'mine';
    store.files.remove(path);
    expect(await workspace.revert(tab), isFalse);
    expect(tab.editor.text.text, 'mine');
    expect(workspace.error, contains('Could not revert draft.txt'));

    // Scoped to the tab like its save failures: closing it retires the
    // message, which is no longer about anything on screen.
    dialogs.choices.add(CloseChoice.discard);
    expect(await workspace.closeTab(tab), isTrue);
    expect(workspace.error, isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('Revert to Saved has no shortcut', (tester) async {
    // No platform convention names one, and Cmd+R and Ctrl+R mean other
    // things in other apps; a revert that cannot be undone should not be
    // one mistyped chord away.
    final tab = await mount(tester);
    tab.editor.text.text = 'mine';
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyR);
    expect(dialogs.revertAsked, isFalse);
    expect(tab.editor.text.text, 'mine');
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
