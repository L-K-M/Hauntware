// SyncPlanView coverage (M8): the ready-state §7 surface — header
// clauses, filter chips, grouped rows, the per-row override menu, the
// conflict bar, rail 3's typed-DELETE dialog, rail 4's refusal banner,
// and the run controls — plus the POLTERGEIST_CAPTURE-gated artifact
// set the task captures ask for.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_app/services/sync_trash_activity.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/compare_view.dart';
import 'package:poltergeist_app/ui/sync/sync_commands.dart';
import 'package:poltergeist_app/ui/sync/sync_plan_view.dart';
import 'package:poltergeist_app/ui/sync/sync_rules_edit_request.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';

/// PNGs land in tasks/run3-task90/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set); POLTERGEIST_CAPTURE=1 gates every
/// artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task90/captures';

enum _ControllerStartZone { runAsync, current }

bool _usesExistingLocalRoots(SyncPlanController controller) {
  for (final endpoint in [controller.pair.left, controller.pair.right]) {
    if (endpoint is! LocalEndpoint || !Directory(endpoint.path).existsSync()) {
      return false;
    }
  }

  return true;
}

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

/// Loads the faces the theme resolves plus MaterialIcons — the
/// widget-test default font renders hollow boxes, so captures ask the
/// host for DejaVu (POLTERGEIST_CAPTURE_FONT_DIR or the usual user font
/// directory).
Future<void> _loadRealFonts() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final dir =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home != null ? '$home/.local/share/fonts' : '');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
  final sans = File('$dir/DejaVuSans.ttf');
  if (!sans.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader('DejaVu Sans')..addFont(_fontBytes(sans.path));
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  final mono = File('$dir/DejaVuSansMono.ttf');
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
  }
}

/// The capture shell — a RepaintBoundary at the size a pane tab would
/// occupy, l10n delegates + the app theme wired exactly as the shell
/// does.
Future<void> pumpSyncPlanView(
  WidgetTester tester,
  SyncPlanController controller, {
  VoidCallback? onSaveAsFavorite,
  ValueChanged<SyncRulesEditRequest>? onEditRules,
  Future<void> Function(RegisteredCommand command)? onRunCommand,
  DateTime Function()? clock,
  Size size = const Size(1200, 720),
}) => _pumpSyncPlanView(
  tester,
  controller,
  onSaveAsFavorite: onSaveAsFavorite,
  onEditRules: onEditRules,
  onRunCommand: onRunCommand,
  clock: clock,
  size: size,
);

Future<void> _pumpSyncPlanView(
  WidgetTester tester,
  SyncPlanController controller, {
  VoidCallback? onSaveAsFavorite,
  ValueChanged<SyncRulesEditRequest>? onEditRules,
  Future<void> Function(RegisteredCommand command)? onRunCommand,
  DateTime Function()? clock,
  Size size = const Size(1200, 720),
  _ControllerStartZone startZone = _ControllerStartZone.runAsync,
}) async {
  if (controller.phase == SyncPlanPhase.scanning) {
    Future<void> start() async {
      controller.start();
      await pumpUntil(() => controller.phase != SyncPlanPhase.scanning);
      if (controller.phase != SyncPlanPhase.recovery &&
          _usesExistingLocalRoots(controller)) {
        await pumpUntil(() => !controller.trashPurgeBlocksActions);
      }
    }

    if (startZone == _ControllerStartZone.current) {
      await start();
    } else {
      await tester.runAsync(start);
    }
  }

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final capture = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
  final base = buildPoltergeistTheme(
    capture ? Brightness.light : Brightness.dark,
  );
  // The house capture convention: the loaded family must be requested
  // by the theme — FontLoader alone cannot reach default-styled text.
  final theme = capture
      ? base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
          primaryTextTheme: base.primaryTextTheme.apply(
            fontFamily: 'DejaVu Sans',
          ),
        )
      : base;
  final compareCommand = RegisteredCommand(
    id: kSyncCompareSelectedCommandId,
    scope: CommandScope.selection,
    label: (l10n) => l10n.syncCompareSelected,
    enabled: () => controller.canCompareSelection,
    run: (context) async {
      final comparison = controller.comparisonForSelection();
      if (comparison == null) return;
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => CompareView(controller: comparison, clock: clock),
          ),
        ),
      );
    },
  );
  await tester.pumpWidget(
    // The boundary wraps MaterialApp so overlay surfaces (the typed
    // DELETE dialog, the override popup) land inside the capture.
    RepaintBoundary(
      key: const ValueKey('capture.syncPlan'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: SyncPlanView(
              controller: controller,
              commands: [compareCommand],
              onRunCommand: onRunCommand ?? (command) => command.run(context),
              onSaveAsFavorite: onSaveAsFavorite,
              onEditRules: onEditRules,
              clock: clock,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The scan also canonicalizes trash roots through real filesystem I/O.
Future<void> pumpToReady(
  WidgetTester tester,
  SyncPlanController controller,
) async {
  expect(controller.phase, SyncPlanPhase.ready);
  // The phase flips inside a pump's microtask drain; the rebuild that
  // paints it lands on the next frame.
  await tester.pump();
}

SyncPlanController fakeController(
  Directory scratch, {
  required SyncPair pair,
  required SyncPlan plan,
  List<ScanWarning> warnings = const [],
}) {
  String rootOf(SyncEndpoint endpoint) => switch (endpoint) {
    LocalEndpoint(:final path) => path,
    RemoteEndpoint(:final path) => path,
  };

  return testController(
    pair: pair,
    scanner: FakeSyncScanner(
      left: testScanResult(rootOf(pair.left), const {}),
      right: testScanResult(rootOf(pair.right), const {}),
    ),
    differ: FakeSyncDiffer(plan),
    environment: testSyncEnvironment(scratch),
  );
}

Future<void> capturePlan(
  WidgetTester tester,
  String name, {
  bool inRunAsync = false,
}) async {
  if (Platform.environment['POLTERGEIST_CAPTURE'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture.syncPlan')),
  );
  Future<Uint8List> grab() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  // runAsync can't nest — callers already on the real event loop raster
  // directly.
  final bytes = inRunAsync ? await grab() : (await tester.runAsync(grab))!;
  Directory(_captureDir).createSync(recursive: true);
  File('$_captureDir/$name.png').writeAsBytesSync(bytes);
}

/// An upload-gated LocalFileSystem — the run blocks mid-copy once
/// [blocker] is armed, holding the controller in its running state for
/// the capture without racing the executor. Disarmed during the scan:
/// the scanner's case probe writes through the same verb.
final class _GatedUploadFs extends LocalFileSystem {
  Future<void> Function() blocker = () async {};

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    await blocker();
    return super.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }
}

final class _GatedRestoreFs extends LocalFileSystem {
  final Completer<void> restoreStarted = Completer<void>();
  final Completer<void> _restoreRelease = Completer<void>();
  var _blocked = false;

  void releaseRestore() {
    if (!_restoreRelease.isCompleted) _restoreRelease.complete();
  }

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    final isRestore =
        oldPath.contains(RemoteTrash.rootDirectoryName) &&
        !oldPath.contains(syncTrashRootMarkerName);
    if (!_blocked && isRestore) {
      _blocked = true;
      restoreStarted.complete();
      await _restoreRelease.future;
    }

    return super.rename(oldPath, newPath, overwrite: overwrite);
  }
}

/// A filesystem whose setTimes is refused — the local stand-in for
/// sshd-restricted's `sftp-server -P setstat,fsetstat` (the Docker leg
/// proves the same path over the wire in poltergeist_sync's integration
/// test). The run must still complete, flag the side mtime-unreliable,
/// and surface 05 §4's size-only notice.
final class _SetTimesRefusingFs extends LocalFileSystem {
  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) async => throw RemoteFileException(
    kind: RemoteFileErrorKind.permissionDenied,
    operation: 'setTimes',
    path: path,
    message: 'this server refuses setstat',
  );
}

final class _TrashListingFailureFs extends LocalFileSystem {
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    if (!path.endsWith('.poltergeist-trash')) {
      return super.listDirectory(path);
    }

    throw RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'list',
      path: path,
      message: 'offline',
    );
  }
}

