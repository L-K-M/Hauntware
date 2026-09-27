import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/desktop_window.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'document_workspace_test.dart' show MemoryDocuments, FakeDialogs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed native destroy reports and unlocks the retained workspace',
    () async {
      final workspace = DocumentWorkspace(
        store: MemoryDocuments(),
        dialogs: FakeDialogs(),
      );
      addTearDown(workspace.dispose);
      final tab = workspace.newDocument()!;
      var attempts = 0;
      final desktop = DesktopWindow(
        confirmQuit: workspace.confirmQuit,
        onQuitFailed: workspace.quitFailed,
        destroyWindow: () async {
          attempts++;
          throw StateError('native close failed');
        },
      );
      await desktop.requestQuit();
      expect(workspace.interactionLocked, isFalse);
      expect(workspace.error, contains('native close failed'));
      expect(workspace.documents, [tab]);
      await desktop.requestQuit();
      expect(attempts, 2);
    },
  );

  test('overlapping close callbacks request native destruction once', () async {
    final decision = Completer<bool>();
    var destroys = 0;
    final desktop = DesktopWindow(
      confirmQuit: () => decision.future,
      onQuitFailed: (_) {},
      destroyWindow: () async {
        destroys++;
      },
    );
    final first = desktop.requestQuit();
    final second = desktop.requestQuit();
    decision.complete(true);
    await Future.wait([first, second]);
    expect(destroys, 1);
  });
}
