import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:seance_app/ui/built_in_text_editor.dart';

/// The shared text-tools catalog behind the header icon: the browser opens,
/// a run keeps the buffer's own line endings, locks stop runs without
/// stopping browsing, and the byte preflight follows Séance's conditional
/// saved-EOL policy.
void main() {
  const tooltip = 'Browse Text Tools…';

  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-text-tools-');
    file = File('${directory.path}/notes.txt');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  EditorController controllerOf(WidgetTester tester) =>
      tester.widget<PlanchetteEditor>(find.byType(PlanchetteEditor)).controller;

  /// A checkout-driven screen reads the file on the real event loop, so the
  /// load is awaited in runAsync before the fake-async pumps take over.
  Future<EditorController> pumpLoaded(
    WidgetTester tester,
    String content,
  ) async {
    await tester.runAsync(() async {
      await file.writeAsString(content);
      await tester.pumpWidget(
        MaterialApp(
          home: BuiltInTextEditorScreen(
            file: file,
            remotePath: '/srv/notes.txt',
          ),
        ),
      );
      await controllerOf(tester).initialize();
    });
    await tester.pumpAndSettle();
    return controllerOf(tester);
  }

  testWidgets('the header icon opens the browser and runs a tool', (
    tester,
  ) async {
    final controller = await pumpLoaded(tester, 'b\r\n\r\na\r\n');

    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
    expect(controller.textToolsOpen, isTrue);
    expect(find.text('Text Tools'), findsOneWidget);

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Filter tools',
      ),
      'remove blank',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Blank Lines'));
    await tester.pumpAndSettle();

    // Preserve policy: the dropped line's separator goes with it and the
    // remaining breaks stay CRLF, as the managed save writes them.
    expect(controller.text.text, 'b\r\na\r\n');
    expect(controller.isDirty, isTrue);
    expect(controller.textToolsOpen, isFalse);
    expect(find.textContaining('Remove Blank Lines:'), findsOneWidget);
  });

  testWidgets('a 320 px phone at doubled text scale browses without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(
      () => tester.platformDispatcher.clearTextScaleFactorTestValue(),
    );

    final controller = await pumpLoaded(tester, 'hello\n');

    // The tap must really land: a clipped or pushed-out button is the
    // narrow-layout regression this test exists to catch.
    expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.textToolsOpen, isTrue);
  });

  testWidgets('an editing lock browses with disabled rows and Escape closes', (
    tester,
  ) async {
    final controller = await pumpLoaded(tester, 'b\na\n');

    // The reload path holds this lock while it refreshes the checkout.
    controller.editingLocked = true;
    await tester.pump();
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
    expect(controller.textToolsOpen, isTrue);

    // The list scrolls; the filter brings the row on screen so its
    // disabled state is observable.
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Filter tools',
      ),
      'remove blank',
    );
    await tester.pumpAndSettle();
    final row = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Remove Blank Lines'),
        matching: find.byType(ListTile),
      ),
    );
    expect(row.enabled, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.textToolsOpen, isFalse);
    expect(controller.text.text, 'b\na\n');
  });

  testWidgets('the byte preflight folds stray breaks like the managed save', (
    tester,
  ) async {
    // Two CRLF breaks against one stray LF: the loader reports CRLF, so the
    // save folds the stray LF too. The controller's saved-size count must
    // agree with those bytes, not the raw buffer's.
    final controller = await pumpLoaded(tester, 'a\r\nb\nc\r\n');

    expect(controller.text.text, 'a\r\nb\nc\r\n');
    expect(controller.bufferLineEnding, LineEnding.crlf);
    expect(controller.fileByteCount, 9);
    expect(utf8.encode(controller.text.text).length, 8);
  });

  testWidgets('an LF-dominant buffer counts its stray CRLF raw', (
    tester,
  ) async {
    // The other branch of the conditional save: an LF document's breaks
    // stay as they are, so the saved size is the raw buffer's bytes.
    final controller = await pumpLoaded(tester, 'a\nb\r\nc\n');

    expect(controller.bufferLineEnding, LineEnding.lf);
    expect(controller.fileByteCount, 7);
    expect(utf8.encode(controller.text.text).length, 7);
  });

  test(
    'a growing tool is refused once the folded bytes pass the cap',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // The screen's wiring is pinned above; this locks the policy itself to
      // the conditional saver, with the cap shrunk so the refusal is cheap.
      final controller = EditorController(
        displayPath: 'notes.txt',
        initialText: 'a\nb\n',
        normalization: TextNormalization.preserve,
        saveNormalizationForLineEnding: seanceSaveNormalization,
        maximumBytes: 7,
        undoQuiet: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.setMetadata(
        const TextDocumentMetadata(lineEnding: LineEnding.crlf),
      );
      expect(controller.fileByteCount, 6);
      expect(
        await controller.runTextTool(
          'prefixSuffixLines',
          options: {'text': 'x'},
        ),
        isA<TextToolRefused>(),
      );
      expect(controller.text.text, 'a\nb\n');
    },
  );
}
