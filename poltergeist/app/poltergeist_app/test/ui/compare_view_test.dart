import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/editor_text_size_controller.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/services/sync_compare_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/compare_diff_colors.dart';
import 'package:poltergeist_app/ui/compare_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/preview_harness.dart';

const _serverId = 'compare-server';
const _relativePath = 'notes.txt';
final _captureDirectory =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/sync-pair-compare/screenshots';

void main() {
  late Directory temporaryDirectory;

  setUpAll(() async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await _loadRealFonts();
    }
  });

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'compare_view_test_',
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'shows aligned rows, then separate editors with independent find bars',
    (tester) async {
      final left = File('${temporaryDirectory.path}/left.txt');
      final right = File('${temporaryDirectory.path}/right.txt');
      left.writeAsBytesSync([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('left\r\ntext\r\n'),
      ]);
      right.writeAsStringSync('right\ntext\n');
      final controller = _controller(
        left: _local(SyncSide.left, left, mtimeSecs: 1),
        right: _local(SyncSide.right, right, mtimeSecs: 2),
      );
      addTearDown(controller.dispose);
      final semantics = tester.ensureSemantics();

      await tester.runAsync(controller.start);
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      expect(find.byKey(const ValueKey('sync.compare.view')), findsOneWidget);
      expect(find.text('Compare notes.txt'), findsOneWidget);
      expect(find.text('1 changed region'), findsOneWidget);
      expect(find.text('Line endings differ: CRLF vs LF'), findsOneWidget);
      expect(find.text('BOM differs'), findsOneWidget);
      expect(
        _inSide('sync.compare.left', find.text(left.path)),
        findsOneWidget,
      );
      expect(
        _inSide('sync.compare.right', find.text(right.path)),
        findsOneWidget,
      );
      expect(find.byType(PlanchetteEditor), findsNothing);
      expect(find.bySemanticsLabel('Left only, line 1'), findsOneWidget);
      expect(find.bySemanticsLabel('Right only, line 1'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Left line 2, right line 2'),
        findsOneWidget,
      );
      await _captureView(tester, 'compare-diff-side-by-side');

      await tester.tap(find.text('Separate'));
      await tester.pump();

      final editors = tester
          .widgetList<PlanchetteEditor>(find.byType(PlanchetteEditor))
          .toList();
      expect(editors, hasLength(2));
      expect(
        editors.map((editor) => editor.editingLocked),
        everyElement(isTrue),
      );
      expect(editors.map((editor) => editor.showStatus), everyElement(isFalse));
      expect(editors[0].controller, isNot(same(editors[1].controller)));
      expect(find.text('1 changed region'), findsOneWidget);
      await _captureView(tester, 'after-sync-pair-compare');

      await tester.tap(_inSide('sync.compare.left', find.byTooltip('Find')));
      await tester.pump();
      expect(_findFields(), findsOneWidget);

      await tester.tap(_inSide('sync.compare.right', find.byTooltip('Find')));
      await tester.pump();
      expect(_findFields(), findsNWidgets(2));

      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a refused side leaves its peer readable', (tester) async {
    final left = File('${temporaryDirectory.path}/too-large.txt');
    left.writeAsBytesSync(
      List<int>.filled(builtInEditorMaximumBytes + 1, 0x61),
    );
    final right = File('${temporaryDirectory.path}/readable.txt');
    right.writeAsStringSync('still readable');
    final controller = _controller(
      left: LocalSyncCompareSource(
        side: SyncSide.left,
        fullPath: left.path,
        snapshot: EntrySnapshot(kind: EntryKind.file, size: left.lengthSync()),
      ),
      right: _local(SyncSide.right, right),
    );
    addTearDown(controller.dispose);

    await tester.runAsync(controller.start);
    await _pumpView(tester, controller);
    await tester.pump();

    expect(
      find.text('The built-in editor supports text files up to 4 MB.'),
      findsOneWidget,
    );
    expect(find.byType(PlanchetteEditor), findsOneWidget);
    expect(find.text('still readable'), findsOneWidget);
  });

  testWidgets('both metadata headers share one clock snapshot', (tester) async {
    final left = File('${temporaryDirectory.path}/left.txt')
      ..writeAsStringSync('left');
    final right = File('${temporaryDirectory.path}/right.txt')
      ..writeAsStringSync('right');
    final controller = _controller(
      left: _local(SyncSide.left, left),
      right: _local(SyncSide.right, right),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.start);
    var clockCalls = 0;

    await _pumpView(
      tester,
      controller,
      clock: () {
        clockCalls++;
        return DateTime.utc(2026, 10, 2);
      },
    );

    expect(clockCalls, 1);
  });

  testWidgets('a caller title replaces the relative-path title', (
    tester,
  ) async {
    final left = File('${temporaryDirectory.path}/left.txt')
      ..writeAsStringSync('left');
    final right = File('${temporaryDirectory.path}/right.txt')
      ..writeAsStringSync('right');
    final controller = _controller(
      left: _local(SyncSide.left, left),
      right: _local(SyncSide.right, right),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.start);

    await _pumpView(
      tester,
      controller,
      title: 'Compare left.txt and right.txt',
    );

    expect(find.text('Compare left.txt and right.txt'), findsOneWidget);
    expect(find.text('Compare notes.txt'), findsNothing);
  });

  testWidgets('renders a localized text refusal without raw errors', (
    tester,
  ) async {
    final left = File('${temporaryDirectory.path}/invalid.txt');
    left.writeAsBytesSync([0xff]);
    final right = File('${temporaryDirectory.path}/valid.txt');
    right.writeAsStringSync('readable');
    final controller = _controller(
      left: _local(SyncSide.left, left),
      right: _local(SyncSide.right, right),
    );
    addTearDown(controller.dispose);

    await tester.runAsync(controller.start);
    await _pumpView(tester, controller);
    await tester.pump();

    expect(find.text('This file is not valid UTF-8 text.'), findsOneWidget);
    expect(find.text('This side could not be loaded.'), findsNothing);
    expect(find.text('readable'), findsOneWidget);
  });

  testWidgets('renders confirmation, progress, and cancellation inline', (
    tester,
  ) async {
    final cache = await tester.runAsync(() => _cache(temporaryDirectory));
    final producer = FakePreviewProducer();
    final right = File('${temporaryDirectory.path}/local.txt');
    right.writeAsStringSync('local');
    final controller = _controller(
      left: _remote(SyncSide.left, size: 12),
      right: _local(SyncSide.right, right),
      previewCache: cache,
      previewProducer: producer,
      thresholdBytes: 4,
    );
    addTearDown(controller.dispose);

    await tester.runAsync(() async {
      unawaited(controller.start());
      await _until(
        () =>
            controller.left.phase == SyncComparePhase.confirming &&
            controller.right.phase == SyncComparePhase.ready,
      );
    });
    await _pumpView(tester, controller);
    await tester.pump();

    final leftPane = find.byKey(const ValueKey('sync.compare.left'));
    expect(
      find.descendant(
        of: leftPane,
        matching: find.textContaining('Download 12 B'),
      ),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.descendant(
          of: leftPane,
          matching: find.widgetWithText(FilledButton, 'Download'),
        ),
      );
      await _until(() => producer.specs.isNotEmpty);
    });
    producer.progress(0, 7, 12);
    await tester.pump();

    expect(
      find.descendant(
        of: leftPane,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('7 B of 12 B'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: leftPane,
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    await tester.pump();

    expect(controller.left.phase, SyncComparePhase.cancelled);
    expect(find.text('The preview download was cancelled.'), findsOneWidget);
    expect(find.byType(PlanchetteEditor), findsOneWidget);
  });

  testWidgets('renders an unknown-size gate without hiding the other side', (
    tester,
  ) async {
    final cache = await tester.runAsync(() => _cache(temporaryDirectory));
    final producer = FakePreviewProducer();
    final right = File('${temporaryDirectory.path}/gate-local.txt');
    right.writeAsStringSync('local remains visible');
    final controller = _controller(
      left: _remote(SyncSide.left),
      right: _local(SyncSide.right, right),
      previewCache: cache,
      previewProducer: producer,
      thresholdBytes: 3,
    );
    addTearDown(controller.dispose);

    await tester.runAsync(() async {
      unawaited(controller.start());
      await _until(
        () =>
            producer.specs.isNotEmpty &&
            controller.right.phase == SyncComparePhase.ready,
      );
    });
    final spec = producer.specs.single;
    expect(spec.gate!.thresholdBytes, 3);
    spec.gate!.onThresholdReached?.call(6);
    expect(controller.left.phase, SyncComparePhase.gateConfirm);
    await _pumpView(tester, controller);
    await tester.pump();

    expect(find.text('6 B downloaded so far. Keep going?'), findsOneWidget);
    expect(find.text('local remains visible'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Keep downloading'),
      findsOneWidget,
    );

    controller.cancel(SyncSide.left);
    await tester.runAsync(controller.start);
  });

  testWidgets('unmount cancels an active comparison download', (tester) async {
    final cache = await tester.runAsync(() => _cache(temporaryDirectory));
    final producer = FakePreviewProducer();
    final right = File('${temporaryDirectory.path}/dispose-local.txt');
    right.writeAsStringSync('local');
    final controller = _controller(
      left: _remote(SyncSide.left, size: 12),
      right: _local(SyncSide.right, right),
      previewCache: cache,
      previewProducer: producer,
    );

    await tester.runAsync(() async {
      unawaited(controller.start());
      await _until(() => producer.specs.isNotEmpty);
    });
    await _pumpView(tester, controller);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _until(() => producer.cancels.isNotEmpty));

    expect(producer.cancels, ['produce-0']);
  });

  group('diff', () {
    testWidgets('Find in a diff layout opens Separate and that side\'s find '
        'bar', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'one\ntwo\n',
        'one\nthree\n',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();
      expect(find.byType(PlanchetteEditor), findsNothing);

      await tester.tap(_inSide('sync.compare.right', find.byTooltip('Find')));
      await tester.pump();
      await tester.pump();

      expect(find.byType(PlanchetteEditor), findsNWidgets(2));
      expect(_inSide('sync.compare.right', _findFields()), findsOneWidget);
      expect(_inSide('sync.compare.left', _findFields()), findsNothing);
    });

    testWidgets('a comparing card keeps the files one tap away', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'one\ntwo\n',
        'one\nthree\n',
      );
      final diffs = _FakeDiffs();
      await _pumpView(tester, controller, startDiff: diffs.start);
      await tester.pump();

      expect(find.byKey(const ValueKey(CompareKey.computing)), findsOneWidget);
      expect(find.text('Comparing lines…'), findsOneWidget);
      expect(find.byType(PlanchetteEditor), findsNothing);
      expect(diffs.completers, hasLength(1));

      await tester.tap(find.text('Show files now'));
      await tester.pump();
      expect(find.byType(PlanchetteEditor), findsNWidgets(2));

      diffs.completers.single.complete(
        compareTexts('one\ntwo\n', 'one\nthree\n'),
      );
      await tester.pump();

      expect(find.byType(PlanchetteEditor), findsNWidgets(2));
      expect(find.text('1 changed region'), findsOneWidget);
    });

    testWidgets('unified lists left-only rows before right-only rows', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'same\nold one\nold two\nend\n',
        'same\nnew one\nend\n',
      );
      final semantics = tester.ensureSemantics();
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      await tester.tap(find.text('Unified'));
      await tester.pump();

      final labels = [
        'Left line 1, right line 1',
        'Left only, line 2',
        'Left only, line 3',
        'Right only, line 2',
        'Left line 4, right line 3',
      ];
      final tops = [
        for (final label in labels)
          tester.getTopLeft(find.bySemanticsLabel(label)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(labels.length));
      await _captureView(tester, 'compare-diff-unified');
      semantics.dispose();
    });

    testWidgets('n and N step through changed regions and wrap', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        _numberedLines(300),
        _numberedLines(300, {20: 'edit 20', 150: 'edit 150', 280: 'edit 280'}),
      );
      final semantics = tester.ensureSemantics();
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();
      expect(find.text('3 changed regions'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
      expect(find.bySemanticsLabel('Change 1 of 3'), findsOneWidget);
      final first = _rowsPosition(tester).pixels;

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(_rowsPosition(tester).pixels, greaterThan(first));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);

      await _pressShifted(tester, LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey(CompareKey.previousChange)));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey(CompareKey.nextChange)));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the first n starts at the top visible region', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        _numberedLines(300),
        _numberedLines(300, {20: 'edit 20', 150: 'edit 150', 280: 'edit 280'}),
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      _rowsPosition(tester).jumpTo(18.9 * 100);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      expect(find.text('2/3'), findsOneWidget);
    });

    testWidgets('switching layouts keeps the active region', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        _numberedLines(300),
        _numberedLines(300, {20: 'edit 20', 150: 'edit 150', 280: 'edit 280'}),
      );
      final semantics = tester.ensureSemantics();
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);

      await tester.tap(find.text('Unified'));
      await tester.pumpAndSettle();

      expect(find.text('2/3'), findsOneWidget);
      expect(find.bySemanticsLabel('Right only, line 150'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('n does nothing in Separate', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'one\ntwo\n',
        'one\nthree\n',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      await tester.tap(find.text('Separate'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(
        find.byKey(const ValueKey(CompareKey.regionPosition)),
        findsNothing,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey(CompareKey.nextChange)),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('Side by side'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey(CompareKey.regionPosition)),
        findsNothing,
      );
    });

    testWidgets('identical files say so and disable navigation', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'same\ntext\n',
        'same\ntext\n',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      expect(find.text('The files are identical.'), findsOneWidget);
      expect(find.text('No changed regions'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey(CompareKey.nextChange)),
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(
        find.byKey(const ValueKey(CompareKey.regionPosition)),
        findsNothing,
      );
    });

    testWidgets('same text with CRLF and LF says only line endings differ', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'same\r\ntext\r\n',
        'same\ntext\n',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      expect(find.text('Line endings differ: CRLF vs LF'), findsOneWidget);
      expect(
        find.text(
          'The text is identical; the files differ only in line endings or '
          'the byte order mark.',
        ),
        findsOneWidget,
      );
      expect(find.text('The files are identical.'), findsNothing);
    });

    testWidgets('a missing final newline is one changed region', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'a\nb',
        'a\nb\n',
      );
      final semantics = tester.ensureSemantics();
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      expect(find.text('1 changed region'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Right only, line 3')),
        matchesSemantics(label: 'Right only, line 3', value: 'Blank line'),
      );
      semantics.dispose();
    });

    testWidgets('over the line cap keeps the separate editors with a notice', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'a\r\nb\r\nc\r\nd\r\n',
        'a\nb\n',
      );
      await _pumpView(
        tester,
        controller,
        startDiff: _diffWith(maximumLines: 3),
      );
      await tester.pump();

      expect(
        find.text(
          "Changes aren't marked: comparison is limited to 3 lines per file "
          '(left 4, right 2).',
        ),
        findsOneWidget,
      );
      expect(find.byType(PlanchetteEditor), findsNWidgets(2));
      expect(find.byKey(const ValueKey(CompareKey.changeBar)), findsNothing);
      expect(find.text('Line endings differ: CRLF vs LF'), findsOneWidget);

      await tester.tap(_inSide('sync.compare.left', find.byTooltip('Find')));
      await tester.pump();
      expect(_findFields(), findsOneWidget);
    });

    testWidgets('the cap notice groups thousands', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'a\n',
        'b\n',
      );
      await _pumpView(
        tester,
        controller,
        startDiff: (left, right) => TextComparisonTask.completed(
          const TextComparisonOverLineCap(
            leftLines: 20001,
            rightLines: 3,
            maximumLines: compareMaximumLines,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text(
          "Changes aren't marked: comparison is limited to 20,000 lines per "
          'file (left 20,001, right 3).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a failed diff falls back with a notice and never claims no '
        'changes', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'one\n',
        'two\n',
      );
      await _pumpView(
        tester,
        controller,
        startDiff: (left, right) =>
            TextComparisonTask.completed(const TextComparisonFailed()),
      );
      await tester.pump();

      expect(find.text("Changes couldn't be computed."), findsOneWidget);
      expect(find.byType(PlanchetteEditor), findsNWidgets(2));
      expect(find.text('No changed regions'), findsNothing);
      expect(find.text('The files are identical.'), findsNothing);
      expect(find.byKey(const ValueKey(CompareKey.changeBar)), findsNothing);
    });

    testWidgets('a simplified diff says so', (tester) async {
      final left = [for (var i = 0; i < 60; i++) 'l${i % 7}'].join('\n');
      final right = [for (var i = 0; i < 60; i++) 'l${(i * 3) % 5}'].join('\n');
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        left,
        right,
      );
      await _pumpView(tester, controller, startDiff: _diffWith(costLimit: 1));
      await tester.pump();

      expect(
        find.text(
          'Some changes are shown as larger blocks because the files differ '
          'widely.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey(CompareKey.rows)), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets('diff rows paint the ${brightness.name} theme\'s diff '
          'colours', (tester) async {
        final controller = await _startedPair(
          tester,
          temporaryDirectory,
          'same\nold\nleft only\nend\n',
          'same\nnew\nend\n',
        );
        await _pumpView(
          tester,
          controller,
          startDiff: _syncDiff,
          brightness: brightness,
        );
        await tester.pump();
        final colors = CompareDiffColors.of(
          tester.element(find.byKey(const ValueKey(CompareKey.rows))),
        );
        Finder filled(Color color) => find.byWidgetPredicate(
          (widget) => widget is ColoredBox && widget.color == color,
        );

        expect(filled(colors.removedFill), findsNWidgets(2));
        expect(filled(colors.addedFill), findsOneWidget);
        expect(filled(colors.gapFill), findsOneWidget);
        expect(filled(colors.activeRegion), findsNothing);
        final removedIcon = tester.widget<Icon>(
          find.byIcon(Icons.remove).first,
        );
        expect(removedIcon.color, colors.removedMarker);
        expect(
          tester.widget<Icon>(find.byIcon(Icons.add).first).color,
          colors.addedMarker,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();
        // One bar beside each half of the region's two rows; the gap
        // half has none.
        expect(filled(colors.activeRegion), findsNWidgets(3));
      });
    }

    testWidgets('rows and the separate editors follow the editor text size', (
      tester,
    ) async {
      final long = List.filled(120, 'a').join();
      final textSize = EditorTextSizeController(initial: 20);
      addTearDown(textSize.dispose);
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'top\n$long\nend\n',
        'top\nshort\nend\n',
      );
      await _pumpView(
        tester,
        controller,
        startDiff: _syncDiff,
        size: const Size(1200, 1600),
        textSize: textSize,
      );
      await tester.pump();

      final wrapped = find.textContaining('aaaa');
      double fontSize(Finder text) =>
          tester.widget<Text>(text).style!.fontSize!;
      int chunks() => tester
          .renderObject<RenderParagraph>(wrapped)
          .text
          .toPlainText()
          .split('\n')
          .length;
      expect(fontSize(wrapped), 20);
      final chunksAt20 = chunks();

      await textSize.setTextSize(28);
      await tester.pump();

      expect(fontSize(wrapped), 28);
      expect(fontSize(find.text('short')), 28);
      // Larger text wraps into more lines, and the row grows to hold them
      // with nothing cut at a line's end.
      expect(chunks(), greaterThan(chunksAt20));
      expect(
        tester.getBottomLeft(wrapped).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('end').first).dy),
      );
      final paragraph = tester.renderObject<RenderParagraph>(wrapped);
      expect(
        paragraph.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(paragraph.size.width + 0.01),
      );
      // The −/+ markers grow with the text, in a slot wide enough for them.
      final marker = find.byIcon(Icons.remove).first;
      expect(tester.widget<Icon>(marker).size, 28);
      expect(tester.getSize(marker).width, greaterThanOrEqualTo(28));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Separate'));
      await tester.pump();
      final editors = tester.widgetList<PlanchetteEditor>(
        find.byType(PlanchetteEditor),
      );
      expect(editors, hasLength(2));
      expect(
        editors.map((editor) => editor.textStyle.fontSize),
        everyElement(28),
      );
    });

    testWidgets('a text size change keeps the place inside a tall row', (
      tester,
    ) async {
      final long = List.filled(400, 'q').join();
      final textSize = EditorTextSizeController();
      addTearDown(textSize.dispose);
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'top\n$long\n${_numberedLines(100)}',
        'changed\n$long\n${_numberedLines(100)}',
      );
      await _pumpView(
        tester,
        controller,
        startDiff: _syncDiff,
        textSize: textSize,
      );
      await tester.pump();
      // Five lines into the tall second row.
      _rowsPosition(tester).jumpTo(tester.getSize(find.text('top')).height * 6);
      await tester.pump();

      await textSize.setTextSize(20);
      await tester.pump();
      await tester.pump();

      // Each line and the row grew; the offset keeps its share of the row
      // instead of staying at the old pixel offset. The first row is now
      // above the viewport, in its cache.
      final line = tester.getSize(find.text('top', skipOffstage: false)).height;
      final rowHeight = tester
          .getSize(find.textContaining('qqqq').first)
          .height;
      final pixels = _rowsPosition(tester).pixels;
      expect(pixels, greaterThan(line + line * 5));
      expect(pixels, lessThan(line + rowHeight));
    });

    testWidgets('long lines wrap at column boundaries and paired rows stay '
        'aligned', (tester) async {
      final long = List.filled(120, 'a').join();
      // At 1200 px the side-by-side text area has half a pixel to spare,
      // so any spacing the measurement misses clips each chunk's end.
      for (final (width, scale) in [
        (600.0, 1.0),
        (600.0, 2.0),
        (1200.0, 1.0),
      ]) {
        // The view owns its controller and disposes it with the route.
        final directory = Directory('${temporaryDirectory.path}/$width-$scale')
          ..createSync();
        final controller = await _startedPair(
          tester,
          directory,
          'top\n$long\nend\n',
          'top\nshort\nend\n',
        );
        await _pumpView(
          tester,
          controller,
          startDiff: _syncDiff,
          size: Size(width, 1600),
          textScale: scale,
        );
        await tester.pump();

        final wrapped = find.textContaining('aaaa');
        final paragraph = tester.renderObject<RenderParagraph>(wrapped);
        final text = paragraph.text.toPlainText();
        final chunks = text.split('\n');
        expect(chunks.length, greaterThan(1), reason: 'scale $scale');
        expect(chunks.join(), long);
        // The row holds every wrapped line: nothing is clipped and the
        // next row starts below the last one.
        expect(
          tester.getBottomLeft(wrapped).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.text('end').first).dy),
        );
        expect(
          tester.getTopLeft(wrapped).dy,
          moreOrLessEquals(tester.getTopLeft(find.text('short')).dy),
        );
        // Every chunk fits across its box: nothing at a line's end is cut.
        expect(
          paragraph.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(paragraph.size.width + 0.01),
        );
        expect(find.text('end'), findsNWidgets(2));
        expect(
          tester.getTopLeft(find.text('end').first).dy,
          moreOrLessEquals(tester.getTopLeft(find.text('end').last).dy),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('very long lines say how much is hidden', (tester) async {
      final long = List.filled(12000, 'x').join();
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        '$long\n',
        'short\n',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      final note = find.text('2000 more characters not shown');
      expect(note, findsOneWidget);
      // The note sits on the removed wash, where only the row's own text
      // colour is held to 4.5:1 on every preset.
      expect(
        tester.widget<Text>(note).style!.color,
        CompareDiffColors.of(tester.element(note)).removedText,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact posture defaults to unified with icon-only segments', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'same\nold\nend\n',
        'same\nnew\nend\n',
      );
      final semantics = tester.ensureSemantics();
      await _pumpView(
        tester,
        controller,
        startDiff: _syncDiff,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
      );
      await tester.pump();

      expect(find.text('Side by side'), findsNothing);
      expect(find.byTooltip('Side by side'), findsOneWidget);
      expect(find.byTooltip('Unified'), findsOneWidget);
      final removed = tester.getTopLeft(
        find.bySemanticsLabel('Left only, line 2'),
      );
      final added = tester.getTopLeft(
        find.bySemanticsLabel('Right only, line 2'),
      );
      expect(removed.dx, added.dx);
      expect(removed.dy, lessThan(added.dy));
      expect(tester.takeException(), isNull);
      await _captureView(tester, 'compare-diff-compact');
      semantics.dispose();
    });

    testWidgets('swapping the controller drops the in-flight diff', (
      tester,
    ) async {
      final first = await _startedPair(
        tester,
        temporaryDirectory,
        'one\n',
        'two\n',
      );
      final secondDirectory = Directory('${temporaryDirectory.path}/second')
        ..createSync();
      final second = await _startedPair(
        tester,
        secondDirectory,
        'three\n',
        'three\n',
      );
      final diffs = _FakeDiffs();
      await _pumpView(tester, first, startDiff: diffs.start);
      await tester.pump();
      expect(diffs.completers, hasLength(1));

      await _pumpView(tester, second, startDiff: diffs.start);
      await tester.pump();
      expect(diffs.cancels, 1);
      expect(diffs.completers, hasLength(2));

      diffs.completers.first.complete(compareTexts('one\n', 'two\n'));
      await tester.pump();
      expect(find.byKey(const ValueKey(CompareKey.computing)), findsOneWidget);

      diffs.completers.last.complete(compareTexts('three\n', 'three\n'));
      await tester.pump();
      expect(find.text('No changed regions'), findsOneWidget);
    });

    testWidgets('unmount cancels the diff', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'one\n',
        'two\n',
      );
      final diffs = _FakeDiffs();
      await _pumpView(tester, controller, startDiff: diffs.start);
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());

      expect(diffs.cancels, 1);
    });

    testWidgets('the real worker marks changes end to end', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'one\ntwo\n',
        'one\nthree\n',
      );
      TextComparisonTask? task;
      await _pumpView(
        tester,
        controller,
        startDiff: (left, right) {
          final started = Zone.root.run(() => startTextComparison(left, right));
          task = started;
          return started;
        },
      );
      await tester.pump();
      expect(find.text('Comparing lines…'), findsOneWidget);

      // A worker started in the test's fake-async zone would queue its
      // reply there; the root zone delivers it while runAsync waits.
      await tester.runAsync(() => task!.result);
      await tester.pump();

      expect(find.text('1 changed region'), findsOneWidget);
    });

    testWidgets('n and End reach rows far below wrapped rows', (tester) async {
      final long = List.filled(200, 'w').join();
      String file(String changed) => [
        for (var i = 1; i <= 3000; i++)
          i == 2501 ? changed : (i <= 200 ? 'short $i' : '$long $i'),
      ].join('\n');
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        '${file('$long 2501')}\n',
        '${file('changed 2501')}\n',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
      expect(find.textContaining('changed 2501'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      final position = _rowsPosition(tester);
      expect(position.pixels, position.maxScrollExtent);
      // The last row is the empty line after the final newline.
      expect(find.text('3001'), findsNWidgets(2));
    });

    testWidgets('squeezed columns neither clip a chunk nor overflow the row', (
      tester,
    ) async {
      final long = List.filled(60, 'x').join();
      final rest = [for (var i = 2; i <= 10001; i++) 'line $i'].join('\n');
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        '$long\n$rest\n',
        'short\n$rest\n',
      );
      await _pumpView(
        tester,
        controller,
        startDiff: _syncDiff,
        size: const Size(320, 900),
        platform: TargetPlatform.android,
        textScale: 2,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Side by side'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.textContaining('xx'),
      );
      expect(
        paragraph.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(paragraph.size.width + 0.01),
      );
    });

    testWidgets('controls and separators show as symbols on one line', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'top\nab\u000ccd ef\u000bgh\nend\n',
        'top\nshort\nend\n',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      final symbols = find.text('ab␌cd␤ef␋gh');
      expect(symbols, findsOneWidget);
      expect(
        tester.getSize(symbols).height,
        tester.getSize(find.text('short')).height,
      );
    });

    testWidgets('a rotation across the posture keeps the active region', (
      tester,
    ) async {
      final edits = {for (var i = 11; i <= 110; i++) i: 'early edit $i'};
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        _numberedLines(400),
        _numberedLines(400, {...edits, 300: 'edit 300'}),
      );
      await _pumpView(
        tester,
        controller,
        startDiff: _syncDiff,
        size: const Size(500, 900),
        platform: TargetPlatform.android,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('edit 300'), findsOneWidget);

      tester.view.physicalSize = const Size(900, 900);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Side by side'), findsNothing);
      expect(find.text('Side by side'), findsOneWidget);
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('edit 300'), findsOneWidget);
    });

    testWidgets('a resize that keeps the wrap keeps the scroll offset', (
      tester,
    ) async {
      final long = List.filled(400, 'q').join();
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'top\n$long\n${_numberedLines(100)}',
        'changed\n$long\n${_numberedLines(100)}',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();
      _rowsPosition(tester).jumpTo(200);
      await tester.pump();

      tester.view.physicalSize = const Size(1201, 720);
      await tester.pump();
      await tester.pump();

      expect(_rowsPosition(tester).pixels, 200);
    });

    testWidgets('a resize that rewraps keeps the place inside a tall row', (
      tester,
    ) async {
      final long = List.filled(400, 'q').join();
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        'top\n$long\n${_numberedLines(100)}',
        'changed\n$long\n${_numberedLines(100)}',
      );
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();
      final line = tester.getSize(find.text('top')).height;
      // Five lines into the tall second row.
      _rowsPosition(tester).jumpTo(line * 6);
      await tester.pump();

      tester.view.physicalSize = const Size(800, 720);
      await tester.pump();
      await tester.pump();

      // The row grew taller; the offset keeps its share of the row
      // instead of snapping back to the row's start.
      final rowTop = line;
      final rowHeight = tester
          .getSize(find.textContaining('qqqq').first)
          .height;
      final pixels = _rowsPosition(tester).pixels;
      expect(pixels, greaterThan(rowTop + line * 5));
      expect(pixels, lessThan(rowTop + rowHeight));
    });

    testWidgets('the count, position and layout switch each read on their '
        'own', (tester) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        _numberedLines(30),
        _numberedLines(30, {5: 'edit 5', 20: 'edit 20'}),
      );
      final semantics = tester.ensureSemantics();
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      expect(
        tester.getSemantics(find.byKey(const ValueKey(CompareKey.regionCount))),
        matchesSemantics(label: '2 changed regions', isLiveRegion: true),
      );
      expect(find.bySemanticsLabel('Comparison layout'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Change 1 of 2'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('typing in a find bar while the other side loads keeps the '
        'editors', (tester) async {
      final cache = await tester.runAsync(() => _cache(temporaryDirectory));
      final producer = FakePreviewProducer();
      final right = File('${temporaryDirectory.path}/local.txt')
        ..writeAsStringSync('one\ntwo\n');
      final controller = _controller(
        left: _remote(SyncSide.left, size: 12),
        right: _local(SyncSide.right, right),
        previewCache: cache,
        previewProducer: producer,
      );
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        unawaited(controller.start());
        await _until(
          () =>
              producer.specs.isNotEmpty &&
              controller.right.phase == SyncComparePhase.ready,
        );
      });
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();
      await tester.tap(_inSide('sync.compare.right', find.byTooltip('Find')));
      await tester.pump();
      expect(_findFields(), findsOneWidget);

      await tester.runAsync(() async {
        await producer.complete(0, utf8.encode('one\nfour\n'));
        await _until(() => controller.left.phase == SyncComparePhase.ready);
      });
      await tester.pump();
      await tester.pump();

      expect(find.byType(PlanchetteEditor), findsNWidgets(2));
      expect(_findFields(), findsOneWidget);
      expect(find.text('1 changed region'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(
        find.byKey(const ValueKey(CompareKey.regionPosition)),
        findsNothing,
      );
    });

    testWidgets('a cut line is read with how much it leaves out', (
      tester,
    ) async {
      final long = List.filled(12000, 'x').join();
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        '$long\n',
        'short\n',
      );
      final semantics = tester.ensureSemantics();
      await _pumpView(tester, controller, startDiff: _syncDiff);
      await tester.pump();

      final node = tester.getSemantics(
        find.bySemanticsLabel('Left only, line 1'),
      );
      expect(node.value, endsWith(' 2000 more characters not shown'));
      expect(node.value, startsWith('x' * 10000));
      semantics.dispose();
    });

    testWidgets('the change bar never overflows', (tester) async {
      final edits = {for (var i = 1; i <= 300; i++) i * 3: 'edit ${i * 3}'};
      for (final (width, scale) in [
        (320.0, 1.0),
        (640.0, 1.0),
        (776.0, 1.0),
        (1200.0, 2.0),
      ]) {
        final directory = Directory('${temporaryDirectory.path}/$width-$scale')
          ..createSync();
        final controller = await _startedPair(
          tester,
          directory,
          _numberedLines(900),
          _numberedLines(900, edits),
        );
        await _pumpView(
          tester,
          controller,
          startDiff: _syncDiff,
          size: Size(width, 900),
          textScale: scale,
        );
        await tester.pump();
        await _pressShifted(tester, LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();

        expect(find.text('300/300'), findsOneWidget, reason: '$width');
        expect(tester.takeException(), isNull, reason: '$width x $scale');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('n works from the app bar of a pushed compare route', (
      tester,
    ) async {
      final controller = await _startedPair(
        tester,
        temporaryDirectory,
        _numberedLines(30),
        _numberedLines(30, {5: 'edit 5'}),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPoltergeistTheme(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CompareView(controller: controller, startDiff: _syncDiff),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final back = find.byType(BackButton);
      Focus.of(
        tester.element(find.descendant(of: back, matching: find.byType(Icon))),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      expect(find.text('1/1'), findsOneWidget);
    });
  });
}

Finder _findFields() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && widget.decoration?.hintText == 'Find in file',
);

Future<void> _pumpView(
  WidgetTester tester,
  SyncCompareController controller, {
  DateTime Function()? clock,
  String? title,
  TextComparisonStarter? startDiff,
  Size size = const Size(1200, 720),
  TargetPlatform? platform,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  EditorTextSizeModel? textSize,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final capture = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
  final base = buildPoltergeistTheme(
    capture ? Brightness.light : brightness,
    platform: platform,
  );
  final theme = capture
      ? base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
          primaryTextTheme: base.primaryTextTheme.apply(
            fontFamily: 'DejaVu Sans',
          ),
        )
      : base;
  return tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('capture.syncCompare'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: CompareView(
          controller: controller,
          title: title,
          clock: clock ?? () => DateTime.utc(2026, 10, 2),
          startDiff: startDiff ?? _FakeDiffs().start,
          textSize: textSize,
        ),
      ),
    ),
  );
}

/// Computes the diff on the test isolate, so it lands on the next pump.
TextComparisonTask _syncDiff(String left, String right) =>
    TextComparisonTask.completed(compareTexts(left, right));

TextComparisonStarter _diffWith({
  int maximumLines = compareMaximumLines,
  int costLimit = lineDiffCostLimit,
}) =>
    (left, right) => TextComparisonTask.completed(
      compareTexts(
        left,
        right,
        maximumLines: maximumLines,
        costLimit: costLimit,
      ),
    );

/// Diffs that finish only when a test completes them.
final class _FakeDiffs {
  final completers = <Completer<TextComparison>>[];
  var cancels = 0;

  TextComparisonTask start(String left, String right) {
    final completer = Completer<TextComparison>();
    completers.add(completer);
    return TextComparisonTask(completer.future, onCancel: () => cancels++);
  }
}

Finder _inSide(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

/// [count] numbered lines with a final newline, some replaced.
String _numberedLines(int count, [Map<int, String> replaced = const {}]) =>
    '${[for (var i = 1; i <= count; i++) replaced[i] ?? 'line $i'].join('\n')}\n';

ScrollPosition _rowsPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey(CompareKey.rows)),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

Future<SyncCompareController> _startedPair(
  WidgetTester tester,
  Directory directory,
  String left,
  String right,
) async {
  final leftFile = File('${directory.path}/left.txt')..writeAsStringSync(left);
  final rightFile = File('${directory.path}/right.txt')
    ..writeAsStringSync(right);
  final controller = _controller(
    left: _local(SyncSide.left, leftFile),
    right: _local(SyncSide.right, rightFile),
  );
  addTearDown(controller.dispose);
  await tester.runAsync(controller.start);
  return controller;
}

Future<void> _pressShifted(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

Future<void> _loadRealFonts() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final directory =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home == null ? '' : '$home/.local/share/fonts');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')..addFont(_fontBytes(icons.path));
    await loader.load();
  }
  final sans = File('$directory/DejaVuSans.ttf');
  if (sans.existsSync()) {
    final loader = FontLoader('DejaVu Sans')..addFont(_fontBytes(sans.path));
    final bold = File('$directory/DejaVuSans-Bold.ttf');
    if (bold.existsSync()) loader.addFont(_fontBytes(bold.path));
    await loader.load();
  }
  final mono = File('$directory/DejaVuSansMono.ttf');
  if (mono.existsSync()) {
    final loader = FontLoader('JetBrains Mono')..addFont(_fontBytes(mono.path));
    await loader.load();
  }
}

