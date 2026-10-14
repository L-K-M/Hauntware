import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/logs/log_level.dart';
import 'package:klabautermann_app/ui/logs/log_search.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_core/planchette_core.dart' show TextMatch;

JournalEntry _entry(
  String message, {
  String unit = 'nginx.service',
  int pid = 812,
  int priority = 6,
  Map<String, String?> more = const {},
}) => JournalEntry({
  'PRIORITY': '$priority',
  '_SYSTEMD_UNIT': unit,
  '_PID': '$pid',
  ...more,
  'MESSAGE': message,
});

/// A controller and a search over it, disposed after the test.
(LogViewController, LogSearch) _logs({int? maxLines}) {
  final logs = LogViewController(
    buffer: maxLines == null ? null : LogBuffer(maxLines: maxLines),
  );
  final search = LogSearch(logs);
  addTearDown(() {
    search.dispose();
    logs.dispose();
  });
  return (logs, search);
}

Future<void> _pump(
  WidgetTester tester,
  LogViewController logs,
  LogSearch search, {
  LogWrap wrap = LogWrap.off,
  Size size = const Size(480, 240),
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: brightness == Brightness.dark
          ? GhostTheme.dark(
              klabautermannThemeStyle,
              platform: TargetPlatform.linux,
            )
          : GhostTheme.light(
              klabautermannThemeStyle,
              platform: TargetPlatform.linux,
            ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Material(
        child: LogView(
          controller: logs,
          wrap: wrap,
          levelOf: LogLevel.ofJournalLine,
          search: search,
        ),
      ),
    ),
  );
}

Finder _row(String text) => find.text(text, findRichText: true);

