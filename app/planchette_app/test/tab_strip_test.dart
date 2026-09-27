import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/widgets/tab_strip.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

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

  test('untitled documents reuse the lowest free number', () async {
    final first = workspace.newDocument()!;
    final second = workspace.newDocument()!;
    expect([first.name, second.name], ['Untitled', 'Untitled 2']);
    workspace.select(first);
    // Closing a clean tab needs no dialog.
    await workspace.closeTab(first);
    expect(workspace.newDocument()!.name, 'Untitled');
    expect(workspace.newDocument()!.name, 'Untitled 3');
  });

  test('an untitled name is never one an open file already shows', () async {
    final store = workspace.store as MemoryDocuments;
    store.files[testPath('Untitled 2')] = document('Untitled 2', 'saved');
    expect(workspace.newDocument()!.name, 'Untitled');
    await workspace.open(testPath('Untitled 2'));
    expect(workspace.newDocument()!.name, 'Untitled 3');
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

  testWidgets('tabs are buttons a screen reader can press and close', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final first = workspace.newDocument()!;
    workspace.newDocument();
    await mount(tester);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Untitled')),
      isSemantics(isButton: true, hasTapAction: true, isSelected: false),
    );
    tester.semantics.tap(find.semantics.byLabel('Untitled'));
    await tester.pumpAndSettle();
    expect(workspace.active, first);

    // An icon button is announced through its tooltip.
    tester.semantics.tap(
      find.semantics.byPredicate((node) => node.tooltip == 'Close Untitled'),
    );
    await tester.pumpAndSettle();
    expect(workspace.documents.contains(first), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('a focused tab opens with Enter and shows a focus ring', (
    tester,
  ) async {
    workspace.newDocument();
    final second = workspace.newDocument()!;
    workspace.select(workspace.documents.first);
    await mount(tester);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );

    Focus.of(tester.element(find.text('Untitled 2'))).requestFocus();
    await tester.pumpAndSettle();
    final tab = tester.widget<AnimatedContainer>(
      find.ancestor(
        of: find.text('Untitled 2'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(tab.foregroundDecoration, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(workspace.active, second);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('wheel and swipe each scroll the strip once', (tester) async {
    for (var i = 0; i < 30; i++) {
      workspace.newDocument();
    }
    workspace.select(workspace.documents.first);
    await mount(tester, width: 700);
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(TabStrip),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(position.pixels, 0);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Untitled 3'))),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(100, 0)));
    await tester.pump();
    expect(position.pixels, 100);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
    await tester.pump();
    expect(position.pixels, 150);
    // Shift+wheel is scrolled by the scroll view itself, with its axes
    // flipped; the resolver keeps the strip's handler from adding it again.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 25)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(position.pixels, 175);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
