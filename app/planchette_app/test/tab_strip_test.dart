import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/widgets/tab_strip.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;
import 'services/memory_settings.dart';

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
      PlanchetteApp(workspace: workspace, settings: testSettings()),
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
    final scratch = workspace.newDocument()!;
    expect(scratch.name, 'Untitled');
    // Typed into, so opening a file does not replace it (#56).
    scratch.editor.text.text = 'kept';
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

  testWidgets('the active tab shows its dirty dot too', (tester) async {
    final tab = workspace.newDocument()!;
    await mount(tester);
    expect(find.byKey(ValueKey('close-${tab.id}')), findsOneWidget);

    tab.editor.text.text = 'edited';
    await tester.pumpAndSettle();
    // The document being edited is the one whose state matters most.
    expect(find.byKey(ValueKey('dirty-${tab.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('close-${tab.id}')), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Untitled')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('close-${tab.id}')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // From #43.
  testWidgets('two files with the same name are told apart', (tester) async {
    final store = workspace.store as MemoryDocuments;
    final sep = Platform.pathSeparator;
    final a = 'a${sep}index.js';
    final b = 'b${sep}index.js';
    store.files[testPath(a)] = document(a, 'one');
    store.files[testPath(b)] = document(b, 'two');
    await workspace.open(testPath(a));
    await workspace.open(testPath(b));
    await mount(tester);

    // Each label carries its folder while the names collide.
    expect(find.text('a${sep}index.js'), findsOneWidget);
    expect(find.text('b${sep}index.js'), findsOneWidget);

    await workspace.closeTab(workspace.active!);
    await tester.pumpAndSettle();
    expect(find.text('index.js'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('review fix: same-named folders show as much path as needed', (
    tester,
  ) async {
    // Both labels read src/index.js, which told nothing apart.
    final store = workspace.store as MemoryDocuments;
    final sep = Platform.pathSeparator;
    final x = ['x', 'src', 'index.js'].join(sep);
    final y = ['y', 'src', 'index.js'].join(sep);
    final z = ['z', 'lib', 'index.js'].join(sep);
    for (final path in [x, y, z]) {
      store.files[testPath(path)] = document(path, path);
      await workspace.open(testPath(path));
    }
    await mount(tester);

    expect(find.text(x), findsOneWidget);
    expect(find.text(y), findsOneWidget);
    expect(find.text(['lib', 'index.js'].join(sep)), findsOneWidget);

    // One folder up from x and y, src/index.js needs its parent folder too.
    final short = ['src', 'index.js'].join(sep);
    store.files[testPath(short)] = document(short, short);
    await workspace.open(testPath(short));
    await tester.pumpAndSettle();
    final parent = testPath('').split(sep).lastWhere((part) => part.isNotEmpty);
    expect(find.text([parent, short].join(sep)), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a path whose folders all end another one shows every folder', (
    tester,
  ) async {
    final store = workspace.store as MemoryDocuments;
    final sep = Platform.pathSeparator;
    final root = paths.rootPrefix(testPath(''));
    final inner = paths.join(root, 'a', 'index.js');
    final outer = paths.join(root, 'x', 'a', 'index.js');
    for (final path in [inner, outer]) {
      store.files[path] = document(path, path);
      await workspace.open(path);
    }
    await mount(tester);

    expect(find.text(['a', 'index.js'].join(sep)), findsOneWidget);
    expect(find.text(['x', 'a', 'index.js'].join(sep)), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a tab keeps its width when it becomes dirty', (tester) async {
    final tab = workspace.newDocument()!;
    workspace.newDocument();
    await mount(tester);
    Size size() => tester.getSize(find.byKey(ValueKey('tab-${tab.id}')));
    final before = size();
    tab.editor.text.text = 'now it has content';
    await tester.pumpAndSettle();
    expect(size(), before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // From #42, whose tab actions moved into the strip.
  testWidgets('the tab menu closes others and all', (tester) async {
    workspace
      ..newDocument()
      ..newDocument()
      ..newDocument();
    await mount(tester);

    await tester.tap(find.text('Untitled'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close Others'));
    await tester.pumpAndSettle();
    expect(workspace.documents.map((tab) => tab.name), ['Untitled']);

    workspace.newDocument();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Untitled'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close All Tabs'));
    await tester.pumpAndSettle();
    expect(workspace.documents, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the tab menu offers Close All Tabs for a single tab', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester);
    await tester.tap(find.text('Untitled'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close All Tabs'));
    await tester.pumpAndSettle();
    expect(workspace.documents, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // From #66.
  testWidgets('the tab menu copies a saved document\'s full path', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final store = workspace.store as MemoryDocuments;
    store.files[testPath('context.txt')] = document('context.txt', 'body');
    workspace.newDocument()!.editor.text.text = 'unsaved';
    await workspace.open(testPath('context.txt'));
    await mount(tester);

    await tester.tap(find.text('context.txt'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Full Path'));
    await tester.pumpAndSettle();
    expect(copied, testPath('context.txt'));

    // An untitled document has no path to copy.
    await tester.tap(find.text('Untitled'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    final item = tester.widget<PopupMenuItem<void>>(
      find.ancestor(
        of: find.text('Copy Full Path'),
        matching: find.byType(PopupMenuItem<void>),
      ),
    );
    expect(item.enabled, isFalse);
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
    await tester.pump();
    // Like a click, the close happens on release, so a press can be dragged
    // away and abandoned.
    expect(workspace.documents.contains(second), isTrue);
    await middle.up();
    await tester.pumpAndSettle();
    expect(workspace.documents.contains(second), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('review fix: a middle-click released off its tab closes none', (
    tester,
  ) async {
    // The tap slop let a release on the next tab, or below the strip,
    // still close the tab the press began on.
    final first = workspace.newDocument()!;
    workspace.newDocument();
    await mount(tester);
    final tab = tester.getRect(
      find.ancestor(
        of: find.text('Untitled'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    for (final release in [
      Offset(tab.right + 12, tab.center.dy),
      Offset(tab.right - 3, tab.bottom + 10),
    ]) {
      final middle = await tester.startGesture(
        Offset(tab.right - 3, tab.center.dy),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await middle.moveTo(release);
      await middle.up();
      await tester.pumpAndSettle();
      expect(workspace.documents.contains(first), isTrue, reason: '$release');
    }
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

  testWidgets('tabs take the sibling apps\' shape', (tester) async {
    for (var i = 0; i < 30; i++) {
      workspace.newDocument();
    }
    final active = workspace.documents.first;
    workspace.select(active);
    await mount(tester, width: 700);
    final strip = find.byType(TabStrip);
    final scheme = Theme.of(tester.element(strip)).colorScheme;
    BoxDecoration chip(String name) =>
        tester
                .widget<AnimatedContainer>(
                  find.ancestor(
                    of: find.text(name),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;

    // Poltergeist's pane tabs, which Séance's share: flat chips from the
    // leading edge, each followed by a hairline, and no accent line; the
    // active one takes the editor's surface, over the strip's rule.
    expect(tester.getTopLeft(find.byKey(ValueKey('tab-${active.id}'))).dx, 0);
    final open = chip(active.name);
    final other = chip(workspace.documents[1].name);
    expect(open.borderRadius, isNull);
    for (final decoration in [open, other]) {
      final border = decoration.border! as BorderDirectional;
      expect(border.end.color, scheme.outlineVariant);
      expect(border.bottom, BorderSide.none);
    }
    expect(open.color, scheme.surface);
    final rule = tester
        .widget<Container>(
          find.descendant(of: strip, matching: find.byType(Container)).first,
        )
        .decoration!;
    expect(
      ((rule as BoxDecoration).border! as Border).bottom.color,
      scheme.outlineVariant,
    );

    // The new-tab button stays at the trailing edge, out of the scroll.
    final add = find.descendant(of: strip, matching: find.byIcon(Icons.add));
    expect(
      find.descendant(
        of: find.descendant(of: strip, matching: find.byType(Scrollable)),
        matching: find.byIcon(Icons.add),
      ),
      findsNothing,
    );
    expect(add.hitTestable(), findsOneWidget);
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

  testWidgets('review fix: a screen reader can close a dirty tab', (
    tester,
  ) async {
    // A dirty tab shows its dot in place of the close button until hovered
    // or focused, which a screen reader's cursor is not; the tab itself now
    // carries the close action.
    final dialogs = FakeDialogs()..choices.add(CloseChoice.discard);
    workspace.dispose();
    workspace = DocumentWorkspace(store: MemoryDocuments(), dialogs: dialogs);
    final semantics = tester.ensureSemantics();
    final first = workspace.newDocument()!;
    workspace.newDocument();
    await mount(tester);
    first.editor.text.text = 'edited';
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close Untitled'), findsNothing);

    tester.semantics.customAction(
      find.semantics.byLabel('Untitled, unsaved changes'),
      const CustomSemanticsAction(label: 'Close Untitled'),
    );
    await tester.pumpAndSettle();
    expect(dialogs.asked, ['Untitled']);
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
