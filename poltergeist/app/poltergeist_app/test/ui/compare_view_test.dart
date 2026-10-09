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
import 'package:poltergeist_app/services/sync_compare_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
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

  testWidgets('shows two locked editors with independent find bars', (
    tester,
  ) async {
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

    await tester.runAsync(controller.start);
    await _pumpView(tester, controller);
    await tester.pump();

    expect(find.byKey(const ValueKey('sync.compare.view')), findsOneWidget);
    expect(find.text('Compare notes.txt'), findsOneWidget);
    expect(find.text(left.path), findsOneWidget);
    expect(find.text(right.path), findsOneWidget);
    expect(find.text('Line endings differ: CRLF vs LF'), findsOneWidget);
    expect(find.text('BOM differs'), findsOneWidget);

    final editors = tester
        .widgetList<PlanchetteEditor>(find.byType(PlanchetteEditor))
        .toList();
    expect(editors, hasLength(2));
    expect(editors.map((editor) => editor.editingLocked), everyElement(isTrue));
    expect(editors.map((editor) => editor.showStatus), everyElement(isFalse));
    expect(editors[0].controller, isNot(same(editors[1].controller)));
    await _captureView(tester, 'after-sync-pair-compare');

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sync.compare.left')),
        matching: find.byTooltip('Find'),
      ),
    );
    await tester.pump();
    expect(_findFields(), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sync.compare.right')),
        matching: find.byTooltip('Find'),
      ),
    );
    await tester.pump();
    expect(_findFields(), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
  });

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
}

Finder _findFields() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && widget.decoration?.hintText == 'Find in file',
);

Future<void> _pumpView(
  WidgetTester tester,
  SyncCompareController controller, {
  DateTime Function()? clock,
}) {
  tester.view.physicalSize = const Size(1200, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final capture = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
  final base = buildPoltergeistTheme(
    capture ? Brightness.light : Brightness.dark,
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
        home: CompareView(
          controller: controller,
          clock: clock ?? () => DateTime.utc(2026, 10, 2),
        ),
      ),
    ),
  );
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
