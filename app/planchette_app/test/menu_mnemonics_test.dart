import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs;
import 'services/memory_settings.dart';

/// Alt mnemonics on the in-window menu bar: unique letters, clean native
/// labels, and Alt that opens menus without swallowing AltGr typing.
///
/// Keyboard behaviour here is validated in the framework's key-event model
/// only: simulated events carry explicit characters. Whether a real Windows
/// or Linux keyboard layout delivers a character for Alt and AltGr
/// combinations the way these tests assume is not covered (see
/// docs/TEXT_TOOLS.md).
void main() {
  group('menuAcceleratorLabel', () {
    test('marks the mnemonic, case-insensitively', () {
      expect(menuAcceleratorLabel('Save', 's'), '&Save');
      expect(menuAcceleratorLabel('Save As…', 'a'), 'Save &As…');
      expect(menuAcceleratorLabel('Copy Path', 'p'), 'Copy &Path');
      expect(menuAcceleratorLabel('Find', 'N'.toLowerCase()), 'Fi&nd');
      expect(menuAcceleratorLabel('Export as HTML…', 'x'), 'E&xport as HTML…');
    });

    test('escapes literal ampersands', () {
      expect(menuAcceleratorLabel('One & Two', 'o'), '&One && Two');
    });

    test('a label without the letter comes back unmarked', () {
      expect(menuAcceleratorLabel('Renamed', 'z'), 'Renamed');
      expect(menuAcceleratorLabel('Save', ''), 'Save');
    });
  });

  group('labels', () {
    late MemoryDocuments store;
    late DocumentWorkspace workspace;
    setUp(() {
      store = MemoryDocuments();
      workspace = DocumentWorkspace(store: store, dialogs: FakeDialogs());
    });
    tearDown(() => workspace.dispose());

    Future<void> mount(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, settings: testSettings()),
      );
      await tester.pumpAndSettle();
    }

    /// The bar's own six labels; submenu overlays render inside the MenuBar
    /// subtree too, so an open menu's entries are the labels beyond these.
    const barLabels = {'&File', '&Edit', '&Text', 'Fi&nd', '&View', '&Window'};

    List<String> openMenuLabels(WidgetTester tester) => [
      for (final label in tester.widgetList<MenuAcceleratorLabel>(
        find.byType(MenuAcceleratorLabel),
      ))
        if (!barLabels.contains(label.label)) label.label,
    ];

    String? acceleratorOf(String marked) {
      final at = marked.indexOf('&');
      return at < 0 || at + 1 >= marked.length
          ? null
          : marked[at + 1].toLowerCase();
    }

    void expectUniqueAndMarked(List<String> marked, String where) {
      final letters = <String>[];
      for (final label in marked) {
        final letter = acceleratorOf(label);
        expect(letter, isNotNull, reason: 'unmarked entry in $where: $label');
        expect(
          MenuAcceleratorLabel.stripAcceleratorMarkers(label).toLowerCase(),
          contains(letter),
          reason: '$where marks a letter outside $label',
        );
        letters.add(letter!);
      }
      expect(
        letters.toSet().length,
        letters.length,
        reason: '$where reuses a mnemonic letter: $letters',
      );
    }

    testWidgets('the bar marks one unique letter per top menu', (tester) async {
      workspace.newDocument();
      await mount(tester);
      expect(openMenuLabels(tester), isEmpty);
      final labels = [
        for (final label in tester.widgetList<MenuAcceleratorLabel>(
          find.byType(MenuAcceleratorLabel),
        ))
          label.label,
      ];
      expect(labels, unorderedEquals(barLabels.toList()));
      expect(labels, hasLength(6));
      expectUniqueAndMarked(labels, 'the menu bar');
      expect(labels, containsAll(['&File', '&Edit', '&Text', '&View']));
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    for (final menu in ['File', 'Edit', 'Find', 'View', 'Window', 'Text']) {
      testWidgets('the $menu menu marks unique letters', (tester) async {
        workspace.newDocument();
        await mount(tester);
        await tester.tap(find.text(menu));
        await tester.pumpAndSettle();
        final labels = openMenuLabels(tester);
        expect(labels, isNotEmpty, reason: '$menu opened nothing');
        expectUniqueAndMarked(labels, menu);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
    }

    testWidgets('macOS keeps native labels and no accelerators', (
      tester,
    ) async {
      workspace.newDocument();
      await mount(tester);
      expect(find.byType(MenuAcceleratorLabel), findsNothing);
      expect(find.byType(MenuBar), findsNothing);
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      String labels(Iterable<PlatformMenuItem> items) => items
          .map(
            (item) => switch (item) {
              PlatformMenuItemGroup(:final members) => labels(members),
              PlatformMenu(:final menus) => '${item.label}(${labels(menus)})',
              _ => item.label,
            },
          )
          .join();
      final all = labels(bar.menus);
      expect(all, isNot(contains('&')));
      expect(all, contains('Compare with Saved'));
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('keyboard', () {
    late MemoryDocuments store;
    late DocumentWorkspace workspace;
    setUp(() {
      store = MemoryDocuments();
      workspace = DocumentWorkspace(store: store, dialogs: FakeDialogs());
    });
    tearDown(() => workspace.dispose());

    /// Whether the File menu's overlay is up: its rows' marked labels exist
    /// beyond the bar's six. Works whether or not Alt is held, since the
    /// stored label always carries its marker.
    bool fileMenuOpen(WidgetTester tester) => tester
        .widgetList<MenuAcceleratorLabel>(find.byType(MenuAcceleratorLabel))
        .any((label) => label.label == 'Reopen Closed &Tab');

    Future<void> mount(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      workspace.newDocument();
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, settings: testSettings()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Alt plus the bar letter opens the menu', (tester) async {
      await mount(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
      await tester.pumpAndSettle();
      expect(fileMenuOpen(tester), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      // With Alt released the labels are plain Text again, and the File
      // menu's rows are visible.
      expect(find.text('Reopen Closed Tab'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('an open menu runs a command by Alt letter', (tester) async {
      await mount(tester);
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      // Zoom In is enabled at the default size; its letter is 'i'.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI, character: 'i');
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      // The menu closed by running the command: its rows are gone.
      expect(find.text('Zoom In'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('Ctrl+Alt, the Windows AltGr report, opens nothing', (
      tester,
    ) async {
      await mount(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
      await tester.pumpAndSettle();
      expect(fileMenuOpen(tester), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

    testWidgets('AltGr on Linux producing a character opens nothing', (
      tester,
    ) async {
      await mount(tester);
      // What the GTK embedder delivers for a key the input method did not
      // turn into text: AltRight held, the event carrying the produced
      // character. 'q' with '[' cannot read as a mnemonic letter.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: '[');
      await tester.pumpAndSettle();
      expect(fileMenuOpen(tester), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('plain typing without Alt opens nothing', (tester) async {
      await mount(tester);
      await tester.enterText(find.byType(EditableText).first, 'f');
      await tester.pump();
      expect(fileMenuOpen(tester), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
  });
}