final class _RestoreVerificationFailureFs extends LocalFileSystem {
  bool failRestoreVerification = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) {
    if (failRestoreVerification && path.contains(syncTrashRootMarkerName)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'verify sync trash',
        path: path,
        message: 'restore transport unavailable.',
      );
    }

    return super.stat(path, followLinks: followLinks);
  }
}

final class _RecoveryCleanupFailureFs extends LocalFileSystem {
  static const _restoreStagePrefix = '.poltergeist-restore-';

  bool failStageDelete = false;

  @override
  Future<void> delete(RemoteFileEntry entry) {
    if (failStageDelete &&
        p.basename(entry.path).startsWith(_restoreStagePrefix)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'delete restore stage',
        path: entry.path,
        message: 'connection lost during restore cleanup',
      );
    }

    return super.delete(entry);
  }
}

void main() {
  setUpAll(() async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await _loadRealFonts();
    }
  });

  testWidgets(
    'ready state renders the §7 surface: header, chips, rows, run label',
    (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair();
      final plan = testPlan(
        pair,
        [
          testItem(
            'a.txt',
            left: testFile(size: 100),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem(
            'docs',
            left: testDir,
            suggested: SyncActionType.makeDirRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem(
            'docs/inner.txt',
            left: testFile(size: 50),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem('same.txt', left: testFile(), right: testFile()),
        ],
        warnings: const [
          ScanWarning(
            relativePath: 'locked',
            side: SyncSide.left,
            message: 'could not descend into locked/',
            kind: ScanWarningKind.listingFailure,
          ),
        ],
      );
      final controller = fakeController(scratch, pair: pair, plan: plan);
      addTearDown(controller.dispose);

      var saved = false;
      await pumpSyncPlanView(
        tester,
        controller,
        onSaveAsFavorite: () => saved = true,
      );
      await pumpToReady(tester, controller);

      // Header: the verbatim consequence sentence — copy clause,
      // folder clause, the no-delete sentence (Update mode).
      expect(find.textContaining('Copy 2 new files'), findsOneWidget);
      expect(find.textContaining('create 1 folder'), findsOneWidget);
      expect(find.text('Nothing will be deleted.'), findsOneWidget);
      // Mode picker + rescan affordance.
      expect(find.text('Mode'), findsOneWidget);
      expect(find.text('Update'), findsWidgets);
      expect(find.text('Mirror'), findsOneWidget);
      expect(find.text('Additive'), findsOneWidget);

      // The collapsed-by-default warnings strip counts the warning.
      expect(find.text('1 scan warning'), findsOneWidget);

      // Filter chips carry the effective-action counts.
      expect(find.widgetWithText(FilterChip, 'All (4)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'New (3)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Skipped (1)'), findsOneWidget);
      expect(
        find.widgetWithText(FilterChip, 'Only show actions'),
        findsOneWidget,
      );

      // Rows group by action class (D32 §7): the folder and both new
      // files sit under Copy with their full paths. Only-actions
      // filtering (on by default) hides the skip row and so the
      // Skipped section.
      expect(find.byKey(const ValueKey('sync.section.copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync.section.skipped')), findsNothing);
      expect(find.text('docs'), findsOneWidget);
      expect(find.text('docs/inner.txt'), findsOneWidget);
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('same.txt'), findsNothing);

      // The run button spells out the consequences.
      expect(
        find.widgetWithText(FilledButton, 'Copy 2 · Create 1 Folder'),
        findsOneWidget,
      );
      expect(find.text('Save as Favorite…'), findsOneWidget);

      await capturePlan(tester, 'sync-plan-grouped');

      // Save-as-favorite delegates to the shell's name dialog.
      await tester.tap(find.text('Save as Favorite…'));
      expect(saved, isTrue);
    },
  );

  testWidgets('secondary tap opens the per-row override menu; Skip applies', (
    tester,
  ) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair();
    final item = testItem(
      'a.txt',
      left: testFile(),
      suggested: SyncActionType.copyLeftToRight,
      reason: SyncReason.onlyOnLeft,
    );
    final plan = testPlan(pair, [item]);
    final controller = fakeController(scratch, pair: pair, plan: plan);
    addTearDown(controller.dispose);

    await pumpSyncPlanView(tester, controller);
    await pumpToReady(tester, controller);

    await tester.tap(
      find.byKey(const ValueKey('sync.row.a.txt')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    // §7's override vocabulary: skip, the valid copy direction,
    // reset (disabled until an override exists).
    expect(find.text('Copy left → right'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Reset to suggested'), findsOneWidget);
    await capturePlan(tester, 'sync-plan-override-menu');

    await tester.tap(find.text('Skip'));
    await tester.pump();
    expect(item.effective, SyncActionType.skip);
    expect(item.userOverridden, isTrue);

    // The run button collapses to its empty consequence.
    expect(find.widgetWithText(FilledButton, 'Nothing to Do'), findsOneWidget);
  });

  testWidgets('double-clicking a two-file row opens compare', (tester) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final left = Directory('${scratch.path}/left')..createSync();
    final right = Directory('${scratch.path}/right')..createSync();
    final leftBytes = utf8.encode('alpha\r\nbeta\r\n');
    final rightBytes = [0xef, 0xbb, 0xbf, ...utf8.encode('alpha\ngamma\n')];
    File('${left.path}/a.txt').writeAsBytesSync(leftBytes);
    File('${right.path}/a.txt').writeAsBytesSync(rightBytes);
    final pair = testSyncPair(
      left: left.path,
      right: right.path,
      rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
    );
    final item = testItem(
      'a.txt',
      left: testFile(size: leftBytes.length, mtimeSecs: 1700000000),
      right: testFile(size: rightBytes.length, mtimeSecs: 1700000010),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [item]),
    );
    addTearDown(controller.dispose);

    await pumpSyncPlanView(
      tester,
      controller,
      clock: () => DateTime.fromMillisecondsSinceEpoch(
        1700000000 * Duration.millisecondsPerSecond,
      ),
    );
    await pumpToReady(tester, controller);
    await capturePlan(tester, 'before-sync-pair-compare');

    await tester.tap(find.byKey(const ValueKey('sync.row.a.txt')), pointer: 2);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('sync.row.a.txt')), pointer: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('sync.compare.view')), findsOneWidget);
    final comparison = tester.widget<CompareView>(find.byType(CompareView));
    expect(comparison.clock, isNotNull);
    expect(
      comparison.clock!(),
      DateTime.fromMillisecondsSinceEpoch(
        1700000000 * Duration.millisecondsPerSecond,
      ),
    );
  });

  testWidgets('double-click ignores a row without two files', (tester) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair();
    final item = testItem(
      'a.txt',
      left: testFile(size: 4),
      suggested: SyncActionType.copyLeftToRight,
      reason: SyncReason.onlyOnLeft,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [item]),
    );
    addTearDown(controller.dispose);

    await pumpSyncPlanView(tester, controller);
    await pumpToReady(tester, controller);

    await tester.tap(find.byKey(const ValueKey('sync.row.a.txt')), pointer: 2);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('sync.row.a.txt')), pointer: 1);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('sync.compare.view')), findsNothing);
  });

  testWidgets('context menu dispatches the registered compare command', (
    tester,
  ) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair();
    final item = testItem(
      'a.txt',
      left: testFile(),
      right: testFile(),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [item]),
    );
    addTearDown(controller.dispose);
    final ran = <String>[];

    await pumpSyncPlanView(
      tester,
      controller,
      onRunCommand: (command) async => ran.add(command.id),
    );
    await pumpToReady(tester, controller);

    await tester.tap(
      find.byKey(const ValueKey('sync.row.a.txt')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare Selected Item'));
    await tester.pump();

    expect(ran, [kSyncCompareSelectedCommandId]);
  });

  testWidgets('context menu selects its row and restores table focus', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair(
      rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
    );
    final first = testItem(
      'a.txt',
      left: testFile(),
      right: testFile(),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final second = testItem(
      'b.txt',
      left: testFile(),
      right: testFile(),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [first, second]),
    );
    addTearDown(controller.dispose);
    String? compared;

    await pumpSyncPlanView(
      tester,
      controller,
      onRunCommand: (_) async {
        compared = controller.comparisonForSelection()?.request.relativePath;
      },
    );
    await pumpToReady(tester, controller);
    final firstRow = find.byKey(const ValueKey('sync.row.a.txt'));
    final secondRow = find.byKey(const ValueKey('sync.row.b.txt'));

    await tester.tap(firstRow);
    await tester.pump();
    await tester.tap(secondRow, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final firstSemantics = tester.getSemantics(firstRow).getSemanticsData();
    final secondSemantics = tester.getSemantics(secondRow).getSemanticsData();
    expect(firstSemantics.flagsCollection.isSelected, ui.Tristate.isFalse);
    expect(secondSemantics.flagsCollection.isSelected, ui.Tristate.isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(compared, 'b.txt');
    semantics.dispose();
  });

  testWidgets('Enter and semantics expose the registered compare command', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair();
    final item = testItem(
      'a.txt',
      left: testFile(),
      right: testFile(),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [item]),
    );
    addTearDown(controller.dispose);
    final ran = <String>[];

    await pumpSyncPlanView(
      tester,
      controller,
      onRunCommand: (command) async => ran.add(command.id),
    );
    await pumpToReady(tester, controller);
    final row = find.byKey(const ValueKey('sync.row.a.txt'));

    expect(
      tester
          .getSemantics(row)
          .getSemanticsData()
          .hasAction(ui.SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(row);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(ran, [kSyncCompareSelectedCommandId]);
    semantics.dispose();
  });

  testWidgets('one-sided rows keep assistive selection activation', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair();
    final first = testItem(
      'a.txt',
      left: testFile(),
      suggested: SyncActionType.copyLeftToRight,
      reason: SyncReason.onlyOnLeft,
    );
    final second = testItem(
      'b.txt',
      left: testFile(),
      suggested: SyncActionType.copyLeftToRight,
      reason: SyncReason.onlyOnLeft,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [first, second]),
    );
    addTearDown(controller.dispose);
    final ran = <String>[];

    await pumpSyncPlanView(
      tester,
      controller,
      onRunCommand: (command) async => ran.add(command.id),
    );
    await pumpToReady(tester, controller);
    final row = find.byKey(const ValueKey('sync.row.b.txt'));
    final node = tester.getSemantics(row);

    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, ui.SemanticsAction.tap);
    await tester.pump();

    expect(
      tester.getSemantics(row).getSemanticsData().flagsCollection.isSelected,
      ui.Tristate.isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(ran, isEmpty);
    semantics.dispose();
  });

  testWidgets('double-clicking row controls does not open compare', (
    tester,
  ) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final left = Directory('${scratch.path}/left')..createSync();
    final right = Directory('${scratch.path}/right')..createSync();
    File('${left.path}/a.txt').writeAsStringSync('left');
    File('${right.path}/a.txt').writeAsStringSync('right');
    final pair = testSyncPair(
      left: left.path,
      right: right.path,
      rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
    );
    final item = testItem(
      'a.txt',
      left: testFile(size: 4),
      right: testFile(size: 5),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [item]),
    );
    addTearDown(controller.dispose);

    await pumpSyncPlanView(tester, controller);
    await pumpToReady(tester, controller);

    final checkbox = find.byKey(const ValueKey('sync.row.a.txt.check'));
    await tester.tap(checkbox, pointer: 2);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(checkbox, pointer: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('sync.compare.view')), findsNothing);

    final row = find.byKey(const ValueKey('sync.row.a.txt'));
    final glyph = find.descendant(of: row, matching: find.byType(InkWell));
    expect(glyph, findsOneWidget);
    await tester.tap(glyph, pointer: 2);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(glyph, pointer: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('sync.compare.view')), findsNothing);
  });

  testWidgets('conflict rows mount the bulk resolve bar', (tester) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair(
      rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
    );
    final conflict = testItem(
      'a.txt',
      left: testFile(mtimeSecs: 30),
      right: testFile(mtimeSecs: 20),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [conflict]),
    );
    addTearDown(controller.dispose);

    await pumpSyncPlanView(tester, controller);
    await pumpToReady(tester, controller);

    expect(find.text('Resolve conflicts:'), findsOneWidget);
    expect(find.text('Newer wins'), findsOneWidget);
    expect(find.text('Keep left'), findsOneWidget);
    expect(find.text('Keep right'), findsOneWidget);
    expect(find.text('Skip all'), findsOneWidget);
    // Conflicts gate the run — the button stays disabled until they
    // resolve (§7's decision-before-run rule).
    final runButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Nothing to Do'),
    );
    expect(runButton.onPressed, isNull);

    await tester.tap(find.text('Keep left'));
    await tester.pump();
    expect(conflict.effective, SyncActionType.updateLeftToRight);
    expect(find.text('Resolve conflicts:'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Copy 1'), findsOneWidget);
  });

  testWidgets('rail 4 refusal shows the banner and keeps Run disabled', (
    tester,
  ) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair(
      rules: const SyncRuleSet(deletions: DeletionPolicy.trash, maxDelete: 2),
    );
    final items = [
      for (var i = 0; i < 3; i++)
        testItem(
          'gone$i.txt',
          right: testFile(),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
    ];
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, items),
    );
    addTearDown(controller.dispose);
    SyncRulesEditRequest? request;

    await pumpSyncPlanView(
      tester,
      controller,
      onEditRules: (value) => request = value,
    );
    await pumpToReady(tester, controller);

    expect(find.text('Too many deletions'), findsOneWidget);
    expect(find.textContaining('over the 2-file cap'), findsOneWidget);
    await capturePlan(tester, 'sync-plan-maxdelete-refusal');

    // The consequence label still reports the plan; the button
    // refuses to arm it.
    final runButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete 3'),
    );
    expect(runButton.onPressed, isNull);

    await tester.tap(find.text('Save as Favorite & Adjust Rules…'));
    expect(request?.target, SyncRulesEditTarget.maxDelete);
  });

  testWidgets('docroot warning persists and targets the affected side', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    const rightPath = '/var/www/\u05d0';
    final pair = testSyncPair(right: rightPath);
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, const []),
    );
    addTearDown(controller.dispose);
    SyncRulesEditRequest? request;

    await pumpSyncPlanView(
      tester,
      controller,
      onEditRules: (value) => request = value,
    );
    await pumpToReady(tester, controller);

    expect(
      find.byKey(const ValueKey('sync.docrootWarning.right')),
      findsOneWidget,
    );
    expect(find.text('Trash may be public'), findsOneWidget);
    expect(find.textContaining('\u2066$rightPath\u2069'), findsOneWidget);
    expect(find.text('Use safer path'), findsOneWidget);
    final warningAction = tester.widget<TextButton>(
      find.byKey(const ValueKey('sync.docrootWarningAction.right')),
    );
    expect(
      warningAction.style?.foregroundColor?.resolve(const <WidgetState>{}),
      Theme.of(
        tester.element(find.byType(SyncPlanView)),
      ).colorScheme.onErrorContainer,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('sync.docrootWarning.right')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('sync.docrootWarningAction.right')),
    );
    expect(request?.target, SyncRulesEditTarget.docrootTrash);
    expect(request?.docrootWarning?.side, SyncSide.right);
    expect(
      request?.docrootWarning?.suggestedTrashPath,
      startsWith('~/.poltergeist-trash/root-'),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('sync.docrootWarning.right')))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('sync.docrootWarningAction.right')),
          )
          .label,
      contains('right'),
    );
    semantics.dispose();
  });

  testWidgets(
    'rail 3: the typed DELETE gate opens, stays disabled until typed, '
    'then the run executes',
    (tester) async {
      await tester.runAsync(() async {
        final scratch = Directory.systemTemp.createTempSync('pg-view-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final left = Directory('${scratch.path}/left')..createSync();
        final right = Directory('${scratch.path}/right')..createSync();
        // 10 deletes of 11 right files trips the fraction clause.
        for (var i = 0; i < 10; i++) {
          File('${right.path}/gone$i.txt').writeAsStringSync('x');
        }
        File('${right.path}/keep.txt').writeAsStringSync('k');
        File('${left.path}/a.txt').writeAsStringSync('a');
        final controller = SyncPlanController(
          pair: testSyncPair(
            left: left.path,
            right: right.path,
            rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
          ),
          environment: testSyncEnvironment(scratch),
          syncTasks: SyncQueueTasks(),
          deviceId: 'test-device',
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await _pumpSyncPlanView(
          tester,
          controller,
          startZone: _ControllerStartZone.current,
        );
        await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
        await tester.pump();
        expect(controller.needsTypedConfirmation, isTrue);

        // The action bar's consequence label arms the dialog, not the
        // run — a.txt's copy joins all 11 right-side deletes (mirror
        // deletes keep.txt too: left is authoritative).
        await tester.tap(
          find.widgetWithText(FilledButton, 'Copy 1 · Delete 11'),
        );
        // pumpAndSettle is fake-clock — inside runAsync only pump works.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('Confirm deletions'), findsOneWidget);
        expect(find.textContaining('Type DELETE'), findsWidgets);
        await capturePlan(tester, 'sync-plan-delete-confirm', inRunAsync: true);

        // Disabled until the field reads DELETE exactly. The dialog's
        // field shares the tree with the filter bar's — scope it.
        final confirmField = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        FilledButton confirm() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Delete'),
        );
        expect(confirm().onPressed, isNull);
        await tester.enterText(confirmField, 'DELET');
        await tester.pump();
        expect(confirm().onPressed, isNull);
        await tester.enterText(confirmField, 'DELETE');
        await tester.pump();
        expect(confirm().onPressed, isNotNull);

        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await pumpUntil(() => controller.phase == SyncPlanPhase.completed);
        await pumpUntil(() => !controller.trashPurgeBlocksActions);
        await tester.pump();
        expect(File('${right.path}/gone0.txt').existsSync(), isFalse);
        // The journal exposes the restore affordance.
        expect(find.text('Restore Trashed Files…'), findsOneWidget);
        expect(find.text('Copy Report'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'a running sync exposes Pause/Cancel; a failed run offers Retry',
    (tester) async {
      await tester.runAsync(() async {
        final scratch = Directory.systemTemp.createTempSync('pg-view-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final left = Directory('${scratch.path}/left')..createSync();
        final right = Directory('${scratch.path}/right')..createSync();
        File('${left.path}/a.txt').writeAsStringSync('payload');
        final gated = _GatedUploadFs();
        final controller = SyncPlanController(
          pair: testSyncPair(left: left.path, right: right.path),
          environment: testSyncEnvironment(
            scratch,
            localFileSystem: () => gated,
          ),
          syncTasks: SyncQueueTasks(),
          deviceId: 'test-device',
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await _pumpSyncPlanView(
          tester,
          controller,
          startZone: _ControllerStartZone.current,
        );
        await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
        await tester.pump();

        // Arm the gate post-scan (the case probe rides `upload` too),
        // then the run blocks mid-copy.
        final gate = Completer<void>();
        gated.blocker = () => gate.future;
        unawaited(controller.run());
        await pumpUntil(() => controller.isRunning);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(find.text('Pause'), findsOneWidget);
        expect(find.text('Cancel'), findsWidgets);
        await capturePlan(tester, 'sync-plan-running', inRunAsync: true);

        // Pause toggles the verb while the upload stays gated.
        await tester.tap(find.text('Pause'));
        await tester.pump();
        expect(find.text('Resume'), findsOneWidget);
        await tester.tap(find.text('Resume'));
        await tester.pump();

        gate.complete();
        await pumpUntil(() => controller.phase == SyncPlanPhase.completed);
        await tester.pump();
        expect(File('${right.path}/a.txt').readAsStringSync(), 'payload');
      });
    },
  );

  testWidgets('an active restore exposes a working Cancel action', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final left = Directory('${scratch.path}/left')..createSync();
      final right = Directory('${scratch.path}/right')..createSync();
      File('${left.path}/new.txt').writeAsStringSync('new');
      File('${right.path}/old-a.txt').writeAsStringSync('a');
      File('${right.path}/old-b.txt').writeAsStringSync('b');
      final fileSystem = _GatedRestoreFs();
      final controller = SyncPlanController(
        pair: testSyncPair(
          left: left.path,
          right: right.path,
          rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
        ),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => fileSystem,
        ),
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);

      await _pumpSyncPlanView(
        tester,
        controller,
        startZone: _ControllerStartZone.current,
      );
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      await pumpUntil(() => !controller.trashPurgeBlocksActions);
      await tester.pump();

      final restoreAction = find.text('Restore Trashed Files…');
      await tester.ensureVisible(restoreAction);
      await tester.pumpAndSettle();
      await tester.tap(restoreAction);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await fileSystem.restoreStarted.future;
      await tester.pumpAndSettle();

      expect(controller.isRestoringTrash, isTrue);
      final cancel = find.widgetWithText(TextButton, 'Cancel');
      expect(cancel, findsOneWidget);
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      await tester.tap(cancel);
      fileSystem.releaseRestore();
      await pumpUntil(() => !controller.isRestoringTrash);
      await tester.pumpAndSettle();

      expect(
        [
          'old-a.txt',
          'old-b.txt',
        ].where((name) => File('${right.path}/$name').existsSync()),
        hasLength(1),
      );
    });
  });

  testWidgets('restart recovery renders without an in-memory run', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-recovery-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final left = Directory('${scratch.path}/left')..createSync();
      final right = Directory('${scratch.path}/right')..createSync();
      File('${left.path}/entry').writeAsStringSync('replacement');
      Directory('${right.path}/entry').createSync();
      const rules = SyncRuleSet(
        direction: SyncDirection.leftToRight,
        deletions: DeletionPolicy.trash,
        conflictDefault: ConflictDefault.keepLeft,
      );
      final pair = testSyncPair(
        left: left.path,
        right: right.path,
        rules: rules,
      );
      final fileSystem = _RecoveryCleanupFailureFs();
      final environment = testSyncEnvironment(
        scratch,
        localFileSystem: () => fileSystem,
      );
      final interrupted = SyncPlanController(
        pair: pair,
        environment: environment,
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      interrupted.start();
      await pumpUntil(() => interrupted.phase == SyncPlanPhase.ready);
      await interrupted.run();
      fileSystem.failStageDelete = true;
      await expectLater(
        interrupted.restoreTrashed(),
        throwsA(isA<RemoteFileException>()),
      );
      interrupted.dispose();

      final controller = SyncPlanController(
        pair: pair,
        environment: environment,
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      await _pumpSyncPlanView(
        tester,
        controller,
        startZone: _ControllerStartZone.current,
      );
      await tester.pump();

      expect(controller.lastRun, isNull);
      expect(controller.recoveryPending, isTrue);
      expect(find.text('Interrupted restore'), findsOneWidget);
      expect(
        find.text(
          'A previous restore stopped before it finished. '
          'Sync is paused until you finish it.',
        ),
        findsOneWidget,
      );
      final recoveryAction = find.text('Finish Restore…');
      expect(recoveryAction, findsOneWidget);
      await capturePlan(tester, 'sync-restore-recovery', inRunAsync: true);

      await tester.ensureVisible(recoveryAction);
      await tester.tap(recoveryAction);
      await tester.pumpAndSettle();

      expect(find.text('Finish Interrupted Restore'), findsOneWidget);
      expect(
        find.text(
          'Finish the interrupted restore. Restores 1 original item. '
          'Removes 1 file created by this run.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(controller.recoveryPending, isTrue);
    });
  });

  testWidgets(
    'restore discloses replacement removal and reports restored items',
    (tester) async {
      await tester.runAsync(() async {
        final scratch = Directory.systemTemp.createTempSync('pg-view-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final left = Directory('${scratch.path}/left')..createSync();
        final right = Directory('${scratch.path}/right')..createSync();
        File('${left.path}/entry').writeAsStringSync('replacement');
        Directory('${right.path}/entry').createSync();
        final controller = SyncPlanController(
          pair: testSyncPair(
            left: left.path,
            right: right.path,
            rules: const SyncRuleSet(
              direction: SyncDirection.leftToRight,
              deletions: DeletionPolicy.trash,
              conflictDefault: ConflictDefault.keepLeft,
            ),
          ),
          environment: testSyncEnvironment(scratch),
          syncTasks: SyncQueueTasks(),
          deviceId: 'test-device',
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await _pumpSyncPlanView(
          tester,
          controller,
          startZone: _ControllerStartZone.current,
        );
        await controller.run();
        await pumpUntil(() => !controller.trashPurgeBlocksActions);
        await tester.pump();

        final restoreAction = find.text('Restore Trashed Files…');
        await tester.ensureVisible(restoreAction);
        await tester.tap(restoreAction);
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Restores 1 original item. '
            'Removes 1 file created by this run.',
          ),
          findsOneWidget,
        );
        await capturePlan(
          tester,
          'after-restore-confirmation-light',
          inRunAsync: true,
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
        await pumpUntil(() => !controller.isRestoringTrash);
        await tester.pumpAndSettle();

        expect(find.text('Restored 1 item'), findsOneWidget);
        expect(Directory('${right.path}/entry').existsSync(), isTrue);
      });
    },
  );

  testWidgets('restore failure is actionable and leaves retry available', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final left = Directory('${scratch.path}/left')..createSync();
      final right = Directory('${scratch.path}/right')..createSync();
      File('${left.path}/new.txt').writeAsStringSync('new');
      File('${right.path}/old.txt').writeAsStringSync('old');
      final fileSystem = _RestoreVerificationFailureFs();
      final controller = SyncPlanController(
        pair: testSyncPair(
          left: left.path,
          right: right.path,
          rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
        ),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => fileSystem,
        ),
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);

      await _pumpSyncPlanView(
        tester,
        controller,
        startZone: _ControllerStartZone.current,
      );
      await controller.run(deleteConfirmed: true);
      await pumpUntil(() => !controller.trashPurgeBlocksActions);
      await tester.pump();

      final restoreAction = find.text('Restore Trashed Files…');
      await tester.ensureVisible(restoreAction);
      await tester.tap(restoreAction);
      await tester.pumpAndSettle();
      fileSystem.failRestoreVerification = true;

      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await pumpUntil(() => !controller.isRestoringTrash);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Restore stopped. Check the connection and file state, then retry. '
          'Error: restore transport unavailable.',
        ),
        findsOneWidget,
      );
      expect(find.text('Restore Trashed Files…'), findsOneWidget);
      expect(controller.canRestore, isTrue);
    });
  });

  testWidgets('a failed item surfaces Retry Failed and retries to done', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final left = Directory('${scratch.path}/left')..createSync();
      final right = Directory('${scratch.path}/right')..createSync();
      final source = File('${left.path}/a.txt')..writeAsStringSync('x');
      final controller = SyncPlanController(
        pair: testSyncPair(left: left.path, right: right.path),
        environment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);

      await _pumpSyncPlanView(
        tester,
        controller,
        startZone: _ControllerStartZone.current,
      );
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await tester.pump();

      // Vanish the source between preview and run — rail 7 flips the
      // item failed rather than copying stale bytes.
      source.deleteSync();
      await controller.run();
      await tester.pump();
      final item = controller.lastRun!.plan.items.firstWhere(
        (i) => i.relativePath == 'a.txt',
      );
      expect(
        item.status,
        isIn([SyncItemStatus.failed, SyncItemStatus.conflicted]),
      );
      if (item.status != SyncItemStatus.failed) return;

      expect(find.text('Retry Failed'), findsOneWidget);
      await capturePlan(tester, 'sync-plan-retry-failed', inRunAsync: true);

      source.writeAsStringSync('x');
      await tester.tap(find.text('Retry Failed'));
      await pumpUntil(() => item.status == SyncItemStatus.done);
      await tester.pump();
      expect(File('${right.path}/a.txt').readAsStringSync(), 'x');
    });
  });

  testWidgets('a refused setTimes flags the side mtime-unreliable and surfaces '
      'the size-only notice', (tester) async {
    await tester.runAsync(() async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final left = Directory('${scratch.path}/left')..createSync();
      final right = Directory('${scratch.path}/right')..createSync();
      File('${left.path}/a.txt').writeAsStringSync('payload');
      final refusing = _SetTimesRefusingFs();
      final controller = SyncPlanController(
        pair: testSyncPair(left: left.path, right: right.path),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => refusing,
        ),
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);

      await _pumpSyncPlanView(
        tester,
        controller,
        startZone: _ControllerStartZone.current,
      );
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await tester.pump();

      // Before the run both sides are trusted — no notice.
      expect(find.textContaining('comparing by size only'), findsNothing);

      await controller.run();
      await pumpUntil(() => controller.phase == SyncPlanPhase.completed);
      await tester.pump();

      // The refused stamp completed the item, flagged the
      // destination side, and the header now warns (05 §4).
      expect(File('${right.path}/a.txt').existsSync(), isTrue);
      expect(controller.pairState.mtimeUnreliableRight, isTrue);
      expect(controller.pairState.mtimeUnreliableLeft, isFalse);
      expect(find.textContaining('comparing by size only'), findsOneWidget);
      await capturePlan(tester, 'sync-plan-sizeonly-notice', inRunAsync: true);

      // §4's automatic fallback: the flagged pair's next plan
      // compares size-only, so the refused stamp no longer reads
      // as an update — the row converges to equal.
      await controller.rescan();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      final replanned = controller.plan!.items.singleWhere(
        (item) => item.relativePath == 'a.txt',
      );
      expect(replanned.effective, SyncActionType.skip);
      expect(replanned.reason, SyncReason.equal);
    });
  });

  testWidgets('a kind-change row counts its removed files in Deletes and stays '
      'in the filter', (tester) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    // Mirror: one authorized rule-4 replace (file over a 2-file
    // folder) plus one plain delete — §7's chip counts removed
    // files: 1 delete row + 2-file toll = Deletes (3).
    final pair = testSyncPair(
      rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
    );
    final replace = testItem(
      'thing',
      left: testFile(size: 3),
      right: testDir,
      suggested: SyncActionType.updateLeftToRight,
      reason: SyncReason.typeDiffers,
      destinationSubtree: const {
        'thing/a.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
        'thing/b.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
      },
    );
    final plan = testPlan(pair, [
      replace,
      testItem(
        'old.txt',
        right: testFile(),
        suggested: SyncActionType.deleteRight,
        reason: SyncReason.onlyOnRight,
      ),
    ]);
    final controller = fakeController(scratch, pair: pair, plan: plan);
    addTearDown(controller.dispose);
    await pumpSyncPlanView(tester, controller);
    await pumpToReady(tester, controller);

    expect(find.widgetWithText(FilterChip, 'Deletes (3)'), findsOneWidget);
    // The Run button states the full consequence — the replace
    // row's toll lands in its Delete part.
    expect(find.textContaining('Delete 3'), findsOneWidget);

    // Filtering to Deletes keeps the replace row visible — its
    // red removal badge is why the visible rows sum under N.
    await tester.tap(find.widgetWithText(FilterChip, 'Deletes (3)'));
    await tester.pump();
    expect(find.text('thing'), findsOneWidget);
    expect(find.text('old.txt'), findsOneWidget);
  });

  // 05 §2.1's "Copy as rsync Command" — the action-bar surface of
  // `sync.copyRsyncCommand`: clipboard write + the differentiated
  // toast, disabled while nothing exportable exists.
  group('rsync export button', () {
    String? clipboardText;
    Future<void> pumpAndCopy(
      WidgetTester tester,
      SyncPlanController controller,
    ) async {
      // Reset between captures — a copy that never reaches the channel
      // must fail the assert, not pass on a previous test's text.
      clipboardText = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (message) async {
          if (message.method == 'Clipboard.setData') {
            clipboardText = (message.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);
      await tester.tap(find.text('Copy as rsync Command'));
      await tester.pump();
    }

    testWidgets('copies the rendered command and toasts', (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair();
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 3, mtimeSecs: 10),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      addTearDown(controller.dispose);

      await pumpAndCopy(tester, controller);
      expect(clipboardText, isNotNull);
      expect(clipboardText, contains('rsync '));
      expect(clipboardText, contains('rsync -n -i'));
      expect(find.text('Copied rsync command'), findsOneWidget);
    });

    testWidgets('permanent+none toasts the paste-time warning', (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          deletions: DeletionPolicy.permanent,
          backups: BackupPolicy.none,
        ),
      );
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'old.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
        ]),
      );
      addTearDown(controller.dispose);

      await pumpAndCopy(tester, controller);
      expect(
        find.text('Copied rsync command — deletions are permanent when pasted'),
        findsOneWidget,
      );
      expect(find.text('Copied rsync command'), findsNothing);
      expect(clipboardText, contains('--delete-delay'));
    });

    testWidgets('an unresolvable remote side disables the button', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      // A shared-mode serverConfigId with no catalog bound (the
      // harness's default resolver) — the command refuses rather
      // than emitting a wrong host.
      final pair = SyncPair(
        id: 'pair-remote',
        name: 'Remote',
        left: const LocalEndpoint('/left'),
        right: const RemoteEndpoint(
          server: BookmarkServerRef(serverConfigId: 'srv-missing'),
          path: '/srv/path',
        ),
        rules: const SyncRuleSet(),
      );
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 3, mtimeSecs: 10),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      addTearDown(controller.dispose);
      await pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);

      expect(controller.canExportRsync, isFalse);
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Copy as rsync Command'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('an embedded-identity remote side exports its spec', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = SyncPair(
        id: 'pair-remote',
        name: 'Remote',
        left: const LocalEndpoint('/left'),
        right: const RemoteEndpoint(
          server: BookmarkServerRef(
            identity: EmbeddedHostIdentity(
              host: 'example.com',
              port: 2222,
              username: 'deploy',
              authMethod: AuthMethod.agent,
            ),
          ),
          path: '/srv/site',
        ),
        rules: const SyncRuleSet(),
      );
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 3, mtimeSecs: 10),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      addTearDown(controller.dispose);

      await pumpAndCopy(tester, controller);
      expect(clipboardText, contains("'deploy@example.com:/srv/site'"));
      expect(clipboardText, contains('ssh -p 2222'));
    });
  });

  group('sync trash purge', () {
    testWidgets('stale notice uses the view clock and disables deletion', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-trash-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final leftRoot = Directory('${scratch.path}/left')..createSync();
      final rightRoot = Directory('${scratch.path}/right')..createSync();
      final pair = testSyncPair(left: leftRoot.path, right: rightRoot.path);
      final states = MemorySyncStateStore();
      final pairId = syncPairId(
        pair,
        leftCaseInsensitive: false,
        rightCaseInsensitive: false,
      );
      await states.save(
        pairId,
        SyncPairState(
          trashCacheLeft: TrashCacheEntry(
            lastListedAt: DateTime.utc(2026, 10, 8),
            runs: [
              TrashCacheRun(
                runId: '${syncRunDevicePrefix('test-device')}-cached',
                ageBasis: DateTime.utc(2026, 8),
                fileCount: 3,
              ),
            ],
          ),
        ),
      );
      final environment = SyncEnvironment(
        states: states,
        syncRunsDirectory: '${scratch.path}/sync_runs',
        deviceId: () async => 'test-device',
        localFileSystem: _TrashListingFailureFs.new,
      );
      final controller = testController(
        pair: pair,
        scanner: FakeSyncScanner(
          left: testScanResult(leftRoot.path, const {}),
          right: testScanResult(rightRoot.path, const {}),
        ),
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        environment: environment,
      );
      addTearDown(controller.dispose);

      await _pumpSyncPlanView(
        tester,
        controller,
        clock: () => DateTime.utc(2026, 10, 10),
      );
      await pumpToReady(tester, controller);

      expect(
        find.text('As of 2 days ago; reconnect to delete.'),
        findsOneWidget,
      );
      final delete = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Delete…'),
      );
      expect(delete.onPressed, isNull);
    });

    testWidgets('another plan purge disables Run', (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-trash-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final leftRoot = Directory('${scratch.path}/left')..createSync();
      final rightRoot = Directory('${scratch.path}/right')..createSync();
      final pair = testSyncPair(left: leftRoot.path, right: rightRoot.path);
      final activity = SyncTrashActivityRegistry();
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: '${scratch.path}/sync_runs',
        deviceId: () async => 'test-device',
        trashActivity: activity,
      );
      final controller = testController(
        pair: pair,
        scanner: FakeSyncScanner(
          left: testScanResult(leftRoot.path, const {}),
          right: testScanResult(rightRoot.path, const {}),
        ),
        differ: FakeSyncDiffer(
          testPlan(pair, [
            testItem(
              'a.txt',
              left: testFile(),
              suggested: SyncActionType.copyLeftToRight,
              reason: SyncReason.onlyOnLeft,
            ),
          ]),
        ),
        environment: environment,
      );
      addTearDown(controller.dispose);
      await _pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);

      final purge = (await tester.runAsync(() async {
        final location = await environment.resolveTrashLocation(
          endpoint: pair.left,
          canonicalRoot: leftRoot.path,
          rules: pair.rules,
          side: SyncSide.left,
          pathCase: SyncTrashPathCase.sensitive,
        );
        return activity.tryBeginPurge([
          location,
        ], SyncTrashPurgeAdmission.requireIdle);
      }))!;
      addTearDown(purge.close);
      await tester.pump();

      final run = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Copy 1'),
      );
      expect(run.onPressed, isNull);
    });

    testWidgets('aged notice opens the shared scope-and-forfeit dialog', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-trash-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final leftRoot = Directory('${scratch.path}/left')..createSync();
      final rightRoot = Directory('${scratch.path}/right')..createSync();
      final pair = testSyncPair(left: leftRoot.path, right: rightRoot.path);
      final runId =
          '${syncRunDevicePrefix('test-device')}-00000000-0000-4000-'
          '8000-000000000001';
      final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
        ..createSync();
      await tester.runAsync(
        () => resolveSyncTrashRoot(
          LocalFileSystem(),
          trashRoot.path,
          pathStyle: Platform.isWindows
              ? SyncTrashPathStyle.windows
              : SyncTrashPathStyle.posix,
          access: SyncTrashRootAccess.createOrClaim,
        ),
      );
      final runDirectory = Directory('${trashRoot.path}/$runId')..createSync();
      final trashed = File('${runDirectory.path}/000001-a.txt')
        ..writeAsStringSync('old');
      Directory('${scratch.path}/sync_runs').createSync();
      await tester.runAsync(() async {
        final journal = await SyncRunJournal.create(
          '${scratch.path}/sync_runs',
          SyncRunRecord(
            runId: runId,
            pairId: 'another-pair',
            startedAt: DateTime.now().subtract(const Duration(days: 31)),
            rules: const SyncRuleSet(),
            totals: const PlanTotals(
              counts: {},
              bytes: {},
              replacedFiles: 0,
              replacedBytes: 0,
            ),
            warnings: const [],
          ),
        );
        await journal.appendItem(
          SyncJournalItemLine(
            relativePath: 'a.txt',
            side: SyncSide.left,
            action: SyncActionType.deleteLeft,
            outcome: SyncItemStatus.done,
            attempt: 1,
            trashLocation: trashed.path,
            trashBytes: 3,
          ),
        );
      });
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, const []),
      );
      addTearDown(controller.dispose);

      await tester.runAsync(() async {
        controller.start();
        await pumpUntil(() => controller.trashNotices.isNotEmpty);
        await pumpUntil(() => controller.trashNotices.single.canPurge);
      });
      await _pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);
      expect(controller.trashNotices, isNotEmpty);

      expect(
        find.text(
          '1 trashed file from 1 run older than 30 days — delete them?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();

      expect(find.text('Purge sync trash?'), findsOneWidget);
      expect(
        find.text('Sync trash is shared by host and root.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'This includes trash from other sync pairs that use the same host and root.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('These files can no longer be restored.'),
        findsOneWidget,
      );
    });
  });
}
