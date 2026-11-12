import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

/// Pumps a button that opens the dialog through [show].
Future<void> pumpDialog(
  WidgetTester tester, {
  required Future<GhostCloseChoice?> Function(BuildContext context) show,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => show(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('orders Don’t save, Cancel, Save and focuses Save', (
    tester,
  ) async {
    GhostCloseChoice? answer;
    await pumpDialog(
      tester,
      show: (context) async => answer = await showGhostCloseDialog(
        context,
        title: 'Save changes to “notes.txt”?',
        body: 'Changes not saved will be lost.',
      ),
    );

    final dontSave = find.widgetWithText(TextButton, 'Don’t save');
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(dontSave, findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(save, findsOneWidget);
    expect(
      tester.getTopLeft(dontSave).dx,
      lessThan(tester.getTopLeft(cancel).dx),
    );
    expect(tester.getTopLeft(cancel).dx, lessThan(tester.getTopLeft(save).dx));
    expect(tester.widget<FilledButton>(save).autofocus, isTrue);

    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(answer, GhostCloseChoice.save);
  });

  for (final (label, choice) in [
    ('Don’t save', GhostCloseChoice.dontSave),
    ('Cancel', GhostCloseChoice.cancel),
    ('Save', GhostCloseChoice.save),
  ]) {
    testWidgets('answers $choice for $label', (tester) async {
      GhostCloseChoice? answer;
      await pumpDialog(
        tester,
        show: (context) async => answer = await showGhostCloseDialog(
          context,
          title: 'Save changes to “notes.txt”?',
          body: 'Changes not saved will be lost.',
        ),
      );

      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(answer, choice);
    });
  }

  testWidgets('uses the injected labels', (tester) async {
    GhostCloseChoice? answer;
    await pumpDialog(
      tester,
      show: (context) async => answer = await showGhostCloseDialog(
        context,
        title: 'Save changes to “notes.txt”?',
        body: 'Changes not saved will be lost.',
        saveLabel: 'Keep',
        dontSaveLabel: 'Drop',
        cancelLabel: 'Stay',
      ),
    );

    expect(find.text('Keep'), findsOneWidget);
    expect(find.text('Drop'), findsOneWidget);
    expect(find.text('Stay'), findsOneWidget);
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();
    expect(answer, GhostCloseChoice.dontSave);
  });

  testWidgets('a reload can hide Save and focus Cancel', (tester) async {
    GhostCloseChoice? answer;
    await pumpDialog(
      tester,
      show: (context) async => answer = await showGhostCloseDialog(
        context,
        title: 'Save changes?',
        body: 'The server copy is being reloaded.',
        showSave: false,
      ),
    );

    expect(find.byType(FilledButton), findsNothing);
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    expect(tester.widget<TextButton>(cancel).autofocus, isTrue);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(answer, GhostCloseChoice.cancel);
  });

  testWidgets('a dismissal answers null', (tester) async {
    GhostCloseChoice? answer;
    await pumpDialog(
      tester,
      show: (context) async => answer = await showGhostCloseDialog(
        context,
        title: 'Save changes to “notes.txt”?',
        body: 'Changes not saved will be lost.',
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(answer, isNull);
  });
}
