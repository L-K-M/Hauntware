import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs;

void main() {
  testWidgets(
    'Go to Line opens from the menu and the shortcut',
    (tester) async {
      final workspace = DocumentWorkspace(
        store: MemoryDocuments(),
        dialogs: FakeDialogs(),
      );
      addTearDown(workspace.dispose);
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'one\ntwo\nthree';
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Find'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go to Line…'));
      await tester.pumpAndSettle();
      expect(tab.editor.goToLineOpen, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tab.editor.goToLineOpen, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    },
    // macOS menus are native, so the menu half runs on Linux and Windows.
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'the Go to Line shortcut is Cmd+L on macOS and Ctrl+G elsewhere',
    (tester) async {
      final workspace = DocumentWorkspace(
        store: MemoryDocuments(),
        dialogs: FakeDialogs(),
      );
      addTearDown(workspace.dispose);
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'one\ntwo\nthree';
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
      );
      await tester.pumpAndSettle();

      final apple = defaultTargetPlatform == TargetPlatform.macOS;
      final modifier = apple
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(
        apple ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.keyG,
      );
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(tab.editor.goToLineOpen, isTrue);
      tab.editor.goToLineInput.text = '3';
      expect(tab.editor.submitGoToLine(), isTrue);
      expect(tab.editor.caretLineColumn, (3, 1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}
