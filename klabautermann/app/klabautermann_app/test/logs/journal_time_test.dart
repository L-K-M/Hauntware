// LOG-01's time column for journal rows, in the zone the time display
// picks (A11Y-07), and LOG-05's window around a current match the row
// would not show without wrap.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/time_display.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/logs/log_export.dart';
import 'package:klabautermann_app/ui/logs/log_level.dart';
import 'package:klabautermann_app/ui/logs/log_search.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';
import 'package:klabautermann_app/ui/time_display.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

const _server = 'srv-1';

/// 2026-10-15 09:05:07 UTC.
final _written = DateTime.utc(2026, 10, 15, 9, 5, 7);

JournalEntry _entry(
  String message, {
  int second = 0,
  int pid = 812,
  int priority = 6,
}) => JournalEntry({
  '__REALTIME_TIMESTAMP':
      '${_written.add(Duration(seconds: second)).microsecondsSinceEpoch}',
  'PRIORITY': '$priority',
  '_SYSTEMD_UNIT': 'nginx.service',
  '_PID': '$pid',
  'MESSAGE': message,
});

/// A controller for [_server] and a search over it, disposed after the
/// test.
(LogViewController, LogSearch) _logs() {
  final logs = LogViewController(serverId: _server);
  final search = LogSearch(logs);
  addTearDown(() {
    search.dispose();
    logs.dispose();
  });
  return (logs, search);
}

/// A time display showing server times; [_pump] gives [_server] its
/// zone.
TimeDisplayController _serverTimes() {
  final display = TimeDisplayController(display: TimeDisplay.server);
  addTearDown(display.dispose);
  return display;
}

