import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_dialogs.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, document, testPath;
import 'services/memory_settings.dart';

void main() {
  testWidgets('review fix: a close prompt for a background tab takes keys', (
    tester,
  ) async {
    // The prompt shows its tab first, and that tab's editor then took focus
    // back from the prompt after the frame, so neither Enter nor Escape
    // could answer it. Close Others and Close All go through this too.
    final store = MemoryDocuments();
    final navigator = GlobalKey<NavigatorState>();
    final workspace = DocumentWorkspace(
      store: store,
      dialogs: AppDocumentDialogs(navigator),
    );
    addTearDown(workspace.dispose);
    store.files[testPath('bg.txt')] = document('bg.txt', 'disk');
    await workspace.open(testPath('bg.txt'));
    final background = workspace.active!..editor.text.text = 'edited';
    final front = workspace.newDocument()!..editor.text.text = 'front';
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(
        workspace: workspace,
        settings: testSettings(),
        navigatorKey: navigator,
      ),
    );
    await tester.pumpAndSettle();
    expect(workspace.active, front);

    final closing = workspace.closeTab(background);
    await tester.pumpAndSettle();
    expect(find.text('Save changes to “bg.txt”?'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Save changes to “bg.txt”?'), findsNothing);
    expect(await closing, isFalse);
    // Back in the window, the tab the prompt showed has the keyboard.
    expect(background.editor.editorFocus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
