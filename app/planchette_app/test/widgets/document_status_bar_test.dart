import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/widgets/document_status_bar.dart';
import 'package:planchette_editor/planchette_editor.dart';

// Slice 6 app status: clickable line endings, encoding and indentation over
// the shared editor's passive bar. Rebuilds from the controller, so no
// shell state is needed.
void main() {
  Finder menuItem(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<Object?>,
    ),
  );

  EditorController controller({String displayPath = 'notes.txt'}) {
    final editor = EditorController(
      displayPath: displayPath,
      initialText: 'a\nb\n',
      // Tool conversions apply at once; the UI wait is not under test.
      undoQuiet: Duration.zero,
    );
    addTearDown(editor.dispose);
    return editor;
  }

  Future<void> mount(WidgetTester tester, EditorController editor) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentStatusBar(controller: editor)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows caret, bytes, language and current metadata', (
    tester,
  ) async {
    final editor = controller();
    await mount(tester, editor);
    expect(find.textContaining('Ln 1, Col 1'), findsOneWidget);
    expect(find.text('LF'), findsOneWidget);
    expect(find.text('UTF-8'), findsOneWidget);
    expect(find.textContaining('Spaces:'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('line ending choices go through setMetadata', (tester) async {
    final editor = controller();
    await mount(tester, editor);
    await tester.tap(find.text('LF'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('CRLF'));
    await tester.pumpAndSettle();
    expect(editor.metadata.lineEnding, LineEnding.crlf);
    expect(find.text('CRLF'), findsOneWidget);
  });

  testWidgets('BOM choice explains its size and applies next save', (
    tester,
  ) async {
    final editor = controller();
    await mount(tester, editor);
    final button = find.text('UTF-8');
    expect(
      tester
          .widget<PopupMenuButton<Utf8Bom>>(
            find.ancestor(
              of: button,
              matching: find.byType(PopupMenuButton<Utf8Bom>),
            ),
          )
          .tooltip,
      contains('3 bytes'),
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(menuItem('UTF-8 BOM'));
    await tester.pumpAndSettle();
    expect(editor.metadata.utf8Bom, Utf8Bom.present);
  });

  testWidgets('indentation sets without dirtying the file', (tester) async {
    final editor = controller();
    await mount(tester, editor);
    expect(editor.isDirty, isFalse);
    await tester.tap(find.textContaining('Spaces:'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('Tabs'));
    await tester.pumpAndSettle();
    expect(editor.indentation.style, IndentStyle.tabs);
    expect(editor.isDirty, isFalse);
  });

  testWidgets('width picker keeps the style', (tester) async {
    final editor = controller();
    await mount(tester, editor);
    await tester.tap(find.textContaining('Spaces:'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('Width 8'));
    await tester.pumpAndSettle();
    expect(editor.indentation, const Indentation.spaces(8));
    expect(editor.isDirty, isFalse);
  });

  testWidgets('convert actions run the existing text tools', (tester) async {
    final editor = controller();
    editor.text.value = const TextEditingValue(
      text: '\ta',
      selection: TextSelection.collapsed(offset: 0),
    );
    await mount(tester, editor);
    await tester.tap(find.textContaining('Tab'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('Convert to Spaces'));
    // The bar fires runTextTool without awaiting; let the run land.
    await tester.pump();
    await tester.pumpAndSettle();
    // The shared convert tool owns the exact spacing; the bar only runs it.
    expect(editor.text.text.contains('\t'), isFalse);
  });

  testWidgets('a tab-mandated format disallows spaces', (tester) async {
    final editor = controller(displayPath: 'Makefile');
    await mount(tester, editor);
    await tester.tap(find.textContaining('Tab'));
    await tester.pumpAndSettle();
    PopupMenuItem<Object?> itemFor(String label) => tester.widget(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is PopupMenuItem<Object?>,
        ),
      ),
    );
    expect(itemFor('Spaces').enabled, isFalse);
    expect(itemFor('Convert to Spaces').enabled, isFalse);
    expect(itemFor('Convert to Tabs').enabled, isTrue);
  });

  testWidgets('metadata controls lock while busy or locked', (tester) async {
    final editor = controller();
    editor.setEditingLocked(true);
    await mount(tester, editor);
    final lineEnding = tester.widget<PopupMenuButton<LineEnding>>(
      find.byType(PopupMenuButton<LineEnding>),
    );
    expect(lineEnding.enabled, isFalse);
    final encoding = tester.widget<PopupMenuButton<Utf8Bom>>(
      find.byType(PopupMenuButton<Utf8Bom>),
    );
    expect(encoding.enabled, isFalse);
  });

  testWidgets('an open indentation menu cannot bypass a later lock', (
    tester,
  ) async {
    final editor = controller();
    await mount(tester, editor);
    await tester.tap(find.textContaining('Spaces:'));
    await tester.pumpAndSettle();
    editor.setEditingLocked(true);
    await tester.pump();
    await tester.tap(menuItem('Tabs'));
    await tester.pumpAndSettle();
    expect(editor.indentation.style, IndentStyle.spaces);
  });

  testWidgets(
    'narrow status scrolls to metadata controls at larger text scale',
    (tester) async {
      final editor = controller();
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(body: DocumentStatusBar(controller: editor)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-1000, 0),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('UTF-8'));
      await tester.tap(find.text('UTF-8'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('UTF-8 BOM'));
      await tester.pumpAndSettle();
      expect(editor.metadata.utf8Bom, Utf8Bom.present);
      expect(tester.takeException(), isNull);
    },
  );
}
