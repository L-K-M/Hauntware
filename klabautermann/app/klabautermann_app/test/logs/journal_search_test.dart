import 'dart:async' show unawaited;
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

    test('reads the query as a regular expression while asked (LOG-06)', () {
      final (logs, search) = _logs();
      logs.add(['GET /a 200', 'GET /b 502', 'post /c 404', 'none']);

      search
        ..setRegex(true)
        ..setQuery(r'(get|post) \S+ [45]\d\d');
      expect(search.invalidPattern, isFalse);
      expect(search.total, 2);
      expect(search.matchesIn(logs[1] as LogLine), const [
        TextMatch(start: 0, end: 10),
      ]);

      search.setCaseSensitive(true);
      expect(search.total, 1, reason: 'only the lower-case post line');

      // A pattern that matches no characters finds nothing to show.
      search
        ..setCaseSensitive(false)
        ..setQuery('x*');
      expect(search.total, 0);

      // Plain text again: the parentheses are characters.
      search
        ..setRegex(false)
        ..setQuery('(get');
      expect(search.total, 0);
      expect(search.invalidPattern, isFalse);
    });

    test('a pattern that does not compile matches nothing and says so', () {
      final (logs, search) = _logs();
      logs.add(['a (b', 'c']);
      search
        ..setRegex(true)
        ..setQuery('(b');
      expect(search.invalidPattern, isTrue);
      expect(search.total, 0);
      expect(search.matchesIn(logs[0] as LogLine), isEmpty);

      logs.add(['(b again']);
      expect(search.total, 0, reason: 'new lines are not searched either');

      search.setRegex(false);
      expect(search.invalidPattern, isFalse);
      expect(search.total, 2);
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

    group('a paused view holds its lines as fields open and close', () {
      Future<(LogViewController, LogSearch, ScrollPosition, double)> paused(
        WidgetTester tester,
        LogWrap wrap, {
        String Function(int i)? message,
        int? maxLines,
      }) async {
        final (logs, search) = _logs(maxLines: maxLines);
        await _pump(tester, logs, search, wrap: wrap);
        logs.addJournal([
          for (var i = 0; i < 100; i++) _entry(message?.call(i) ?? 'm $i'),
        ]);
        await tester.pump();
        logs.pause();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        // The newest row, one line high when it does not wrap.
        final newest = message?.call(99) ?? 'm 99';
        final line = tester.getSize(_row('nginx.service[812]: $newest')).height;
        return (logs, search, position, line);
      }

      double topOf(WidgetTester tester, int i) =>
          tester.getTopLeft(_row('nginx.service[812]: m $i')).dy;

      /// Opens row m 5's three fields in a buffer of 100 lines and puts
      /// row m [top], below them, at the top edge.
      Future<(LogViewController, ScrollPosition, double)> belowOpenFields(
        WidgetTester tester,
        LogWrap wrap,
        int top,
      ) async {
        final (logs, _, position, line) = await paused(
          tester,
          wrap,
          maxLines: 100,
        );
        position.jumpTo(5 * line);
        await tester.pump();
        await tester.tap(_row('nginx.service[812]: m 5'));
        await tester.pump();
        position.jumpTo((top + 3) * line);
        await tester.pump();
        expect(topOf(tester, top), moreOrLessEquals(0));
        return (logs, position, line);
      }

      for (final wrap in LogWrap.values) {
        testWidgets('above and at the top edge, wrap ${wrap.name}', (
          tester,
        ) async {
          final (logs, _, position, line) = await paused(tester, wrap);
          // Focus row m 37, then put row m 40 at the top edge, so m 37
          // is three rows above it.
          position.jumpTo(37 * line);
          await tester.pump();
          final above = Focus.of(
            tester.element(_row('nginx.service[812]: m 37')),
          );
          position.jumpTo(40 * line);
          await tester.pump();
          above.requestFocus();
          await tester.pump();
          expect(topOf(tester, 40), 0);

          // Row m 37 opens its three fields above the edge.
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(position.pixels, moreOrLessEquals(43 * line));
          expect(topOf(tester, 40), moreOrLessEquals(0));
          expect(topOf(tester, 41), moreOrLessEquals(line));

          // Row m 40 opens its fields beneath it and stays at the edge.
          await tester.tap(_row('nginx.service[812]: m 40'));
          await tester.pump();
          expect(topOf(tester, 40), moreOrLessEquals(0));
          expect(topOf(tester, 41), moreOrLessEquals(4 * line));

          // Both close again, and the lines in sight hold still.
          await tester.tap(_row('nginx.service[812]: m 40'));
          await tester.pump();
          above.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(_row('_PID=812'), findsNothing);
          expect(position.pixels, moreOrLessEquals(40 * line));
          expect(topOf(tester, 40), moreOrLessEquals(0));
          expect(topOf(tester, 41), moreOrLessEquals(line));
          expect(logs.following.value, isFalse);
        });

        testWidgets('a row partly above the edge keeps its place, '
            'wrap ${wrap.name}', (tester) async {
          final (logs, _, position, line) = await paused(tester, wrap);
          position.jumpTo(40.5 * line);
          await tester.pump();

          // Its line stays half above the edge, its fields beneath it.
          await tester.tap(_row('nginx.service[812]: m 40'));
          await tester.pump();
          expect(topOf(tester, 40), moreOrLessEquals(-line / 2));
          expect(topOf(tester, 41), moreOrLessEquals(3.5 * line));

          // A tap on the second field, half above the edge, closes them,
          // and the row's line takes the top again, as far above it.
          position.jumpTo(42.5 * line);
          await tester.pump();
          await tester.tap(_row('_SYSTEMD_UNIT=nginx.service'));
          await tester.pump();
          expect(_row('_PID=812'), findsNothing);
          expect(topOf(tester, 40), moreOrLessEquals(-line / 2));
          expect(logs.following.value, isFalse);
        });

        testWidgets('a field row at the top edge closes to its line there, '
            'wrap ${wrap.name}', (tester) async {
          final (logs, _, position, line) = await paused(tester, wrap);
          position.jumpTo(40 * line);
          await tester.pump();
          await tester.tap(_row('nginx.service[812]: m 40'));
          await tester.pump();

          // The first field at the edge, as repeated Up and Down steps
          // leave it: a hair below its row's boundary in floating point.
          position.jumpTo((41 - 1e-9) * line);
          await tester.pump();
          await tester.tap(_row('_PID=812'));
          await tester.pump();
          expect(_row('_PID=812'), findsNothing);
          expect(topOf(tester, 40), moreOrLessEquals(0, epsilon: 1e-6));
          expect(topOf(tester, 41), moreOrLessEquals(line, epsilon: 1e-6));
          expect(logs.following.value, isFalse);
        });

        testWidgets('lines that leave with their fields open take all their '
            'rows from above, wrap ${wrap.name}', (tester) async {
          final (logs, position, line) = await belowOpenFields(
            tester,
            wrap,
            40,
          );

          // Lines m 0 to m 9 leave, and m 5's open fields with them:
          // 13 rows.
          logs.addJournal([for (var i = 100; i < 110; i++) _entry('m $i')]);
          await tester.pump();
          expect(logs.firstSeq, 10);
          expect(position.pixels, moreOrLessEquals(30 * line));
          expect(topOf(tester, 40), moreOrLessEquals(0));
          expect(logs.following.value, isFalse);
        });

        testWidgets('an animation lands where it was aimed as lines leave '
            'with their fields open, wrap ${wrap.name}', (tester) async {
          final (logs, position, line) = await belowOpenFields(
            tester,
            wrap,
            40,
          );

          // Toward row m 60 over 200 ms, with the same 13 rows leaving
          // 60 ms in.
          unawaited(
            position.animateTo(
              (60 + 3) * line,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          logs.addJournal([for (var i = 100; i < 110; i++) _entry('m $i')]);
          await tester.pumpAndSettle();
          expect(position.pixels, moreOrLessEquals(50 * line));
          expect(topOf(tester, 60), moreOrLessEquals(0));
          expect(logs.following.value, isFalse);
        });

        testWidgets('an animation lands where it was aimed as the lines in '
            'sight leave too, wrap ${wrap.name}', (tester) async {
          final (logs, position, line) = await belowOpenFields(tester, wrap, 7);

          // Toward row m 20 over 200 ms. 20 ms in, the 13 rows leave,
          // m 7 to m 9 in sight among them: the offset stops at the
          // oldest line left, and the animation still moves by all 13.
          unawaited(
            position.animateTo(
              (20 + 3) * line,
              duration: const Duration(milliseconds: 200),
              curve: Curves.linear,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          logs.addJournal([for (var i = 100; i < 110; i++) _entry('m $i')]);
          await tester.pumpAndSettle();
          expect(position.pixels, moreOrLessEquals(10 * line));
          expect(topOf(tester, 20), moreOrLessEquals(0));
          expect(logs.following.value, isFalse);
        });
      }

      testWidgets('wrap turned on and off keeps the line at the top with '
          'fields open above it and at it', (tester) async {
        // Every row but m 37's and m 40's wraps to several rows.
        final (logs, search, position, line) = await paused(
          tester,
          LogWrap.off,
          message: (i) =>
              i == 37 || i == 40 ? 'm $i' : 'm $i ${'word ' * 30}'.trim(),
        );
        position.jumpTo(37 * line);
        await tester.pump();
        await tester.tap(_row('nginx.service[812]: m 37'));
        await tester.pump();
        // Row m 37 takes four rows, so m 40 starts at row 43.
        position.jumpTo(43 * line);
        await tester.pump();
        await tester.tap(_row('nginx.service[812]: m 40'));
        await tester.pump();
        expect(topOf(tester, 40), moreOrLessEquals(0));

        for (final wrap in [LogWrap.on, LogWrap.off]) {
          await _pump(tester, logs, search, wrap: wrap);
          expect(topOf(tester, 40), moreOrLessEquals(0), reason: wrap.name);
          expect(_row('_PID=812'), findsOneWidget, reason: wrap.name);
          expect(logs.following.value, isFalse);
        }
      });

      testWidgets('wrap turned off and on keeps the wrapped counts and the '
          'share of a top row with its fields open', (tester) async {
        // Every row but the newest wraps to several rows.
        String message(int i) =>
            i == 99 ? 'm 99' : 'm $i ${'word ' * 30}'.trim();
        final (logs, search, position, line) = await paused(
          tester,
          LogWrap.on,
          message: message,
        );
        final row37 = _row('nginx.service[812]: ${message(37)}');
        final row40 = _row('nginx.service[812]: ${message(40)}');

        // Row m 40 at the top edge opens its fields, and the edge then
        // sits halfway down its second field.
        position.jumpTo(position.maxScrollExtent * 40 / 99);
        await tester.pump();
        position.jumpTo(position.pixels + tester.getTopLeft(row40).dy);
        await tester.pump();
        await tester.tap(row40);
        await tester.pump();
        final wrapped = tester.getSize(row40).height;
        expect(wrapped, greaterThan(line));
        position.jumpTo(position.pixels + wrapped + 1.5 * line);
        await tester.pump();
        final top = tester.getTopLeft(row40).dy;
        final extent = position.maxScrollExtent;

        // Without wrap the row keeps its share of its rows: one for its
        // line and one for each field.
        await _pump(tester, logs, search);
        final share = -top / (wrapped + 3 * line);
        expect(
          tester.getTopLeft(row40).dy,
          moreOrLessEquals(-share * 4 * line, epsilon: 1e-6),
        );

        // Row m 37, above the edge, opens its three fields.
        final offset = position.pixels;
        position.jumpTo(37 * line);
        await tester.pump();
        final above = Focus.of(tester.element(row37));
        position.jumpTo(offset);
        await tester.pump();
        above.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(position.pixels, moreOrLessEquals(offset + 3 * line));

        // With wrap again, the counts from before hold, m 37's fields
        // added, and so does the top row.
        await _pump(tester, logs, search, wrap: LogWrap.on);
        expect(
          tester.getTopLeft(row40).dy,
          moreOrLessEquals(top, epsilon: 1e-6),
        );
        expect(
          position.maxScrollExtent,
          moreOrLessEquals(extent + 3 * line, epsilon: 1e-6),
        );
        expect(logs.following.value, isFalse);
      });
    });

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

    testWidgets('a focused row keeps focus while lines leave the buffer', (
      tester,
    ) async {
      final (logs, search) = _logs(maxLines: 50);
      await _pump(tester, logs, search);
      logs.addJournal([for (var i = 0; i < 50; i++) _entry('m $i')]);
      await tester.pump();
      logs.pause();
      final row = _row('nginx.service[812]: m 45');
      final focus = Focus.of(tester.element(row))..requestFocus();
      await tester.pump();

      logs.addJournal([for (var i = 50; i < 55; i++) _entry('m $i')]);
      await tester.pump();
      expect(Focus.of(tester.element(row)), same(focus));
      expect(focus.hasPrimaryFocus, isTrue);
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