void main() {
  group('LogSearch (LOG-05)', () {
    test('counts matches in the loaded lines, ignoring case unless asked', () {
      final (logs, search) = _logs();
      logs.add(['Disk full', 'disk ok', 'DISK DISK', 'net']);

      search.setQuery('disk');
      expect(search.total, 4);
      expect(search.matchesIn(logs[2] as LogLine), const [
        TextMatch(start: 0, end: 4),
        TextMatch(start: 5, end: 9),
      ]);
      expect(search.matchesIn(logs[3] as LogLine), isEmpty);

      search.setCaseSensitive(true);
      expect(search.total, 1);
      expect(search.matchesIn(logs[0] as LogLine), isEmpty);
    });

    test('steps through every match and wraps around', () {
      final (logs, search) = _logs();
      logs.add(['a x', 'b', 'x x']);
      search.setQuery('x');

      final visited = [
        for (var i = 0; i < 4; i++) (search..next()).currentNumber,
      ];
      expect(visited, [1, 2, 3, 1]);
      expect(search.current, (seq: 0, index: 0));
      search.previous();
      expect(search.current, (seq: 2, index: 1));
      expect(search.steps, 5);

      search.setQuery('x x');
      expect(search.current, isNull);
      search.previous();
      expect(search.current, (seq: 2, index: 0));
    });

    test('keeps up as lines arrive and leave', () {
      final (logs, search) = _logs(maxLines: 3);
      logs.add(['x', 'b']);
      search
        ..setQuery('x')
        ..next();
      expect(search.current, (seq: 0, index: 0));

      logs.add(['x x', 'c']);
      expect(search.total, 2);
      expect(search.current, isNull, reason: 'its line left the buffer');

      logs.clear();
      expect(search.total, 0);
    });

    test('reads a journal row\'s unit and PID with its message', () {
      final (logs, search) = _logs();
      logs.addJournal([_entry('started')]);

      search.setQuery('service[812]: st');
      expect(search.matchesIn(logs[0] as LogLine), const [
        TextMatch(start: 6, end: 22),
      ]);
    });
  });

  group('journal rows (LOG-01)', () {
    testWidgets('show unit, PID and message; the priority sets the level', (
      tester,
    ) async {
      final (logs, search) = _logs();
      await _pump(tester, logs, search);
      logs.addJournal([_entry('bind() failed', priority: 3)]);
      await tester.pump();

      expect(_row('nginx.service[812]: bind() failed'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    for (final wrap in LogWrap.values) {
      testWidgets('a tap shows the fields beneath, another hides them, '
          'wrap ${wrap.name}', (tester) async {
        final semantics = tester.ensureSemantics();
        final (logs, search) = _logs();
        await _pump(tester, logs, search, wrap: wrap);
        logs.addJournal([
          _entry(
            'first',
            more: {'CODE_LINE': null, 'CODE_FUNC': 'run ${'x' * 80}'},
          ),
          _entry('second'),
        ]);
        await tester.pump();
        final second = tester.getTopLeft(_row('nginx.service[812]: second'));

        await tester.tap(_row('nginx.service[812]: first'));
        await tester.pump();

        expect(logs.following.value, isFalse);
        expect(_row('_PID=812'), findsOneWidget);
        expect(_row('CODE_LINE [not sent: over 4,096 bytes]'), findsOneWidget);
        expect(
          tester.getSemantics(_row('nginx.service[812]: first')),
          matchesSemantics(
            isExpanded: true,
            hasExpandedState: true,
            hasTapAction: true,
            hasFocusAction: true,
            isFocusable: true,
            // The fields are read with the row, one line each.
            label: [
              'nginx.service[812]: first',
              'PRIORITY=6',
              '_SYSTEMD_UNIT=nginx.service',
              '_PID=812',
              'CODE_LINE [not sent: over 4,096 bytes]',
              'CODE_FUNC=run ${'x' * 80}',
            ].join('\n'),
            onTapHint: 'Hide fields',
          ),
        );
        // The next row starts where the last field's rows end.
        final lastField = _row('CODE_FUNC=run ${'x' * 80}');
        final paragraph = tester.renderObject<RenderParagraph>(lastField);
        expect(
          paragraph.textSize.height,
          wrap == LogWrap.on ? greaterThan(20) : lessThan(20),
        );
        expect(
          tester.getTopLeft(_row('nginx.service[812]: second')).dy,
          moreOrLessEquals(tester.getBottomLeft(lastField).dy),
        );

        // Enter on the focused row hides them again.
        Focus.of(
          tester.element(_row('nginx.service[812]: first')),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(_row('_PID=812'), findsNothing);
        expect(tester.getTopLeft(_row('nginx.service[812]: second')), second);
        semantics.dispose();
      });

      testWidgets('Enter opens and closes the fields and the row keeps '
          'focus, wrap ${wrap.name}', (tester) async {
        final semantics = tester.ensureSemantics();
        final (logs, search) = _logs();
        await _pump(tester, logs, search, wrap: wrap);
        logs.addJournal([for (var i = 0; i < 100; i++) _entry('m $i')]);
        await tester.pump();
        final row = _row('nginx.service[812]: m 95');
        final focus = Focus.of(tester.element(row))..requestFocus();
        await tester.pump();
        final id = tester.getSemantics(row).id;

        for (final open in [true, false]) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(_row('_PID=812'), open ? findsOneWidget : findsNothing);
          expect(focus.hasPrimaryFocus, isTrue);
          expect(tester.getSemantics(row).id, id);
        }

        // The view's own keys still work from the row.
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        final pixels = position.pixels;
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.pump();
        expect(position.pixels, lessThan(pixels));
        semantics.dispose();
      });
    }

    testWidgets('a tap on a row that just left the buffer does nothing', (
      tester,
    ) async {
      final (logs, search) = _logs(maxLines: 5);
      await _pump(tester, logs, search);
      logs.addJournal([for (var i = 0; i < 5; i++) _entry('m $i')]);
      await tester.pump();
      final onTap = tester
          .widget<InkWell>(
            find.ancestor(
              of: _row('nginx.service[812]: m 0'),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!;

      // The row's entry leaves before the next frame rebuilds the row.
      logs.addJournal([_entry('m 5')]);
      expect(onTap, returnsNormally);
      expect(logs.following.value, isTrue);
      await tester.pump();
      expect(_row('_PID=812'), findsNothing);
    });
  });

  testWidgets('a step to a match pauses the view and shows it (LOG-05)', (
    tester,
  ) async {
    final (logs, search) = _logs();
    await _pump(tester, logs, search);
    logs.add([for (var i = 0; i < 100; i++) i == 10 ? 'a Needle' : 'l $i']);
    await tester.pump();

    search.setQuery('needle');
    await tester.pump();
    expect(_row('a Needle'), findsNothing, reason: 'still following');

    search.next();
    await tester.pump();

    expect(logs.following.value, isFalse);
    expect(_row('a Needle'), findsOneWidget);
    final runs = (tester.widget<RichText>(_row('a Needle')).text as TextSpan)
        .children!
        .cast<TextSpan>();
    expect(runs.map((run) => run.text), ['a ', 'Needle']);
    expect(runs.last.style!.backgroundColor, isNotNull);
    expect(runs.last.style!.decoration, TextDecoration.underline);
  });

  group('golden', () {
    // Linux only, as the log view's own goldens.
    final skip = !Platform.isLinux;

    for (final brightness in Brightness.values) {
      testWidgets('journal rows, fields and matches, ${brightness.name}', (
        tester,
      ) async {
        final (logs, search) = _logs();
        await _pump(
          tester,
          logs,
          search,
          brightness: brightness,
          size: const Size(480, 260),
        );
        logs.addJournal([
          _entry('Started nginx', unit: 'init.scope', pid: 1, priority: 5),
          _entry('upstream timed out', priority: 4),
          _entry('worker exited', priority: 3, more: {'CODE_LINE': '42'}),
          _entry('upstream ok'),
        ]);
        await tester.pump();
        await tester.tap(_row('nginx.service[812]: worker exited'));
        search
          ..setQuery('upstream')
          ..next();
        await tester.pump();

        await expectLater(
          find.byType(LogView),
          matchesGoldenFile('goldens/journal_search_${brightness.name}.png'),
        );
      }, skip: skip);
    }
  });
}
