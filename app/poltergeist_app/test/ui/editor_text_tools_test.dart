import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/built_in_text_editor.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// The editor header's text-tools entry (the shared browser): opening,
/// locking, filtering, running tools, the post-run notice, narrow windows,
/// and the normalize-policy contract with the loader and saver.

/// The browser's own scrollable: the document's scroll view must not
/// steal the drag when the catalog needs scrolling.
final _browserScrollable = find.descendant(
  of: find.byType(ListView),
  matching: find.byType(Scrollable),
);

const _sample = 'beta\nalpha\ngamma\nalpha\n';

Future<void> _mount(WidgetTester tester, {bool quitPending = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BuiltInTextEditorScreen(
        file: File('/tmp/notes.txt'),
        initialText: _sample,
        onCloseRequested: quitPending ? () async {} : null,
        onQuitRequested: quitPending ? () async {} : null,
        onNewWindowRequested: quitPending ? () async {} : null,
        quitPending: quitPending,
        showToast: (_, _) {},
        monoFontFallback: poltergeistMonoFontFamilies,
        basenameOf: remoteBasename,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openBrowser(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Text Tools'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the header icon opens and closes the browser', (tester) async {
    await _mount(tester);
    await _openBrowser(tester);
    expect(find.text('Text Tools'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Filter tools'),
      findsOneWidget,
    );
    expect(find.text('Sort Lines…'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('UPPERCASE'),
      200,
      scrollable: _browserScrollable,
    );
    expect(find.text('UPPERCASE'), findsOneWidget);

    await tester.tap(find.byTooltip('Close text tools'));
    await tester.pumpAndSettle();
    expect(find.text('Text Tools'), findsNothing);
    expect(find.text('Sort Lines…'), findsNothing);
  });

  testWidgets('the icon is disabled while the document loads', (tester) async {
    // The missing file's load never completes in the fake clock, so the
    // loading state holds the icon off; one pump is enough to see it.
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BuiltInTextEditorScreen(
          file: File('/nonexistent-dir-7f3a/notes.txt'),
          showToast: (_, _) {},
          monoFontFallback: poltergeistMonoFontFamilies,
          basenameOf: remoteBasename,
        ),
      ),
    );
    await tester.pump();
    final icon = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.construction_outlined),
    );
    expect(icon.onPressed, isNull);
  });

  testWidgets('a locked document still browses, with rows disabled', (
    tester,
  ) async {
    await _mount(tester, quitPending: true);
    await _openBrowser(tester);
    expect(find.text('Text Tools'), findsOneWidget);
    final row = tester.widget<ListTile>(find.widgetWithText(
      ListTile,
      'Sort Lines…',
    ));
    expect(row.enabled, isFalse);
    expect(row.onTap, isNull);
  });

  testWidgets('the browser filters through the ARB keywords', (tester) async {
    await _mount(tester);
    await _openBrowser(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Filter tools'),
      'dedupe',
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove Duplicate Lines…'), findsOneWidget);
    expect(find.text('Sort Lines…'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextField, 'Filter tools'),
      'nothing matches this',
    );
    await tester.pumpAndSettle();
    expect(find.text('No tools match.'), findsOneWidget);
  });

  testWidgets('a tool without options runs and leaves the ARB notice', (
    tester,
  ) async {
    await _mount(tester);
    await _openBrowser(tester);
    await tester.scrollUntilVisible(
      find.text('UPPERCASE'),
      200,
      scrollable: _browserScrollable,
    );
    await tester.tap(find.text('UPPERCASE'));
    // The run waits out Flutter's undo-merge window before it applies.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    // With the caret at the start and nothing selected, the tool scopes
    // itself to the word under it.
    expect(
      find.widgetWithText(TextField, 'BETA\nalpha\ngamma\nalpha\n'),
      findsOneWidget,
    );
    expect(
      find.text('UPPERCASE: uppercased 4 characters in the word.'),
      findsOneWidget,
    );

    // The notice's Undo restores the buffer through the shared controller.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, _sample),
      findsOneWidget,
    );
  });

  testWidgets('the tool bar previews and applies a catalog tool', (
    tester,
  ) async {
    await _mount(tester);
    await _openBrowser(tester);
    await tester.tap(find.text('Sort Lines…'));
    await tester.pumpAndSettle();
    expect(find.text('Applies to'), findsOneWidget);
    expect(find.text('Nothing selected: whole document, 4 lines'),
        findsOneWidget);
    expect(find.text('Order'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('alpha\nalpha\nbeta\ngamma\n'), findsOneWidget);
    expect(
      find.textContaining('Sort Lines: moved'),
      findsOneWidget,
    );
  });

  testWidgets('the browser and tool bar fit a phone-width window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _mount(tester);
    await _openBrowser(tester);
    expect(find.text('Text Tools'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Sort Lines…'),
      200,
      scrollable: _browserScrollable,
    );
    await tester.tap(find.text('Sort Lines…'));
    await tester.pumpAndSettle();
    expect(find.text('Applies to'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
  });

  testWidgets('a normalized edit keeps the document CRLF and BOM on save', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('pg-text-tools-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/crlf.txt');
    // BOM + CRLF: the loader normalizes the buffer to LF and keeps the
    // bytes as metadata; the saver must restore both.
    file.writeAsBytesSync([
      0xEF, 0xBB, 0xBF, ...utf8.encode('one\r\ntwo\r\n'),
    ]);

    // The load and save ride real I/O, so the drive runs where the event
    // loop really turns; the assertions read the settled tree after.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BuiltInTextEditorScreen(
            file: file,
            onCloseRequested: () async {},
            onQuitRequested: () async {},
            onNewWindowRequested: () async {},
            showToast: (_, _) {},
            monoFontFallback: poltergeistMonoFontFamilies,
            basenameOf: remoteBasename,
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    // The status row reports the normalized buffer: LF breaks, no mark.
    expect(find.text('3 lines · 8 bytes'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'one\ntwo\n'),
      'uno\ntwo\n',
    );
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Save locally'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    final saved = file.readAsBytesSync();
    expect(saved, [0xEF, 0xBB, 0xBF, ...utf8.encode('uno\r\ntwo\r\n')]);
  });
}
