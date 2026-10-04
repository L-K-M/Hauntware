import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_editor/planchette_editor.dart' show SyntaxLanguages;

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;
import 'services/memory_settings.dart';

/// Compare with Saved: the buffer against the file on disk, in a diff tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  final path = testPath('compared.txt');

  setUp(() {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
  });
  tearDown(() => workspace.dispose());

  Future<DocumentTab> open(String text) async {
    store.files[path] = document('compared.txt', text, digest: 'v1');
    await workspace.open(path);
    return workspace.active!;
  }

  test('differences from an externally changed file fill a diff tab', () async {
    final tab = await open('one\ntwo\nthree\n');
    tab.editor.text.text = 'one\nTWO\nthree\n';
    store.files[path] = document(
      'compared.txt',
      'one\ntwo\nTHREE\n',
      digest: 'v2',
    );

    expect(await workspace.compareWithSaved(tab), isTrue);

    final diff = workspace.active!;
    expect(diff, isNot(same(tab)));
    expect(diff.path, isNull);
    expect(diff.name, 'compared.txt vs saved.diff');
    expect(diff.editor.text.language, same(SyntaxLanguages.diff));
    expect(diff.editor.text.text, startsWith('--- compared.txt (on disk)\n'));
    expect(
      diff.editor.text.text,
      contains('+++ compared.txt (in the editor)\n'),
    );
    // The disk version minus the buffer's edit, and the buffer minus the
    // disk's: both directions show.
    expect(diff.editor.text.text, contains('-two\n-THREE\n+TWO\n+three\n'));
    expect(diff.editor.isDirty, isFalse);
  });

  test(
    'the source tab keeps its text, dirty state and digest guards',
    () async {
      final tab = await open('one\n');
      tab.editor.text.text = 'edited';
      store.files[path] = document('compared.txt', 'other', digest: 'v2');
      await workspace.checkDisk();
      expect(tab.disk, DiskState.changed);
      final digest = tab.baseline!.sha256;

      await workspace.compareWithSaved(tab);

      expect(workspace.documents, contains(tab));
      expect(tab.editor.text.text, 'edited');
      expect(tab.editor.isDirty, isTrue);
      expect(tab.baseline!.sha256, digest);
      expect(tab.baseline!.text, 'one\n');
      expect(tab.disk, DiskState.changed);
    },
  );

  test('no differences say so and open nothing', () async {
    final tab = await open('steady\n');
    expect(await workspace.compareWithSaved(tab), isFalse);
    expect(workspace.documents, hasLength(1));
    expect(
      workspace.error,
      'compared.txt has no differences from the file on disk.',
    );
  });

  test('a read failure reports the error and opens nothing', () async {
    final tab = await open('text\n');
    store.loadFailures[path] = const FileSystemException('Permission denied');
    expect(await workspace.compareWithSaved(tab), isFalse);
    expect(workspace.documents, hasLength(1));
    expect(workspace.error, contains('Could not compare compared.txt'));
    expect(workspace.error, contains('Permission denied'));
  });

  test('a missing file reports the read error honestly', () async {
    final tab = await open('text\n');
    store.files.remove(path);
    expect(await workspace.compareWithSaved(tab), isFalse);
    expect(workspace.error, contains('Could not compare compared.txt'));
  });

  test('text edited while the file is read refuses the stale diff', () async {
    final tab = await open('one\n');
    store.loadGate = Completer<void>();
    final comparing = workspace.compareWithSaved(tab);
    tab.editor.text.text = 'moved on';
    store.loadGate!.complete();
    expect(await comparing, isFalse);
    expect(workspace.documents, hasLength(1));
    expect(
      workspace.error,
      'compared.txt changed while it was being compared. Compare it again.',
    );
  });

  test('a tab closed while the file is read reports nothing', () async {
    final tab = await open('one\n');
    store.loadGate = Completer<void>();
    final comparing = workspace.compareWithSaved(tab);
    await workspace.closeTab(tab);
    store.loadGate!.complete();
    expect(await comparing, isFalse);
    expect(workspace.documents, isEmpty);
    expect(workspace.error, isNull);
  });

  test('a revert that starts while the file is read refuses', () async {
    final tab = await open('one\n');
    store.loadGate = Completer<void>();
    final comparing = workspace.compareWithSaved(tab);
    // The revert's own read waits behind the same gate, so the tab is busy
    // being reverted by the time the compare's read answers.
    final reverting = workspace.revert(tab);
    await pumpEventQueue();
    store.loadGate!.complete();
    expect(await comparing, isFalse);
    await reverting;
    expect(workspace.error, contains('being reverted'));
  });

  test(
    'a save in flight while the file is read reports busy, not a revert',
    () async {
      final tab = await open('one\n');
      tab.editor.text.text = 'edited';
      store.loadGate = Completer<void>();
      store.writeGate = Completer<void>();
      final comparing = workspace.compareWithSaved(tab);
      final saving = workspace.save(tab);
      await pumpEventQueue();
      expect(tab.busy, isTrue);
      store.loadGate!.complete();
      expect(await comparing, isFalse);
      store.writeGate!.complete();
      expect(await saving, isTrue);
      expect(workspace.error, contains('compared.txt is busy'));
      expect(workspace.error, isNot(contains('reverted')));
    },
  );

  test('a Save As that retargets the tab mid-compare refuses', () async {
    final tab = await open('one\n');
    tab.editor.text.text = 'edited';
    store.loadGate = Completer<void>();
    final comparing = workspace.compareWithSaved(tab);
    dialogs.savePath = testPath('elsewhere.txt');
    final saved = await workspace.save(tab, saveAs: true);
    expect(saved, isTrue);
    store.loadGate!.complete();
    expect(await comparing, isFalse);
    expect(workspace.documents, hasLength(1));
    expect(
      workspace.error,
      contains('was saved somewhere else while it was being compared'),
    );
  });

  test('disposing the workspace mid-compare stays silent', () async {
    // A workspace this test owns, so its dispose is not repeated by the
    // shared tearDown.
    final local = DocumentWorkspace(store: store, dialogs: dialogs);
    store.files[path] = document('compared.txt', 'one\n', digest: 'v1');
    await local.open(path);
    final tab = local.active!;
    store.loadGate = Completer<void>();
    final comparing = local.compareWithSaved(tab);
    local.dispose();
    store.loadGate!.complete();
    expect(await comparing, isFalse);
  });

  test(
    'a diff too large for the output limit is refused, not unchanged',
    () async {
      // Every line differs and the middle is far past the minimal-diff limit,
      // so the whole file replaces in one hunk — far past the output limit.
      final disk = List.generate(
        6000,
        (i) => 'disk line $i ${'x' * 80}',
      ).join('\n');
      final buffer = List.generate(
        6000,
        (i) => 'edit line $i ${'y' * 80}',
      ).join('\n');
      final tab = await open('$disk\n');
      tab.editor.text.text = '$buffer\n';

      expect(await workspace.compareWithSaved(tab), isFalse);
      expect(workspace.documents, hasLength(1));
      expect(workspace.error, contains('too large to show as a diff'));
    },
  );

  test('untitled and loading tabs are not compared', () async {
    final untitled = workspace.newDocument()!;
    expect(untitled.path, isNull);
    expect(await workspace.compareWithSaved(untitled), isFalse);
    expect(workspace.error, isNull);
  });

  testWidgets('the Find menu offers Compare with Saved on saved tabs only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // An untitled tab has nothing on disk to compare with.
    workspace.newDocument();
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Compare with Saved'),
          )
          .onPressed,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    store.files[path] = document('compared.txt', 'one\ntwo\n', digest: 'v1');
    await workspace.open(path);
    workspace.active!.editor.text.text = 'one\nTWO\n';
    await tester.pumpAndSettle();

    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare with Saved'));
    await tester.pump();

    // The diff runs in a worker isolate, which needs real async time the
    // widget pumper does not provide.
    for (var i = 0; i < 400 && workspace.documents.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(workspace.documents, hasLength(2));
    expect(workspace.active!.name, 'compared.txt vs saved.diff');
    expect(workspace.active!.editor.text.text, contains('-two\n+TWO\n'));
    // The source tab keeps its edit and its place.
    expect(workspace.documents.first.editor.isDirty, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('a deleted file keeps the command greyed, like Revert', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open('text\n');
    store.files.remove(path);
    await workspace.checkDisk();

    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Compare with Saved'),
          )
          .onPressed,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
