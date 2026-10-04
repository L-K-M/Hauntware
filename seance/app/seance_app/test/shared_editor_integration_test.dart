import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:seance_app/ui/built_in_text_editor.dart';

void main() {
  testWidgets('the embedded editor shares dotenv and replace behavior', (
    tester,
  ) async {
    final dirty = ValueNotifier(false);
    addTearDown(dirty.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: File('/unused/checkout'),
          remotePath: '/srv/app/.env.local',
          initialText: 'APP_NAME=old\nGREETING="old # value"\n',
          dirtyNotifier: dirty,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final surface = tester.widget<PlanchetteEditor>(
      find.byType(PlanchetteEditor),
    );
    expect(surface.controller.text.language?.id, 'dotenv');
    expect(find.byKey(const ValueKey('editor-line-gutter')), findsOneWidget);

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Find in file',
      ),
      'old',
    );
    await tester.tap(find.byTooltip('Find and replace'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Replace with',
      ),
      'new',
    );
    await tester.tap(find.text('Replace all'));
    await tester.pumpAndSettle();

    expect(
      surface.controller.text.text,
      'APP_NAME=new\nGREETING="new # value"\n',
    );
    expect(dirty.value, isTrue);
    expect(find.textContaining('Unsaved edits'), findsOneWidget);
  });

  testWidgets(
    'an open offline editor can upload after its session reconnects',
    (tester) async {
      final key = GlobalKey<BuiltInTextEditorScreenState>();
      final saved = <String>[];
      var uploads = 0;
      var reconciliations = 0;

      Widget host({Future<bool> Function()? onUpload}) => MaterialApp(
        home: BuiltInTextEditorScreen(
          key: key,
          file: File('/unused/checkout'),
          remotePath: '/etc/config.txt',
          initialText: 'original\n',
          saveDocument: (_, text) async => saved.add(text),
          onSaved: () async => reconciliations++,
          onUpload: onUpload,
        ),
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final state = key.currentState;
      final controller = tester
          .widget<PlanchetteEditor>(find.byType(PlanchetteEditor))
          .controller;
      expect(controller.canPublish, isFalse);
      await tester.enterText(find.byType(TextField), 'edited while offline\n');

      await tester.pumpWidget(
        host(
          onUpload: () async {
            uploads++;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState, same(state));
      expect(
        tester
            .widget<PlanchetteEditor>(find.byType(PlanchetteEditor))
            .controller,
        same(controller),
      );
      expect(controller.canPublish, isTrue);
      expect(controller.text.text, 'edited while offline\n');

      await tester.tap(find.byTooltip('Save and upload'));
      await tester.pumpAndSettle();

      expect(saved, ['edited while offline\n']);
      expect(uploads, 1);
      expect(reconciliations, 0);
      expect(controller.isDirty, isFalse);
      expect(find.text('Saved and uploaded.'), findsOneWidget);
    },
  );

  testWidgets(
    'an open online editor saves locally after its session goes offline',
    (tester) async {
      final key = GlobalKey<BuiltInTextEditorScreenState>();
      final saved = <String>[];
      var uploads = 0;
      var onlineReconciliations = 0;
      var offlineReconciliations = 0;

      Widget host({required bool online}) => MaterialApp(
        home: BuiltInTextEditorScreen(
          key: key,
          file: File('/unused/checkout'),
          remotePath: '/etc/config.txt',
          initialText: 'original\n',
          saveDocument: (_, text) async => saved.add(text),
          onSaved: online
              ? () async => onlineReconciliations++
              : () async => offlineReconciliations++,
          onUpload: online
              ? () async {
                  uploads++;
                  return true;
                }
              : null,
        ),
      );

      await tester.pumpWidget(host(online: true));
      await tester.pumpAndSettle();
      final state = key.currentState;
      final controller = tester
          .widget<PlanchetteEditor>(find.byType(PlanchetteEditor))
          .controller;
      expect(controller.canPublish, isTrue);
      await tester.enterText(
        find.byType(TextField),
        'edited before disconnect\n',
      );

      await tester.pumpWidget(host(online: false));
      await tester.pumpAndSettle();
      expect(key.currentState, same(state));
      expect(controller.canPublish, isFalse);
      expect(find.byTooltip('Save and upload'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(saved, ['edited before disconnect\n']);
      expect(uploads, 0);
      expect(onlineReconciliations, 0);
      expect(offlineReconciliations, 1);
      expect(controller.isDirty, isFalse);
      expect(find.text('Saved locally.'), findsOneWidget);
    },
  );
}
