import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

// The workspace locks each editor through its controller the moment a dialog
// opens and unlocks it the moment the dialog closes, which can be before the
// next frame. Nothing may hold the lock until the view rebuilds.
import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

/// A save dialog that stays open until the test answers it, the way the
/// native picker stays open while frames keep rendering behind it.
class GatedSaveDialogs extends FakeDialogs {
  final saveGate = Completer<String?>();
  @override
  Future<String?> pickSavePath(String suggestedName) => saveGate.future;
}

void main() {
  testWidgets('a save answered before the next frame still writes', (
    tester,
  ) async {
    final store = MemoryDocuments();
    final dialogs = GatedSaveDialogs();
    final workspace = DocumentWorkspace(store: store, dialogs: dialogs);
    addTearDown(workspace.dispose);
    final tab = workspace.newDocument()!;
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
    );
    await tester.pumpAndSettle();
    tab.editor.text.text = 'race text';
    await tester.pump();

    // Ctrl+S on an untitled tab opens the (gated) save dialog.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Frames render while the dialog is open: the view now holds the
    // workspace's interaction lock.
    await tester.pump();
    await tester.pump();
    expect(workspace.interactionLocked, isTrue);
    expect(tab.editor.editingLocked, isTrue);

    // The user picks a path; the store answers before the next frame.
    dialogs.saveGate.complete(testPath('race.txt'));
    await tester.idle();

    expect(
      store.files[testPath('race.txt')]?.text,
      'race text',
      reason: 'the save ran before the view rebuilt without its lock',
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets(
    'Save As onto an existing file writes after Replace is confirmed',
    (tester) async {
      final store = MemoryDocuments();
      final dialogs = FakeDialogs()..savePath = testPath('existing.txt');
      final confirm = Completer<void>();
      dialogs.beforeReplace = () => confirm.future;
      final workspace = DocumentWorkspace(store: store, dialogs: dialogs);
      addTearDown(workspace.dispose);
      store.files[testPath('existing.txt')] = document('existing.txt', 'old');
      final tab = workspace.newDocument()!;
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
      );
      await tester.pumpAndSettle();
      tab.editor.text.text = 'new text';
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // The Replace question is on screen for a few frames.
      await tester.pump();
      await tester.pump();
      expect(workspace.interactionLocked, isTrue);

      // The user presses Replace; nothing else happens before the save.
      confirm.complete();
      await tester.idle();

      expect(store.files[testPath('existing.txt')]!.text, 'new text');
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.linux}),
  );
}