Future<void> _captureView(WidgetTester tester, String name) async {
  if (Platform.environment['POLTERGEIST_CAPTURE'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture.syncCompare')),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  });
  Directory(_captureDirectory).createSync(recursive: true);
  File('$_captureDirectory/$name.png').writeAsBytesSync(bytes!);
}

SyncCompareController _controller({
  required SyncCompareSource left,
  required SyncCompareSource right,
  PreviewCache? previewCache,
  PreviewProducer? previewProducer,
  int thresholdBytes = 1024,
}) => SyncCompareController(
  request: SyncCompareRequest(
    relativePath: _relativePath,
    left: left,
    right: right,
  ),
  previewCache: previewCache,
  previewProducer: previewProducer,
  largeDownloadThresholdBytes: () => thresholdBytes,
);

LocalSyncCompareSource _local(SyncSide side, File file, {int? mtimeSecs}) =>
    LocalSyncCompareSource(
      side: side,
      fullPath: file.path,
      snapshot: EntrySnapshot(
        kind: EntryKind.file,
        size: file.lengthSync(),
        mtimeSecs: mtimeSecs,
      ),
    );

RemoteSyncCompareSource _remote(SyncSide side, {int? size}) =>
    RemoteSyncCompareSource(
      side: side,
      fullPath: '/remote/notes.txt',
      snapshot: EntrySnapshot(kind: EntryKind.file, size: size),
      serverId: _serverId,
    );

Future<PreviewCache> _cache(Directory parent) async {
  final cache = PreviewCache(directory: Directory('${parent.path}/cache'));
  await cache.open();
  return cache;
}

Future<void> _until(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not reached');
}