Future<void> _pump(
  WidgetTester tester,
  LogViewController logs,
  LogSearch search, {
  required TimeDisplayController display,
  String zone = '+0000',
  LogWrap wrap = LogWrap.off,
  Size size = const Size(480, 240),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final profile = ValueNotifier<HostProfile?>(HostProfile(zoneOffset: zone));
  addTearDown(profile.dispose);

  await tester.pumpWidget(
    TimeDisplayScope(
      display: display,
      serverProfile: (_) => profile,
      child: MaterialApp(
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Material(
          child: LogView(
            controller: logs,
            wrap: wrap,
            levelOf: LogLevel.ofJournalLine,
            search: search,
          ),
        ),
      ),
    ),
  );
  // The view hands the controller the zone after its first frame.
  await tester.pump();
}

/// The text a row draws, an ellipsis standing for what a window hides.
String _drawn(RichText row) =>
    row.text.toPlainText(includeSemanticsLabels: false);

/// The row whose drawn text contains [text].
Finder _row(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && _drawn(widget).contains(text),
);

String _drawnOf(WidgetTester tester, String text) =>
    _drawn(tester.widget<RichText>(_row(text)));

/// [at] on this device's wall clock as a row shows it.
String _local(DateTime at) {
  final local = at.toLocal();
  String two(int value) => '$value'.padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

void main() {
  group('the time column (LOG-01)', () {
    testWidgets('shows at the server\'s zone, or this device\'s, in the row '
        'that search and export read', (tester) async {
      final (logs, search) = _logs();
      final display = _serverTimes();
      await _pump(tester, logs, search, display: display, zone: '+1245');
      logs.addJournal([_entry('started'), _entry('ready', second: 1)]);
      await tester.pump();

      // 09:05:07 UTC is 21:50:07 at +12:45.
      const row = '2026-10-15 21:50:07 nginx.service[812]: started';
      expect(find.text(row, findRichText: true), findsOneWidget);
      search.setQuery('21:50:08');
      expect(search.total, 1);
      expect(logExportLines(logs, dropped: (count) => '$count dropped'), [
        row,
        '2026-10-15 21:50:08 nginx.service[812]: ready',
      ]);

      // This device's zone: the rows, the search and the export follow
      // together.
      await display.setTimeDisplay(TimeDisplay.device);
      await tester.pump();
      await tester.pump();
      expect(logs.zoneOffset, isNull);
      final local = '${_local(_written)} nginx.service[812]: started';
      expect(find.text(local, findRichText: true), findsOneWidget);
      expect(
        logExportLines(logs, dropped: (count) => '$count dropped').first,
        local,
      );
      search.setQuery(_local(_written).substring(11));
      expect(search.total, 1);
    });

    testWidgets('a screen reader hears the time once with the row', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (logs, search) = _logs();
      await _pump(tester, logs, search, display: _serverTimes());
      logs.addJournal([_entry('started')]);
      await tester.pump();

      const row = '2026-10-15 09:05:07 nginx.service[812]: started';
      final label = tester.getSemantics(_row(row)).label;
      expect(label, row);
      expect('09:05:07'.allMatches(label), hasLength(1));
      semantics.dispose();
    });

    for (final (width, scale) in [(320.0, 2.0), (360.0, 3.0), (480.0, 1.0)]) {
      for (final wrap in LogWrap.values) {
        testWidgets('rows line up and stack as measured at ${width.toInt()} '
            'px and ${scale}x, wrap ${wrap.name}', (tester) async {
          final (logs, search) = _logs();
          await _pump(
            tester,
            logs,
            search,
            display: _serverTimes(),
            wrap: wrap,
            size: Size(width, 2000),
            textScale: scale,
          );
          logs.addJournal([
            _entry('started', pid: 1),
            _entry('ready ${'x' * 40}', second: 52, pid: 45678),
            _entry('done', second: 59),
          ]);
          await tester.pump();

          final rows = [
            for (final text in ['started', 'ready', 'done'])
              tester.renderObject<RenderParagraph>(_row(text)),
          ];
          final line = rows.first.size.height;
          double caretX(RenderParagraph row, int offset) =>
              row.localToGlobal(Offset.zero).dx +
              row.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dx;

          // Every row's minutes start in one column.
          expect(caretX(rows[1], 14), moreOrLessEquals(caretX(rows[0], 14)));
          expect(caretX(rows[2], 14), moreOrLessEquals(caretX(rows[0], 14)));
          // Each row starts where the one before it ends: the heights the
          // list counted are the ones drawn.
          for (var i = 1; i < rows.length; i++) {
            expect(
              rows[i].localToGlobal(Offset.zero).dy,
              moreOrLessEquals(
                rows[i - 1].localToGlobal(Offset.zero).dy +
                    rows[i - 1].size.height,
              ),
            );
          }
          if (wrap == LogWrap.on) {
            expect(rows[1].size.height, greaterThan(line), reason: 'stacks');
          } else {
            expect(rows[1].size.height, moreOrLessEquals(line));
          }
        });
      }
    }
  });

  group('a current match the row does not show (LOG-05)', () {
    testWidgets('past the ellipsis: the row shows a window around it, one '
        'line high, and steps move no row', (tester) async {
      final (logs, search) = _logs();
      await _pump(
        tester,
        logs,
        search,
        display: _serverTimes(),
        size: const Size(800, 240),
      );
      logs.addJournal([
        for (var i = 0; i < 5; i++)
          _entry(
            i == 1
                ? 'long ${'filler ' * 20}needle at the end'
                : i == 3
                ? 'needle early'
                : 'm $i',
            second: i,
          ),
      ]);
      await tester.pump();
      final line = tester.getSize(_row('m 0')).height;
      final tops = [
        for (final text in ['m 0', 'long', 'm 2', 'needle early', 'm 4'])
          tester.getTopLeft(_row(text)).dy,
      ];

      search.setQuery('needle');
      search.next();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      final pixels = position.pixels;

      final windowed = _drawnOf(tester, 'needle at');
      expect(windowed, startsWith('…'));
      expect(windowed, endsWith('needle at the end'));
      expect(tester.getSize(_row('needle at')).height, moreOrLessEquals(line));
      expect(search.currentNumber, 1);
      expect(search.total, 2);
      // The match's glyphs end inside the row.
      final paragraph = tester.renderObject<RenderParagraph>(_row('needle at'));
      final start = windowed.indexOf('needle');
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 6),
      );
      expect(boxes.single.right, lessThanOrEqualTo(paragraph.size.width));

      // The next match: the first row is whole again, and nothing moved.
      search.next();
      await tester.pump();
      expect(search.currentNumber, 2);
      expect(_drawnOf(tester, 'long'), startsWith('2026-10-15 09:05:08 '));
      expect(_drawnOf(tester, 'needle early'), startsWith('2026-10-15'));
      expect(position.pixels, pixels);
      expect([
        for (final text in ['m 0', 'long', 'm 2', 'needle early', 'm 4'])
          tester.getTopLeft(_row(text)).dy,
      ], tops);
    });

    testWidgets('on a later line of a message: the window starts on it', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (logs, search) = _logs();
      await _pump(
        tester,
        logs,
        search,
        display: _serverTimes(),
        size: const Size(800, 240),
      );
      logs.addJournal([
        _entry('first line\nsecond line\nthird has the needle'),
        _entry('after'),
      ]);
      await tester.pump();
      final top = tester.getTopLeft(_row('after')).dy;

      search
        ..setQuery('needle')
        ..next();
      await tester.pump();

      expect(_drawnOf(tester, 'needle'), '…third has the needle');
      expect(tester.getTopLeft(_row('after')).dy, top);
      // A screen reader still hears the whole row, its time once.
      final label = tester.getSemantics(_row('needle')).label;
      expect(label, startsWith('2026-10-15 09:05:07 nginx.service[812]: '));
      expect(label, endsWith('third has the needle'));
      expect('09:05:07'.allMatches(label), hasLength(1));
      semantics.dispose();
    });

    testWidgets('on a 320 px phone at 3x, a match behind the time shows', (
      tester,
    ) async {
      final (logs, search) = _logs();
      await _pump(
        tester,
        logs,
        search,
        display: _serverTimes(),
        size: const Size(320, 600),
        textScale: 3,
      );
      logs.addJournal([_entry('worker exited'), _entry('after', second: 1)]);
      await tester.pump();
      final line = tester.getSize(_row('after')).height;
      final top = tester.getTopLeft(_row('after')).dy;

      search
        ..setQuery('exited')
        ..next();
      await tester.pump();

      final windowed = _drawnOf(tester, 'exited');
      expect(windowed, startsWith('…'));
      final paragraph = tester.renderObject<RenderParagraph>(_row('exited'));
      final start = windowed.indexOf('exited');
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 6),
      );
      expect(boxes, isNotEmpty);
      expect(boxes.first.left, lessThan(paragraph.size.width));
      expect(paragraph.size.height, moreOrLessEquals(line));
      expect(tester.getTopLeft(_row('after')).dy, top);
    });

    testWidgets('with wrap the row shows every match, so it is not windowed', (
      tester,
    ) async {
      final (logs, search) = _logs();
      await _pump(
        tester,
        logs,
        search,
        display: _serverTimes(),
        wrap: LogWrap.on,
      );
      logs.addJournal([_entry('long ${'filler ' * 20}needle\nand more')]);
      await tester.pump();

      search
        ..setQuery('needle')
        ..next();
      await tester.pump();
      expect(_drawnOf(tester, 'needle'), startsWith('2026-10-15 09:05:07 '));
    });
  });

  group('golden', () {
    // Linux only, as the log view's own goldens.
    final skip = !Platform.isLinux;

    for (final brightness in Brightness.values) {
      testWidgets('journal rows with times and a windowed match, '
          '${brightness.name}', (tester) async {
        final (logs, search) = _logs();
        await _pump(
          tester,
          logs,
          search,
          display: _serverTimes(),
          brightness: brightness,
          size: const Size(480, 160),
        );
        logs.addJournal([
          _entry('Started nginx', priority: 5),
          _entry(
            'upstream timed out while reading the response header from '
            'the upstream server',
            second: 1,
            priority: 4,
          ),
          _entry(
            'worker exited\nsignal 9\ncore dumped',
            second: 2,
            priority: 3,
          ),
          _entry('upstream ok', second: 3),
        ]);
        await tester.pump();
        search
          ..setQuery('upstream server')
          ..next();
        await tester.pump();

        await expectLater(
          find.byType(LogView),
          matchesGoldenFile('goldens/journal_time_${brightness.name}.png'),
        );
      }, skip: skip);
    }
  });
}
