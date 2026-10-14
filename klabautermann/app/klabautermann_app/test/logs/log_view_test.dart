import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/logs/log_level.dart';
import 'package:klabautermann_app/ui/logs/log_text.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

const _viewSize = Size(400, 200);

/// The height of the first row, one line, as the view measured it.
double _lineHeight(WidgetTester tester) =>
    tester.getSize(find.byType(RichText).first).height;

ThemeData _theme(Brightness brightness) => brightness == Brightness.dark
    ? GhostTheme.dark(klabautermannThemeStyle, platform: TargetPlatform.linux)
    : GhostTheme.light(klabautermannThemeStyle, platform: TargetPlatform.linux);

List<String> _lines(int from, int count) => [
  for (var i = from; i < from + count; i++) 'line $i',
];

Widget _app(
  LogViewController logs, {
  LogWrap wrap = LogWrap.off,
  LogLevel? Function(LogLine line)? levelOf,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: _theme(brightness),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Material(
    child: LogView(controller: logs, wrap: wrap, levelOf: levelOf),
  ),
);

Future<LogViewController> _pump(
  WidgetTester tester, {
  LogViewController? controller,
  LogWrap wrap = LogWrap.off,
  LogLevel? Function(LogLine line)? levelOf,
  Size size = _viewSize,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final logs = controller ?? LogViewController();
  addTearDown(logs.dispose);

  await tester.pumpWidget(
    _app(logs, wrap: wrap, levelOf: levelOf, brightness: brightness),
  );
  return logs;
}

/// Counts reads of its entries, so a test can bound the work a frame does.
final class _CountingController extends LogViewController {
  int reads = 0;

  @override
  LogEntry operator [](int index) {
    reads++;
    return super[index];
  }
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

bool _atEnd(WidgetTester tester) {
  final position = _position(tester);
  return position.pixels == position.maxScrollExtent;
}

Finder _line(int i) => find.text('line $i', findRichText: true);

/// Whether line [i] is built and its whole height is inside the view.
bool _shows(WidgetTester tester, int i) {
  if (_line(i).evaluate().isEmpty) return false;
  final rect = tester.getRect(_line(i));
  return rect.top >= 0 && rect.bottom <= _viewSize.height;
}

/// The oldest line at least partly in the view.
int _topLine(WidgetTester tester) {
  var top = -1;
  for (final element in find.byType(RichText).evaluate()) {
    final text = (element.widget as RichText).text.toPlainText();
    final match = RegExp(r'^line (\d+)$').firstMatch(text);
    final box = element.renderObject! as RenderBox;
    if (match == null ||
        box.localToGlobal(Offset(0, box.size.height)).dy <= 0) {
      continue;
    }
    final line = int.parse(match.group(1)!);
    if (top < 0 || line < top) top = line;
  }
  return top;
}

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text, findRichText: true));

/// Expects [text]'s row to be exactly as tall as its wrapped text, so no
/// part of it is clipped and no row has slack.
void _expectWholeRows(WidgetTester tester, String text) {
  final paragraph = _paragraph(tester, text);
  expect(paragraph.size.height, closeTo(paragraph.textSize.height, 0.01));
  expect(paragraph.didExceedMaxLines, isFalse);
}

Future<void> _wheel(WidgetTester tester, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(const Offset(200, 100)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  group('follow and pause (LOG-02)', () {
    testWidgets('keeps the newest line in sight as lines arrive', (
      tester,
    ) async {
      final logs = await _pump(tester);
      logs.add(_lines(0, 100));
      await tester.pump();

      expect(_atEnd(tester), isTrue);
      expect(_shows(tester, 99), isTrue);

      logs.add(_lines(100, 50));
      await tester.pump();

      expect(logs.following.value, isTrue);
      expect(_atEnd(tester), isTrue);
      expect(_shows(tester, 149), isTrue);
      expect(find.text('Follow'), findsNothing);

      logs.clear();
      await tester.pump();
      expect(find.byType(RichText), findsNothing);
    });

    testWidgets('opens on the newest line', (tester) async {
      final logs = LogViewController()..add(_lines(0, 100));
      await _pump(tester, controller: logs);

      expect(_atEnd(tester), isTrue);
      expect(_shows(tester, 99), isTrue);
    });

    testWidgets('a drag away pauses and holds the view; Follow resumes', (
      tester,
    ) async {
      final logs = await _pump(tester);
      logs.add(_lines(0, 100));
      await tester.pump();

      await tester.drag(find.byType(LogView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(logs.following.value, isFalse);
      final pixels = _position(tester).pixels;
      logs.add(_lines(100, 50));
      await tester.pump();
      expect(_position(tester).pixels, pixels);
      expect(_atEnd(tester), isFalse);

      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(logs.following.value, isTrue);
      expect(_shows(tester, 149), isTrue);
      expect(find.text('Follow'), findsNothing);
    });

    testWidgets('a wheel scroll pauses; scrolling back to the end follows', (
      tester,
    ) async {
      final logs = await _pump(tester);
      logs.add(_lines(0, 100));
      await tester.pump();

      await _wheel(tester, -100);
      expect(logs.following.value, isFalse);

      logs.add(_lines(100, 10));
      await tester.pump();
      await _wheel(tester, 100000);

      expect(logs.following.value, isTrue);
      logs.add(_lines(110, 10));
      await tester.pump();
      expect(_atEnd(tester), isTrue);
      expect(_shows(tester, 119), isTrue);
    });

    for (final wrap in LogWrap.values) {
      testWidgets('a paused view keeps its lines while old ones leave, '
          'wrap ${wrap.name}', (tester) async {
        final logs = await _pump(
          tester,
          wrap: wrap,
          controller: LogViewController(buffer: LogBuffer(maxLines: 100)),
        );
        // Line 5 wraps to several rows when wrap is on.
        logs.add([
          ..._lines(0, 5),
          'line 5 ${List.filled(40, 'word').join(' ')}',
          ..._lines(6, 94),
        ]);
        await tester.pump();
        await tester.drag(find.byType(LogView), const Offset(0, 600));
        await tester.pumpAndSettle();
        expect(logs.following.value, isFalse);
        final first = [
          for (var i = 20; i < 100; i++)
            if (_shows(tester, i)) i,
        ].first;
        final top = tester.getTopLeft(_line(first)).dy;

        // Evicts lines 0 to 19, all above the view.
        logs.add(_lines(100, 20));
        await tester.pump();

        expect(logs.firstSeq, 20);
        expect(tester.getTopLeft(_line(first)).dy, top);
        expect(logs.following.value, isFalse);
      });
    }
  });

  group('follow while lines wrap and leave', () {
    final wordy = List.filled(30, 'word').join(' ');
    List<String> wordyLines() => [
      for (var i = 0; i < 40; i++) 'line $i $wordy',
      'newest',
    ];
    double newestBottom(WidgetTester tester) =>
        tester.getBottomLeft(find.text('newest', findRichText: true)).dy;

    testWidgets('opens on the newest line', (tester) async {
      final logs = LogViewController()..add(wordyLines());
      await _pump(
        tester,
        controller: logs,
        wrap: LogWrap.on,
        size: const Size(250, 200),
      );

      expect(_atEnd(tester), isTrue);
      expect(newestBottom(tester), closeTo(200, 0.01));
    });

    testWidgets('a wider view keeps the newest line in sight at once', (
      tester,
    ) async {
      final logs = LogViewController()..add(wordyLines());
      await _pump(
        tester,
        controller: logs,
        wrap: LogWrap.on,
        size: const Size(250, 200),
      );
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(600, 200);
      await tester.pump();

      expect(_atEnd(tester), isTrue);
      expect(newestBottom(tester), closeTo(200, 0.01));
    });

    testWidgets(
      'a paused view near the end stays paused when the view widens',
      (tester) async {
        final logs = LogViewController()
          ..add([
            for (var i = 0; i < 2000; i++)
              'line $i ${List.filled(4 + i % 20, 'token').join(' ')}',
          ]);
        await _pump(
          tester,
          controller: logs,
          wrap: LogWrap.on,
          size: const Size(600, 400),
        );
        await tester.pumpAndSettle();
        await tester.dragFrom(const Offset(300, 200), const Offset(0, 100));
        await tester.pumpAndSettle();
        expect(logs.following.value, isFalse);

        // The rows below the view shrink by more than the view is from
        // the end: the view lands on the end at once, without blank space
        // or a spring back that would resume following.
        tester.view.physicalSize = const Size(900, 400);
        await tester.pump();
        expect(_atEnd(tester), isTrue);

        await tester.pumpAndSettle();
        expect(_atEnd(tester), isTrue);
        expect(logs.following.value, isFalse);
        expect(find.text('Follow'), findsOneWidget);
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.linux,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('a fling while paused keeps its lines as old ones leave', (
      tester,
    ) async {
      final logs = await _pump(
        tester,
        controller: LogViewController(buffer: LogBuffer(maxLines: 400)),
      );
      logs.add(_lines(0, 400));
      await tester.pump();

      await tester.fling(find.byType(LogView), const Offset(0, 200), 1000);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(logs.following.value, isFalse);
      final top = _topLine(tester);

      // Evicts lines 0 to 49, all above the view, while the fling runs on
      // toward older lines.
      logs.add(_lines(400, 50));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_topLine(tester), inInclusiveRange(top - 2, top));

      await tester.pumpAndSettle();
      expect(logs.following.value, isFalse);
      expect(_topLine(tester), lessThanOrEqualTo(top));
    });

    testWidgets('clearing a paused view follows again', (tester) async {
      final logs = await _pump(tester);
      logs.add(_lines(0, 100));
      await tester.pump();
      await tester.drag(find.byType(LogView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(logs.following.value, isFalse);

      logs.clear();
      await tester.pump();
      expect(logs.following.value, isTrue);
      expect(find.text('Follow'), findsNothing);

      logs.add(_lines(100, 100));
      await tester.pump();
      expect(_atEnd(tester), isTrue);
      expect(_shows(tester, 199), isTrue);
    });
  });

  group('keyboard', () {
    Future<LogViewController> focused(
      WidgetTester tester, {
      LogWrap wrap = LogWrap.off,
    }) async {
      final logs = await _pump(tester, wrap: wrap);
      logs.add(_lines(0, 100));
      await tester.pump();
      await tester.tap(find.byType(LogView));
      await tester.pump();
      return logs;
    }

    for (final wrap in LogWrap.values) {
      testWidgets('Home, arrows and pages scroll; End follows, '
          'wrap ${wrap.name}', (tester) async {
        final logs = await focused(tester, wrap: wrap);

        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pump();
        expect(_position(tester).pixels, 0);
        expect(logs.following.value, isFalse);
        expect(_shows(tester, 0), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(_position(tester).pixels, closeTo(_lineHeight(tester), 0.01));

        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump();
        expect(_position(tester).pixels, closeTo(200, 0.01), reason: 'a page');

        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(_position(tester).pixels, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pump();
        expect(logs.following.value, isTrue);
        expect(_atEnd(tester), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(logs.following.value, isFalse);
      });
    }

    for (final opened in [true, false]) {
      testWidgets('Page Up with wrap on passes no line unseen, '
          '${opened ? 'opened over lines' : 'lines after opening'}', (
        tester,
      ) async {
        const size = Size(400, 600);
        String text(int i) => 'line $i ${List.filled(6, 'a' * 15).join(' ')}';
        Finder line(int i) => find.text(text(i), findRichText: true);
        final lines = [for (var i = 0; i < 300; i++) text(i)];
        final logs = LogViewController();
        if (opened) logs.add(lines);
        await _pump(tester, controller: logs, wrap: LogWrap.on, size: size);
        if (!opened) {
          logs.add(lines);
          await tester.pump();
        }
        await tester.tap(find.byType(LogView));
        await tester.pump();

        for (var step = 0; step < 8; step++) {
          final top = [
            for (var i = 0; i < 300; i++)
              if (line(i).evaluate().isNotEmpty &&
                  tester.getBottomLeft(line(i)).dy > 0)
                i,
          ].first;
          await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
          await tester.pump();

          // A page is one line less than the view, so the line that was
          // at the top is still partly in sight at the bottom.
          expect(line(top), findsOneWidget, reason: 'step $step');
          expect(
            tester.getTopLeft(line(top)).dy,
            lessThan(size.height),
            reason: 'step $step',
          );
        }
      });
    }

    testWidgets('keyboard focus draws a focus ring', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await _pump(tester);
      Finder ring() => find.descendant(
        of: find.byType(LogView),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              (widget.decoration as BoxDecoration?)?.border != null,
        ),
      );
      expect(ring(), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(ring(), findsOneWidget);
    });
  });

  group('wrap', () {
    testWidgets('a long line takes the rows it needs at the view width', (
      tester,
    ) async {
      final long = List.filled(40, 'word').join(' ');
      final logs = await _pump(tester, wrap: LogWrap.on);
      logs.add(['short', long, 'after']);
      await tester.pump();

      RenderParagraph paragraph(String text) => tester
          .renderObject<RenderParagraph>(find.text(text, findRichText: true));
      final wide = paragraph(long);
      expect(
        paragraph('short').size.height,
        closeTo(_lineHeight(tester), 0.01),
      );
      expect(wide.size.height, greaterThan(2 * _lineHeight(tester)));
      expect(wide.size.height, closeTo(wide.textSize.height, 0.01));
      expect(
        tester.getTopLeft(find.text('after', findRichText: true)).dy,
        closeTo(
          tester.getBottomLeft(find.text(long, findRichText: true)).dy,
          0.01,
        ),
      );

      // Narrower, the same line needs more rows.
      final rowsAt400 = wide.size.height;
      tester.view.physicalSize = const Size(250, 200);
      await tester.pump();
      final narrow = paragraph(long);
      expect(narrow.size.height, greaterThan(rowsAt400));
      expect(narrow.size.height, closeTo(narrow.textSize.height, 0.01));
    });

    testWidgets('a line separator wraps the line instead of hiding text', (
      tester,
    ) async {
      final logs = await _pump(tester, wrap: LogWrap.on);
      logs.add(['first\u2028second']);
      await tester.pump();

      _expectWholeRows(tester, 'first\u2028second');
    });

    testWidgets('a cut line is measured with its note', (tester) async {
      final logs = await _pump(
        tester,
        wrap: LogWrap.on,
        controller: LogViewController(buffer: LogBuffer(maxLineBytes: 8)),
      );
      // The kept text fits one row; its note does not.
      logs.add(['a' * 20, 'b']);
      await tester.pump();

      const shown = 'aaaaaaaa [line cut: 20 characters in all]';
      _expectWholeRows(tester, shown);
      expect(
        _paragraph(tester, shown).size.height,
        greaterThan(_paragraph(tester, 'b').size.height),
      );
    });

    testWidgets('a long line arriving at the line cap takes its rows', (
      tester,
    ) async {
      final long = 'long ${List.filled(40, 'word').join(' ')}';
      final logs = await _pump(
        tester,
        wrap: LogWrap.on,
        controller: LogViewController(buffer: LogBuffer(maxLines: 30)),
      );
      logs.add(_lines(0, 30));
      await tester.pump();

      // One line arrives and one leaves: the count stays at the cap.
      logs.add([long]);
      await tester.pump();
      _expectWholeRows(tester, long);
      expect(
        _paragraph(tester, long).size.height,
        greaterThan(2 * _paragraph(tester, 'line 29').size.height),
      );
      expect(_atEnd(tester), isTrue);
      expect(
        tester.getBottomLeft(find.text(long, findRichText: true)).dy,
        closeTo(_viewSize.height, 0.01),
      );

      // When it leaves, its rows go with it.
      logs.add(_lines(30, 30));
      await tester.pump();
      expect(_atEnd(tester), isTrue);
      expect(_shows(tester, 59), isTrue);
      expect(
        tester.getBottomLeft(_line(59)).dy,
        closeTo(_viewSize.height, 0.01),
      );
    });

    testWidgets('a text scale change measures the rows again', (tester) async {
      final logs = await _pump(tester, wrap: LogWrap.on);
      final wide = 'x' * 20;
      logs.add(['short', wide]);
      await tester.pump();

      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();

      _expectWholeRows(tester, 'short');
      _expectWholeRows(tester, wide);
      expect(
        _paragraph(tester, wide).size.height,
        greaterThan(_paragraph(tester, 'short').size.height),
      );
    });

    testWidgets('the level gutter appearing measures the rows again', (
      tester,
    ) async {
      tester.view.physicalSize = _viewSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final logs = LogViewController();
      addTearDown(logs.dispose);
      // Fits the row's width until the gutter takes some of it.
      final line = 'a' * 29;
      logs.add([line]);
      await tester.pumpWidget(_app(logs, wrap: LogWrap.on));
      final oneRow = _paragraph(tester, line).size.height;

      await tester.pumpWidget(
        _app(logs, wrap: LogWrap.on, levelOf: (_) => LogLevel.error),
      );

      _expectWholeRows(tester, line);
      expect(_paragraph(tester, line).size.height, greaterThan(oneRow));
    });

    for (final width in [300.0, 600.0]) {
      testWidgets('scrolling up through lines not yet measured holds the '
          'view, $width wide', (tester) async {
        final logs = LogViewController()
          ..add([
            for (var i = 0; i < 300; i++)
              'line $i${i.isEven ? '' : ' ${List.filled(i % 7 * 4, 'word').join(' ')}'}',
          ]);
        await _pump(tester, controller: logs, wrap: LogWrap.on);
        // A new width leaves every row measured for the old one.
        tester.view.physicalSize = Size(width, 200);
        await tester.pump();

        for (var step = 0; step < 20; step++) {
          // A one-row line that stays in the view after the drag.
          final probe = [
            for (var i = 0; i < 300; i += 2)
              if (_line(i).evaluate().isNotEmpty &&
                  tester.getTopLeft(_line(i)).dy >= 0 &&
                  tester.getBottomLeft(_line(i)).dy <= 150)
                i,
          ].first;
          final before = tester.getTopLeft(_line(probe)).dy;
          await tester.dragFrom(const Offset(150, 100), const Offset(0, 40));
          await tester.pump();
          expect(
            tester.getTopLeft(_line(probe)).dy,
            closeTo(before + 40, 0.01),
            reason: 'step $step',
          );
        }
      });
    }

    testWidgets('a large width change while following settles in a frame', (
      tester,
    ) async {
      final logs = LogViewController()
        ..add([
          for (var i = 0; i < 3000; i++)
            'line $i ${List.filled(i % 13 * 3, 'word').join(' ')}',
        ]);
      await _pump(
        tester,
        controller: logs,
        wrap: LogWrap.on,
        size: const Size(120, 600),
      );

      for (final width in [1600.0, 120.0]) {
        tester.view.physicalSize = Size(width, 600);
        await tester.pump();
        expect(_atEnd(tester), isTrue);
        expect(
          tester
              .getBottomLeft(
                find.textContaining('line 2999', findRichText: true),
              )
              .dy,
          closeTo(600, 0.01),
        );
      }
    });

    testWidgets('a new line reads only the entries near the view', (
      tester,
    ) async {
      final logs = _CountingController()..add(_lines(0, 5000));
      await _pump(tester, controller: logs, wrap: LogWrap.on);

      logs.reads = 0;
      logs.add(['line 5000']);
      await tester.pump();

      expect(_shows(tester, 5000), isTrue);
      expect(logs.reads, lessThan(500));
    });

    testWidgets('a resize measures only the entries near the view', (
      tester,
    ) async {
      final wordy = List.filled(30, 'word').join(' ');
      final logs = _CountingController()
        ..add([for (var i = 0; i < 5000; i++) '$i $wordy']);
      await _pump(tester, controller: logs, wrap: LogWrap.on);

      logs.reads = 0;
      tester.view.physicalSize = const Size(390, 200);
      await tester.pump();

      _expectWholeRows(tester, '4999 $wordy');
      expect(_atEnd(tester), isTrue);
      expect(logs.reads, lessThan(500));
    });
  });

  group('markers and levels', () {
    testWidgets('dropped lines and cut lines are worded', (tester) async {
      // With wrap off the note sits past the ellipsis until sideways
      // scrolling lands; screen readers still read it.
      final logs = await _pump(
        tester,
        wrap: LogWrap.on,
        controller: LogViewController(buffer: LogBuffer(maxLineBytes: 64)),
      );
      logs.add(['a' * 20000], dropped: 1234);
      await tester.pump();

      expect(find.text('1,234 lines dropped here'), findsOneWidget);
      _expectWholeRows(
        tester,
        '${'a' * 64} [line cut: 20,000 characters in all]',
      );
    });

    testWidgets('levels colour the text and add a spoken icon', (tester) async {
      final semantics = tester.ensureSemantics();
      const levels = {
        'disk failed': (LogLevel.error, Icons.error_outline, 'Error'),
        'disk slow': (LogLevel.warning, Icons.warning_amber, 'Warning'),
        'probe': (LogLevel.debug, Icons.bug_report_outlined, 'Debug'),
        'started': (null, null, null),
      };
      final logs = await _pump(
        tester,
        levelOf: (line) => levels[line.text]!.$1,
      );
      logs.add(levels.keys);
      await tester.pump();

      final palette = LogPalette.fromTheme(_theme(Brightness.light));
      for (final MapEntry(key: text, value: (level, icon, word))
          in levels.entries) {
        final row = tester.widget<RichText>(
          find.text(text, findRichText: true),
        );
        expect(
          (row.text as TextSpan).children!.first.style!.color,
          palette.levelColor(level),
        );
        if (icon == null) continue;
        expect(find.byIcon(icon), findsOneWidget);
        expect(find.bySemanticsLabel('$word\n$text'), findsOneWidget);
      }
      semantics.dispose();
    });
  });

  group('golden', () {
    // Baselines come from Linux, the platform CI's app job runs on; other
    // hosts rasterize differently. The test font draws glyphs as boxes,
    // which still show every colour and the row layout.
    final skip = !Platform.isLinux;

    for (final brightness in Brightness.values) {
      testWidgets('levels, SGR colours, markers and wrap, paused, '
          '${brightness.name}', (tester) async {
        final logs = await _pump(
          tester,
          brightness: brightness,
          size: const Size(480, 300),
          wrap: LogWrap.on,
          controller: LogViewController(buffer: LogBuffer(maxLineBytes: 120)),
          levelOf: (line) => const {
            'E': LogLevel.error,
            'W': LogLevel.warning,
            'D': LogLevel.debug,
          }[line.text[0]],
        );
        logs
          ..add(['I service started', 'D probe 12 ms'])
          ..add([
            'W disk 91% full',
            'E unit failed: exit 1',
            'I \x1b[31mred\x1b[0m \x1b[1;32mbold green\x1b[0m \x1b[7mreverse\x1b[0m',
            'I \x1b[30;40mhidden?\x1b[0m \x1b[38;2;9;9;9;48;2;9;9;9mrgb\x1b[0m \x1b[2mfaint\x1b[0m',
            'I tab\tseparated',
          ], dropped: 3)
          ..add(['I ${'long ' * 30}'])
          ..pause();
        await tester.pump();

        await expectLater(
          find.byType(LogView),
          matchesGoldenFile('goldens/log_view_${brightness.name}.png'),
        );
      }, skip: skip);
    }
  });
}
