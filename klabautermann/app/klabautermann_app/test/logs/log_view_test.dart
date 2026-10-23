import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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

/// The theme's [platform] also picks the scroll physics: macOS bounces
/// past the ends, Linux and Windows clamp.
ThemeData _theme(
  Brightness brightness, {
  TargetPlatform platform = TargetPlatform.linux,
}) => brightness == Brightness.dark
    ? GhostTheme.dark(klabautermannThemeStyle, platform: platform)
    : GhostTheme.light(klabautermannThemeStyle, platform: platform);

/// The desktop platforms, for tests whose theme follows the variant's.
final _desktops = TargetPlatformVariant.desktop();

List<String> _lines(int from, int count) => [
  for (var i = from; i < from + count; i++) 'line $i',
];

Widget _app(
  LogViewController logs, {
  LogWrap wrap = LogWrap.off,
  LogLevel? Function(LogLine line)? levelOf,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: _theme(brightness, platform: platform),
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
  TargetPlatform platform = TargetPlatform.linux,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final logs = controller ?? LogViewController();
  addTearDown(logs.dispose);

  await tester.pumpWidget(
    _app(
      logs,
      wrap: wrap,
      levelOf: levelOf,
      brightness: brightness,
      platform: platform,
    ),
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
    final match = RegExp(r'^line (\d+)\b').firstMatch(text);
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

/// The line whose text starts with "line [i]", wrapped or not.
Finder _lineStarting(int i) => find.byWidgetPredicate(
  (widget) =>
      widget is RichText &&
      RegExp('^line $i\\b').hasMatch(widget.text.toPlainText()),
);

/// The height of a row: the shortest "line N" in the view, which the views
/// that use it always show on one row.
double _rowHeight(WidgetTester tester) => [
  for (final element in find.byType(RichText).evaluate())
    if ((element.widget as RichText).text.toPlainText().startsWith('line '))
      (element.renderObject! as RenderBox).size.height,
].reduce(math.min);

/// The oldest line at least partly in the view, and the share of its
/// height above the view's top edge.
typedef _TopHold = ({int line, double hidden});

_TopHold _topHold(WidgetTester tester) {
  final line = _topLine(tester);
  final rect = tester.getRect(_lineStarting(line));
  return (line: line, hidden: -rect.top / rect.height);
}

/// Expects [before]'s line still the oldest in the view: its first row at
/// the top edge if it was there, and otherwise as large a share of it
/// above the edge as before, give or take the row the offset moves in
/// whole rows by.
void _expectTopHeld(WidgetTester tester, _TopHold before, String reason) {
  expect(_topLine(tester), before.line, reason: reason);
  final rect = tester.getRect(_lineStarting(before.line));
  if (before.hidden <= 1e-3) {
    expect(rect.top, closeTo(0, 0.01), reason: '$reason: first row');
    return;
  }
  expect(
    -rect.top,
    closeTo(before.hidden * rect.height, _rowHeight(tester) + 0.01),
    reason: '$reason: share above the edge',
  );
}

/// Pauses the view and scrolls it so the oldest line in it starts exactly
/// at its top edge.
Future<void> _pauseAtLineTop(
  WidgetTester tester,
  LogViewController logs,
) async {
  await tester.drag(find.byType(LogView), const Offset(0, 600));
  await tester.pumpAndSettle();
  expect(logs.following.value, isFalse);

  final position = _position(tester);
  final top = tester.getTopLeft(_lineStarting(_topLine(tester))).dy;
  position.jumpTo(position.pixels + top);
  await tester.pump();
  expect(logs.following.value, isFalse);
  expect(_topHold(tester).hidden, closeTo(0, 1e-3));
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

  group('a paused view keeps its lines when rows change', () {
    // Odd lines wrap to up to five rows when wrap is on.
    List<String> mixed() => [
      for (var i = 0; i < 300; i++)
        i.isEven
            ? 'line $i'
            : 'line $i ${List.filled(i % 5 * 6, 'word').join(' ')}',
    ];

    Future<LogViewController> paused(WidgetTester tester, LogWrap wrap) async {
      final logs = LogViewController()..add(mixed());
      await _pump(tester, controller: logs, wrap: wrap);
      await tester.drag(find.byType(LogView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(logs.following.value, isFalse);
      return logs;
    }

    for (final wrap in LogWrap.values) {
      testWidgets('a text scale change, wrap ${wrap.name}', (tester) async {
        final logs = await paused(tester, wrap);
        var top = _topHold(tester);

        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pump();
        expect(logs.following.value, isFalse);
        _expectTopHeld(tester, top, 'scale 2');

        top = _topHold(tester);
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await tester.pump();
        expect(logs.following.value, isFalse);
        _expectTopHeld(tester, top, 'scale 1');
      });
    }

    testWidgets('wrap turned off and on', (tester) async {
      final logs = await paused(tester, LogWrap.on);

      for (final wrap in [LogWrap.off, LogWrap.on, LogWrap.off, LogWrap.on]) {
        final top = _topHold(tester);
        await tester.pumpWidget(_app(logs, wrap: wrap));
        expect(logs.following.value, isFalse, reason: wrap.name);
        _expectTopHeld(tester, top, wrap.name);
      }
    });

    // In both, the line at the top edge wraps to more rows than its count
    // held, and its first row must stay at that edge.
    testWidgets('the first wrap with rows still estimated keeps a line '
        'at the top edge whole', (tester) async {
      final logs = LogViewController()
        ..add([
          for (var i = 0; i < 300; i++)
            'line $i ${List.filled(25, 'word').join(' ')}',
        ]);
      await _pump(tester, controller: logs);
      await _pauseAtLineTop(tester, logs);
      final top = _topHold(tester);
      final row = tester.getSize(_lineStarting(top.line)).height;

      await tester.pumpWidget(_app(logs, wrap: LogWrap.on));
      expect(logs.following.value, isFalse);
      expect(
        tester.getSize(_lineStarting(top.line)).height,
        greaterThan(2 * row),
      );
      _expectTopHeld(tester, top, 'wrap on');
    });

    testWidgets('a text scale change with wrap on keeps a line at the top '
        'edge whole', (tester) async {
      final logs = LogViewController()
        ..add([
          for (var i = 0; i < 300; i++)
            'line $i ${List.filled(3, 'word').join(' ')}',
        ]);
      await _pump(tester, controller: logs, wrap: LogWrap.on);
      await _pauseAtLineTop(tester, logs);
      final top = _topHold(tester);
      final row = tester.getSize(_lineStarting(top.line)).height;

      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      expect(logs.following.value, isFalse);
      // Two rows, each twice as high.
      expect(
        tester.getSize(_lineStarting(top.line)).height,
        greaterThan(3 * row),
      );
      _expectTopHeld(tester, top, 'scale 2');
    });
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

    for (final wrap in LogWrap.values) {
      testWidgets('an animated scroll while paused lands where it was aimed '
          'as old lines leave, wrap ${wrap.name}', (tester) async {
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
        await _pauseAtLineTop(tester, logs);
        final top = _topLine(tester);
        final position = _position(tester);

        // Three lines up over 100 ms, as a click on the desktop scrollbar's
        // track animates, with lines 0 to 19 leaving 40 ms in.
        unawaited(
          position.animateTo(
            position.pixels - 3 * _rowHeight(tester),
            duration: const Duration(milliseconds: 100),
            curve: Curves.linear,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        logs.add(_lines(100, 20));
        await tester.pump(const Duration(milliseconds: 16));
        expect(logs.firstSeq, 20);
        expect(
          _topLine(tester),
          inInclusiveRange(top - 3, top),
          reason: 'during the animation',
        );

        await tester.pumpAndSettle();
        expect(logs.following.value, isFalse);
        expect(_topLine(tester), top - 3, reason: 'where the animation ends');
        expect(_topHold(tester).hidden, closeTo(0, 1e-3));

        // An animation to the newest line still ends on it, following.
        unawaited(
          position.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.linear,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        logs.add(_lines(120, 20));
        await tester.pumpAndSettle();
        expect(logs.firstSeq, 40);
        expect(logs.following.value, isTrue);
        expect(_atEnd(tester), isTrue);
        expect(_shows(tester, 139), isTrue);
      });
    }

    for (final wrap in LogWrap.values) {
      testWidgets(
        'a track click near the top while paused stays on the lines as old '
        'ones leave, wrap ${wrap.name}',
        (tester) async {
          final logs = await _pump(
            tester,
            wrap: wrap,
            controller: LogViewController(buffer: LogBuffer(maxLines: 100)),
            platform: defaultTargetPlatform,
          );
          logs.add([
            ..._lines(0, 5),
            'line 5 ${List.filled(40, 'word').join(' ')}',
            ..._lines(6, 94),
          ]);
          await tester.pump();
          await _pauseAtLineTop(tester, logs);
          final position = _position(tester);
          // Less than a page from the oldest line, so the click aims at it.
          position.jumpTo(
            position.pixels - (_topLine(tester) - 8) * _rowHeight(tester),
          );
          await tester.pump();
          expect(_topLine(tester), 8);

          // A click on the scrollbar's track above its thumb, once the
          // pointer has shown the scrollbar, animates a page up for 100 ms.
          const track = Offset(396, 1);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: track);
          await tester.pump();
          await mouse.moveTo(track);
          await tester.pumpAndSettle();
          final before = position.pixels;
          await mouse.down(track);
          await tester.pump();
          await mouse.up();
          await tester.pump();

          // Lines 0 to 19 leave 40 ms in. The rest of the path must not run
          // past the oldest line left, which bouncing physics would show as
          // blank space above it.
          for (var ms = 0; ms < 500; ms += 10) {
            if (ms == 40) logs.add(_lines(100, 20));
            await tester.pump(const Duration(milliseconds: 10));
            expect(
              position.pixels,
              greaterThanOrEqualTo(position.minScrollExtent),
              reason: 'the frame ${ms + 10} ms after the click',
            );
          }
          expect(position.pixels, lessThan(before), reason: 'it animated');

          await tester.pumpAndSettle();
          expect(logs.firstSeq, 20);
          expect(logs.following.value, isFalse);
          expect(_topLine(tester), 20);
          expect(_topHold(tester).hidden, closeTo(0, 1e-3));
        },
        variant: _desktops,
      );
    }

    // Curves that come within a few pixels of the end 110 ms into 300 ms
    // and then turn back from it or run past it.
    for (final (name, curve) in [
      ('bounceOut', Curves.bounceOut),
      ('easeOutBack', Curves.easeOutBack),
    ]) {
      for (final wrap in LogWrap.values) {
        testWidgets(
          'an animation to the newest line while paused moves no further '
          'than its curve as old lines leave, $name, wrap ${wrap.name}',
          (tester) async {
            // Animates a paused view to the end, with lines 0 to 19 leaving
            // 110 ms in when [evict]. Returns the highest the view went
            // above the line it started on, in rows, the furthest it went
            // past the end, in pixels, and whether it landed following on
            // the newest line.
            Future<({double above, double past, bool landed})> run({
              required bool evict,
            }) async {
              await tester.pumpWidget(const SizedBox());
              final logs = await _pump(
                tester,
                wrap: wrap,
                controller: LogViewController(buffer: LogBuffer(maxLines: 100)),
                platform: defaultTargetPlatform,
              );
              logs.add(_lines(0, 100));
              await tester.pump();
              await _pauseAtLineTop(tester, logs);
              final position = _position(tester);
              final row = _rowHeight(tester);
              // Every line takes one row, so line n starts at
              // (n - firstSeq) rows.
              final start = _topLine(tester);
              expect(position.pixels, closeTo(start * row, 0.01));

              unawaited(
                position.animateTo(
                  position.maxScrollExtent,
                  duration: const Duration(milliseconds: 300),
                  curve: curve,
                ),
              );
              await tester.pump();
              var above = 0.0;
              var past = 0.0;
              for (var ms = 0; ms < 600; ms += 10) {
                if (evict && ms == 110) logs.add(_lines(100, 20));
                await tester.pump(const Duration(milliseconds: 10));
                final startAt = (start - logs.firstSeq) * row;
                above = math.max(above, (startAt - position.pixels) / row);
                past = math.max(
                  past,
                  position.pixels - position.maxScrollExtent,
                );
              }
              expect(logs.firstSeq, evict ? 20 : 0);

              await tester.pumpAndSettle();
              final newest = logs.firstSeq + logs.length - 1;
              return (
                above: above,
                past: past,
                landed:
                    logs.following.value &&
                    _atEnd(tester) &&
                    _shows(tester, newest),
              );
            }

            final control = await run(evict: false);
            expect(control.above, 0);
            expect(control.landed, isTrue);

            final evicted = await run(evict: true);
            expect(
              evicted.above,
              lessThan(0.01),
              reason: 'rows above the line it started on',
            );
            expect(
              evicted.past,
              lessThanOrEqualTo(control.past + 0.01),
              reason: 'pixels past the end',
            );
            expect(
              evicted.landed,
              isTrue,
              reason: 'following, on the newest line',
            );
          },
          variant: _desktops,
        );
      }
    }

    for (final wrap in LogWrap.values) {
      testWidgets(
        'an animation to a line while paused lands on it as the lines in '
        'view leave, wrap ${wrap.name}',
        (tester) async {
          // Animates a paused view down from line 8 to line [aim] for
          // 100 ms, as a click on the scrollbar's track does, with lines 0
          // to 19, the view's own among them, leaving 40 ms in. Returns
          // where it lands.
          Future<_TopHold> run({required int aim}) async {
            await tester.pumpWidget(const SizedBox());
            final logs = await _pump(
              tester,
              wrap: wrap,
              controller: LogViewController(buffer: LogBuffer(maxLines: 100)),
              platform: defaultTargetPlatform,
            );
            logs.add(_lines(0, 100));
            await tester.pump();
            await _pauseAtLineTop(tester, logs);
            final position = _position(tester);
            final row = _rowHeight(tester);
            position.jumpTo(position.pixels - (_topLine(tester) - 8) * row);
            await tester.pump();
            expect(_topLine(tester), 8);

            unawaited(
              position.animateTo(
                position.pixels + (aim - 8) * row,
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeInOut,
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 40));
            logs.add(_lines(100, 20));
            // Frame by frame, so the path passes the oldest line left: it
            // waits there, neither above it nor stopped by the physics.
            for (var ms = 50; ms < 200; ms += 10) {
              await tester.pump(const Duration(milliseconds: 10));
              expect(position.pixels, greaterThanOrEqualTo(0));
            }
            await tester.pumpAndSettle();
            expect(logs.firstSeq, 20);
            expect(logs.following.value, isFalse);
            return _topHold(tester);
          }

          final kept = await run(aim: 30);
          expect(kept.line, 30, reason: 'the line it was aimed at');
          expect(kept.hidden, closeTo(0, 1e-3));

          // Line 18 leaves too, so it lands on the oldest line left.
          final left = await run(aim: 18);
          expect(left.line, 20, reason: 'the oldest line left');
          expect(left.hidden, closeTo(0, 1e-3));
        },
        variant: _desktops,
      );
    }

    for (final wrap in LogWrap.values) {
      testWidgets(
        'an animation to the top that runs past it while paused lands on '
        'the oldest line as lines leave, wrap ${wrap.name}',
        (tester) async {
          final logs = await _pump(
            tester,
            wrap: wrap,
            controller: LogViewController(buffer: LogBuffer(maxLines: 100)),
            platform: defaultTargetPlatform,
          );
          logs.add(_lines(0, 100));
          await tester.pump();
          await _pauseAtLineTop(tester, logs);
          final position = _position(tester);
          position.jumpTo(
            position.pixels - (_topLine(tester) - 25) * _rowHeight(tester),
          );
          await tester.pump();
          expect(_topLine(tester), 25);

          // easeOutBack runs past the top before it settles there, which
          // bouncing physics show as blank space above the oldest line.
          unawaited(
            position.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(position.pixels, lessThan(0), reason: 'above the top');

          // Lines 0 to 19 leave while the view is above the oldest line.
          logs.add(_lines(100, 20));
          await tester.pumpAndSettle();
          expect(logs.firstSeq, 20);
          expect(logs.following.value, isFalse);
          expect(_topLine(tester), 20);
          expect(_topHold(tester).hidden, closeTo(0, 1e-3));
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }

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

    // A cap of 600 lines evicts from the front until the held entries reach
    // the 1,024 slots the row counts start with, and the next line moves
    // them to new slots.
    LogViewController capped() =>
        LogViewController(buffer: LogBuffer(maxLines: 600));

    testWidgets('rows stay in place after old lines leave and the counts '
        'move to new slots', (tester) async {
      final logs = await _pump(tester, wrap: LogWrap.on, controller: capped());
      for (var batch = 0; batch < 12; batch++) {
        logs.add(_lines(batch * 100, 100));
        await tester.pump();
      }

      expect(logs.firstSeq, 600);
      expect(_atEnd(tester), isTrue);
      final row = tester.getSize(_line(1199)).height;
      expect(
        tester.getBottomLeft(_line(1199)).dy,
        closeTo(_viewSize.height, 0.01),
      );
      expect(
        _position(tester).maxScrollExtent,
        closeTo(600 * row - _viewSize.height, 0.01),
      );
    });

    testWidgets('a paused view keeps its lines while the counts move to '
        'new slots', (tester) async {
      final logs = await _pump(tester, wrap: LogWrap.on, controller: capped());
      logs.add(_lines(0, 600));
      await tester.pump();
      await tester.drag(find.byType(LogView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(logs.following.value, isFalse);
      final first = _topLine(tester) + 1;
      final top = tester.getTopLeft(_line(first)).dy;

      // The last batch passes 1,024 lines in all.
      for (var batch = 6; batch < 11; batch++) {
        logs.add(_lines(batch * 100, 100));
        await tester.pump();
        expect(tester.getTopLeft(_line(first)).dy, top, reason: 'batch $batch');
      }
      expect(logs.firstSeq, lessThan(first));
      expect(logs.following.value, isFalse);
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

    /// Pauses a 300 px wide wrapped view with [long] across its top edge
    /// and line 50, the line after it, [below] rows under that edge.
    Future<LogViewController> straddle(
      WidgetTester tester,
      String long, {
      required int below,
      LogLevel? Function(LogLine line)? levelOf,
    }) async {
      final logs = LogViewController()
        ..add([..._lines(0, 50), long, ..._lines(50, 50)]);
      await _pump(
        tester,
        controller: logs,
        wrap: LogWrap.on,
        levelOf: levelOf,
        size: const Size(300, 200),
      );
      await tester.drag(find.byType(LogView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(logs.following.value, isFalse);

      // Line 50 is just above the view, built but offstage.
      final line50 = find.text(
        'line 50',
        findRichText: true,
        skipOffstage: false,
      );
      final row = tester.getSize(line50).height;
      final position = _position(tester);
      position.jumpTo(
        position.pixels + tester.getTopLeft(line50).dy - below * row,
      );
      await tester.pump();
      expect(tester.getTopLeft(_line(50)).dy, closeTo(below * row, 0.01));
      expect(
        tester.getTopLeft(find.text(long, findRichText: true)).dy,
        lessThan(-row),
      );
      return logs;
    }

    /// The share of [long]'s height above the view's top edge.
    double hiddenShare(WidgetTester tester, String long) {
      final rect = tester.getRect(find.text(long, findRichText: true));
      return -rect.top / rect.height;
    }

    /// Expects the view to be paused with [long] still across its top
    /// edge, the share [hidden] of it above that edge give or take a row,
    /// and line 50 wholly in sight below it.
    void expectHeld(
      WidgetTester tester,
      LogViewController logs,
      String long,
      double hidden,
      String step,
    ) {
      final reason = '$step: top line ${_topLine(tester)}';
      expect(logs.following.value, isFalse, reason: reason);
      expect(_shows(tester, 50), isTrue, reason: reason);
      final rect = tester.getRect(find.text(long, findRichText: true));
      expect(rect.top, lessThanOrEqualTo(0), reason: reason);
      expect(rect.bottom, greaterThan(0), reason: reason);
      expect(
        -rect.top,
        closeTo(hidden * rect.height, tester.getSize(_line(50)).height + 0.01),
        reason: '$reason: share above the edge',
      );
    }

    testWidgets('a paused view keeps the line across its top in sight as '
        'the width changes', (tester) async {
      final long = 'long ${List.filled(120, 'word').join(' ')}';
      final logs = await straddle(tester, long, below: 3);

      for (final width in [900.0, 300.0, 200.0, 400.0]) {
        final hidden = hiddenShare(tester, long);
        tester.view.physicalSize = Size(width, 200);
        await tester.pump();
        expectHeld(tester, logs, long, hidden, '$width wide');
      }
    });

    testWidgets('a paused view keeps the line across its top in sight as '
        'the gutter goes and comes', (tester) async {
      // Breaks anywhere, so the gutter's width changes its rows.
      final long = 'x' * 2000;
      LogLevel? noLevel(LogLine line) => null;
      final logs = await straddle(tester, long, below: 2, levelOf: noLevel);

      var hidden = hiddenShare(tester, long);
      await tester.pumpWidget(_app(logs, wrap: LogWrap.on));
      expectHeld(tester, logs, long, hidden, 'gutter gone');

      hidden = hiddenShare(tester, long);
      await tester.pumpWidget(_app(logs, wrap: LogWrap.on, levelOf: noLevel));
      expectHeld(tester, logs, long, hidden, 'gutter back');
    });

    testWidgets('a paused view keeps a line at its top edge whole as it '
        'narrows', (tester) async {
      // One row at 800 px, two at 400.
      final logs = LogViewController()
        ..add([
          for (var i = 0; i < 300; i++)
            'line $i ${List.filled(8, 'word').join(' ')}',
        ]);
      await _pump(
        tester,
        controller: logs,
        wrap: LogWrap.on,
        size: const Size(800, 200),
      );
      await _pauseAtLineTop(tester, logs);
      final top = _topHold(tester);
      final row = tester.getSize(_lineStarting(top.line)).height;

      tester.view.physicalSize = const Size(400, 200);
      await tester.pump();
      expect(logs.following.value, isFalse);
      expect(
        tester.getSize(_lineStarting(top.line)).height,
        closeTo(2 * row, 0.01),
      );
      _expectTopHeld(tester, top, '400 wide');
    });

    testWidgets('Home after narrowing reaches the start of the oldest line', (
      tester,
    ) async {
      final logs = await _pump(
        tester,
        wrap: LogWrap.on,
        size: const Size(800, 200),
      );
      // One row at 800 px, so still counted as one at 300 px, where it
      // wraps.
      logs.add([
        for (var i = 0; i < 3000; i++)
          'line $i ${List.filled(8, 'word').join(' ')}',
      ]);
      await tester.pump();
      final row = tester.getSize(_lineStarting(2999)).height;
      tester.view.physicalSize = const Size(300, 200);
      await tester.pump();
      expect(logs.following.value, isTrue);

      await tester.tap(find.byType(LogView));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();

      expect(_position(tester).pixels, 0);
      expect(tester.getTopLeft(_lineStarting(0)).dy, 0);
      expect(tester.getSize(_lineStarting(0)).height, greaterThan(row));
      expect(logs.following.value, isFalse);
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

      testWidgets('URLs, addresses and HTTP codes, ${brightness.name} '
          '(LOG-07)', (tester) async {
        final logs = await _pump(
          tester,
          brightness: brightness,
          size: const Size(480, 200),
          wrap: LogWrap.on,
          levelOf: (line) =>
              const {'E': LogLevel.error, 'W': LogLevel.warning}[line.text[0]],
        );
        logs
          ..add([
            'I 10.0.0.7 "GET /a HTTP/1.1" 200 see https://example.test/a',
            'W 192.168.1.20 "GET /old HTTP/1.1" 301 fe80::1%eth0',
            'E 10.0.0.9 "POST /api HTTP/1.1" 404 then status=503',
            'I \x1b[32mprogram colour 10.0.0.1 GET /x 500\x1b[0m',
          ])
          ..pause();
        await tester.pump();

        await expectLater(
          find.byType(LogView),
          matchesGoldenFile('goldens/log_view_tokens_${brightness.name}.png'),
        );
      }, skip: skip);
    }
  });
}
