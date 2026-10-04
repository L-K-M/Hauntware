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
  late DocumentWorkspace workspace;
  setUp(() {
    store = MemoryDocuments();
    workspace = DocumentWorkspace(store: store, dialogs: FakeDialogs());
  });
  tearDown(() {
    workspace.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
    );
    await tester.pumpAndSettle();
  }

  PlatformMenuItem item(WidgetTester tester, String menuLabel, String label) {
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final menu = bar.menus.whereType<PlatformMenu>().firstWhere(
      (menu) => menu.label == menuLabel,
    );
    Iterable<PlatformMenuItem> leaves(Iterable<PlatformMenuItem> items) =>
        items.expand(
          (entry) => switch (entry) {
            PlatformMenuItemGroup(:final members) => leaves(members),
            PlatformMenu(:final menus) => leaves(menus),
            _ => [entry],
          },
        );
    return leaves(menu.menus).firstWhere((entry) => entry.label == label);
  }

  testWidgets('File Copy Path copies the active path', (tester) async {
    store.files[testPath('a.txt')] = document('a.txt', 'hi');
    await workspace.open(testPath('a.txt'));
    await mount(tester);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final command = item(tester, 'File', 'Copy Path');
    expect(command.onSelected, isNotNull);
    command.onSelected!();
    await tester.pumpAndSettle();
    expect(copied, testPath('a.txt'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Edit Select Line selects the caret line', (tester) async {
    final tab = workspace.newDocument()!..editor.text.text = 'one\ntwo';
    await mount(tester);
    tab.editor.text.selection = const TextSelection.collapsed(offset: 5);

    item(tester, 'Edit', 'Select Line').onSelected!();
    await tester.pumpAndSettle();
    expect(
      tab.editor.text.selection,
      const TextSelection(baseOffset: 4, extentOffset: 7),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Edit lists the slice commands without new chords', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester);
    for (final label in [
      'Select Line',
      'Select Paragraph',
      'Select Enclosing Brackets',
      'Insert Line Above',
      'Insert Line Below',
      'Copy Line',
      'Cut Line',
      'Increment Number',
      'Decrement Number',
      'Paste and Match Indentation',
    ]) {
      expect(item(tester, 'Edit', label).label, label);
      expect(item(tester, 'Edit', label).shortcut, isNull);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
