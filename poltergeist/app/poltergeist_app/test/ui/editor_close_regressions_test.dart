import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart' as pe;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/quit_guard.dart';
import 'package:poltergeist_app/ui/built_in_text_editor.dart';

void main() {
  late ValueNotifier<bool> quitPending;
  late GlobalKey<NavigatorState> navigatorKey;
  Future<bool> Function()? closeGuard;
  late List<String> writes;
  late List<String> toasts;
  late int reconciles;

  setUp(() {
    quitPending = ValueNotifier(false);
    navigatorKey = GlobalKey<NavigatorState>();
    closeGuard = null;
    writes = [];
    toasts = [];
    reconciles = 0;
  });

  tearDown(() => quitPending.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Future<String> Function(File, String)? saveDocument,
    Future<bool> Function()? onUpload,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder<bool>(
          valueListenable: quitPending,
          builder: (_, pending, _) => BuiltInTextEditorScreen(
            file: File('/unused/config.txt'),
            initialText: 'original',
            saveDocument:
                saveDocument ??
                (_, text) async {
                  writes.add(text);
                  return 'baseline';
                },
            onUpload: onUpload,
            onSaved: () async => reconciles++,
            quitPending: pending,
            onCloseRequested: () async {},
            onCloseGuardChanged: (guard) => closeGuard = guard,
            showToast: (_, message) => toasts.add(message),
            monoFontFallback: const ['monospace'],
            basenameOf: (_) => 'config.txt',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'edited');
    await tester.pump();
  }

  pe.EditorController controller(WidgetTester tester) => tester
      .widget<pe.PlanchetteEditor>(find.byType(pe.PlanchetteEditor))
      .controller;

  QuitGuard quitGuard() => QuitGuard(
    navigatorKey: navigatorKey,
    confirmEditorsClose: () => closeGuard!(),
    setEditorQuitPending: (pending) => quitPending.value = pending,
  )..bindQueue(() => null);

  Future<void> chooseSave(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(find.text('Save changes to “config.txt”?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('Quit explicit Save writes after editing becomes locked', (
    tester,
  ) async {
    await mount(tester);
    expect(controller(tester).isDirty, isTrue);
    expect(quitPending.value, isFalse);

    final quitting = quitGuard().confirmClose();
    await tester.pumpAndSettle();
    expect(quitPending.value, isTrue);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);

    // Invoke the actual bindings even while the dialog owns keyboard focus.
    final shortcuts = tester
        .widgetList<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .singleWhere(
          (widget) => widget.bindings.containsKey(
            const SingleActivator(LogicalKeyboardKey.keyS, control: true),
          ),
        );
    for (final shortcut in const [
      SingleActivator(LogicalKeyboardKey.keyS, control: true),
      SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true),
    ]) {
      shortcuts.bindings[shortcut]!();
    }
    await tester.pumpAndSettle();
    expect(writes, isEmpty);

    await chooseSave(tester);
    expect(await quitting, isTrue);
    expect(writes, ['edited']);
    expect(reconciles, 1);
    expect(controller(tester).isDirty, isFalse);
    expect(toasts, ['Saved locally.']);
  });

  for (final throws in [false, true]) {
    testWidgets(
      '${throws ? 'Throwing' : 'Cancelled'} upload refuses close after local write',
      (tester) async {
        var uploads = 0;
        await mount(
          tester,
          onUpload: () async {
            uploads++;
            if (throws) throw StateError('connection lost');
            return false;
          },
        );

        final closing = closeGuard!();
        await chooseSave(tester);
        expect(await closing, isFalse);
        expect(writes, ['edited']);
        expect(uploads, 1);
        expect(reconciles, 1);
        expect(controller(tester).isDirty, isFalse);
        expect(controller(tester).text.text, 'edited');
        expect(find.byType(BuiltInTextEditorScreen), findsOneWidget);
        expect(
          toasts.single,
          throws ? contains('connection lost') : 'Saved locally; not uploaded.',
        );
        await tester.enterText(find.byType(TextField), 'keep editing');
        expect(controller(tester).isDirty, isTrue);
      },
    );
  }

  for (final upload in [false, true]) {
    testWidgets(
      'Successful ${upload ? 'upload' : 'local-only Save'} authorizes close',
      (tester) async {
        var uploads = 0;
        await mount(
          tester,
          onUpload: upload
              ? () async {
                  uploads++;
                  return true;
                }
              : null,
        );

        final closing = closeGuard!();
        await chooseSave(tester);
        expect(await closing, isTrue);
        expect(writes, ['edited']);
        expect(uploads, upload ? 1 : 0);
        expect(reconciles, upload ? 0 : 1);
        expect(controller(tester).isDirty, isFalse);
        expect(toasts, [upload ? 'Saved and uploaded.' : 'Saved locally.']);
      },
    );
  }

  testWidgets('Failed Quit save vetoes closing and restores editing', (
    tester,
  ) async {
    var attempts = 0;
    var uploads = 0;
    await mount(
      tester,
      saveDocument: (_, _) async {
        attempts++;
        throw StateError('disk full');
      },
      onUpload: () async {
        uploads++;
        return true;
      },
    );

    final quitting = quitGuard().confirmClose();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    await chooseSave(tester);
    expect(await quitting, isFalse);
    await tester.pump();
    expect(attempts, 1);
    expect(writes, isEmpty);
    expect(uploads, 0);
    expect(reconciles, 0);
    expect(toasts.single, contains('disk full'));
    expect(controller(tester).isDirty, isTrue);
    expect(controller(tester).text.text, 'edited');
    expect(quitPending.value, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    await tester.enterText(find.byType(TextField), 'after failure');
    expect(controller(tester).text.text, 'after failure');
  });

  testWidgets('Successful upload cannot discard newer dirty edits', (
    tester,
  ) async {
    final upload = Completer<bool>();
    await mount(tester, onUpload: () => upload.future);
    final closing = closeGuard!();
    await chooseSave(tester);
    expect(writes, ['edited']);
    expect(controller(tester).isSaving, isTrue);

    // Model a newer buffer update arriving after the saved snapshot.
    controller(tester).text.text = 'newer edits';
    upload.complete(true);
    await tester.pumpAndSettle();
    expect(await closing, isFalse);
    expect(controller(tester).text.text, 'newer edits');
    expect(controller(tester).isDirty, isTrue);
    expect(reconciles, 0);
  });

  testWidgets('Native close refuses an in-flight save', (tester) async {
    final save = Completer<String>();
    var attempts = 0;
    await mount(
      tester,
      saveDocument: (_, _) {
        attempts++;
        return save.future;
      },
    );
    await tester.tap(find.byTooltip('Save locally'));
    await tester.pump();
    final refused = await closeGuard!();
    save.complete('baseline');
    await tester.pumpAndSettle();

    expect(refused, isFalse);
    expect(attempts, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(reconciles, 1);
  });
}
