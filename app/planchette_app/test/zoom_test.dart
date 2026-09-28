import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs;

void main() {
  late DocumentWorkspace workspace;
  setUp(() {
    workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
  });
  tearDown(() => workspace.dispose());

  double fontSize(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
      .style!
      .fontSize!;

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'zoom shortcuts resize every editor and reset to the default',
    (tester) async {
      workspace.newDocument();
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
      );
      await tester.pumpAndSettle();
      expect(fontSize(tester), 14);

      await chord(tester, LogicalKeyboardKey.equal);
      expect(fontSize(tester), 16);
      await chord(tester, LogicalKeyboardKey.numpadAdd);
      expect(fontSize(tester), 18);

      workspace.newDocument();
      await tester.pumpAndSettle();
      expect(fontSize(tester), 18, reason: 'new tabs share the zoom');

      await chord(tester, LogicalKeyboardKey.minus);
      await chord(tester, LogicalKeyboardKey.minus);
      await chord(tester, LogicalKeyboardKey.minus);
      expect(fontSize(tester), 13);

      await chord(tester, LogicalKeyboardKey.digit0);
      expect(fontSize(tester), 14);

      for (var i = 0; i < 20; i++) {
        await chord(tester, LogicalKeyboardKey.minus);
      }
      expect(fontSize(tester), 9, reason: 'zoom stops at the smallest size');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );
}
