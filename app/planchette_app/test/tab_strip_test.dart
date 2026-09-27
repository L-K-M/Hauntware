import 'package:flutter/gestures.dart';
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

  Future<void> mount(WidgetTester tester, {double width = 1000}) async {
    await tester.binding.setSurfaceSize(Size(width, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  test('untitled documents reuse the lowest free number', () {
    final first = workspace.newDocument()!;
    final second = workspace.newDocument()!;
    expect([first.name, second.name], ['Untitled', 'Untitled 2']);
    workspace.select(first);
    // Closing a clean tab needs no dialog.
    return workspace.closeTab(first).then((_) {
      expect(workspace.newDocument()!.name, 'Untitled');
      expect(workspace.newDocument()!.name, 'Untitled 3');
    });
  });

  testWidgets(
    'numbered shortcuts select tabs, with 9 meaning the last',
    (tester) async {
      final tabs = [for (var i = 0; i < 4; i++) workspace.newDocument()!];
      await mount(tester);
      await chord(tester, LogicalKeyboardKey.digit2);
      expect(workspace.active, tabs[1]);
      await chord(tester, LogicalKeyboardKey.digit9);
      expect(workspace.active, tabs[3]);
      await chord(tester, LogicalKeyboardKey.digit7);
      expect(workspace.active, tabs[3], reason: 'no seventh tab');
      await chord(tester, LogicalKeyboardKey.digit1);
      expect(workspace.active, tabs[0]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets('a dirty tab shows a dot until hovered, then a close button', (
    tester,
  ) async {
    final first = workspace.newDocument()!;
    final second = workspace.newDocument()!;
    await mount(tester);
    first.editor.text.text = 'edited';
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dirty-${first.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('close-${first.id}')), findsNothing);
    expect(find.byKey(ValueKey('close-${second.id}')), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Untitled')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('close-${first.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('dirty-${first.id}')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('chrome rows start at the leading edge', (tester) async {
    workspace.newDocument();
    await mount(tester);
    // The shell's column used to center its rows, floating the menu bar
    // and a short tab strip in the middle of a wide window.
    expect(tester.getTopLeft(find.text('File')).dx, lessThan(40));
    expect(tester.getTopLeft(find.text('Untitled')).dx, lessThan(40));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('middle-click closes a tab', (tester) async {
    workspace.newDocument();
    final second = workspace.newDocument()!;
    await mount(tester);
    final middle = await tester.startGesture(
      tester.getCenter(find.text('Untitled 2')),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await middle.up();
    await tester.pumpAndSettle();
    expect(workspace.documents.contains(second), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the active tab scrolls into view in a crowded strip', (
    tester,
  ) async {
    for (var i = 0; i < 30; i++) {
      workspace.newDocument();
    }
    workspace.select(workspace.documents.first);
    await mount(tester, width: 700);
    await chord(tester, LogicalKeyboardKey.digit9);
    final last = workspace.documents.last;
    final rect = tester.getRect(find.text(last.name));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(700));

    await chord(tester, LogicalKeyboardKey.digit1);
    final first = tester.getRect(find.text('Untitled'));
    expect(first.left, greaterThanOrEqualTo(0));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
