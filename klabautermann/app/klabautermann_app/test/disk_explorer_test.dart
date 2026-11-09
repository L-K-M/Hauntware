// DSK-07's disk space explorer: it reads the mount point when it opens,
// lists entries largest first, drills into folders and back up without
// reading them again, says what it could not read, and in admin mode
// reads as root.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/disk_explorer.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

DiskUsageListing _listing(
  String path,
  Map<String, (int, bool)> entries, {
  bool incomplete = false,
}) => DiskUsageListing(
  path: path,
  totalBytes: entries.values.fold(4096, (sum, entry) => sum + entry.$1),
  entries: [
    for (final MapEntry(key: name, value: (bytes, folder)) in entries.entries)
      DiskUsageEntry(name: name, bytes: bytes, isFolder: folder),
  ],
  truncated: false,
  incomplete: incomplete,
);

void main() {
  late FakeEngineClient engine;
  late MonitoringController monitoring;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
  });

  tearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DiskExplorer(
          monitoring: monitoring,
          serverId: _server,
          root: '/var',
        ),
      ),
    );
    await tester.pump();
  }

  List<ReadDiskUsage> reads() => [
    for (final request in engine.sentOfType<ReadDiskUsage>())
      request as ReadDiskUsage,
  ];

  Future<void> answer(
    WidgetTester tester, {
    DiskUsageListing? listing,
    DiskUsageReportFailure? failure,
  }) async {
    final request = reads().last;
    engine.emit(
      DiskUsageReport(
        serverId: _server,
        requestId: request.requestId,
        path: request.path,
        listing: listing,
        failure: failure,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('reads the mount point, lists entries largest first and '
      'drills in and back up without reading again', (tester) async {
    await pump(tester);
    expect(reads().single.path, '/var');
    expect(reads().single.elevated, isFalse);
    // The mount point, so the engine can answer folders under it from one
    // export where ncdu or gdu is installed (03 §7.3).
    expect(reads().single.root, '/var');
    expect(reads().single.fresh, isFalse);
    expect(find.textContaining('Reading /var'), findsOneWidget);

    await answer(
      tester,
      listing: _listing('/var', {
        'lib': (3 << 30, true),
        'log': (1 << 30, true),
        'tmpfile': (4096, false),
      }),
    );
    final names = [
      for (final name in ['lib', 'log', 'tmpfile'])
        tester.getTopLeft(find.text(name)).dy,
    ];
    expect(names, orderedEquals([...names]..sort()));
    expect(find.textContaining('in this folder'), findsOneWidget);

    await tester.tap(find.text('tmpfile'));
    await tester.pumpAndSettle();
    expect(reads(), hasLength(1), reason: 'a file does not open');

    await tester.tap(find.text('log'));
    await tester.pump();
    expect(reads().last.path, '/var/log');
    await answer(
      tester,
      listing: _listing('/var/log', {'journal': (1 << 29, true)}),
    );
    expect(find.text('journal'), findsOneWidget);

    await tester.tap(find.byTooltip('Up a folder'));
    await tester.pumpAndSettle();
    expect(find.text('lib'), findsOneWidget);
    expect(reads(), hasLength(2), reason: 'a folder read stays');
    expect(find.byTooltip('Up a folder'), findsOneWidget);
  });

  testWidgets('Mac arrows select and open folders and leave an empty folder', (
    tester,
  ) async {
    await pump(tester);
    await answer(
      tester,
      listing: _listing('/var', {
        'log': (8192, true),
        'tmpfile': (4096, false),
      }),
    );
    await tester.tap(find.text('tmpfile'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(reads().last.path, '/var/log');
    await answer(tester, listing: _listing('/var/log', {}));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('tmpfile'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(reads(), hasLength(2), reason: 'cannot leave the mount root');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('boundary and page keys reveal file rows without opening them', (
    tester,
  ) async {
    await pump(tester);
    await answer(
      tester,
      listing: _listing('/var', {
        for (var i = 0; i < 120; i++) 'file$i': (4096 - i, false),
      }),
    );
    await tester.tap(find.text('file0'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(find.text('file119').hitTestable(), findsOneWidget);
    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    final notes = (scroll.slivers.first as SliverToBoxAdapter).child!;
    expect(
      (notes.key! as GlobalKey).currentContext,
      isNotNull,
      reason: 'the single-child notes sliver stays mounted outside the cache',
    );
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .singleWhere((tile) => tile.selected)
          .title,
      isA<Text>().having((text) => text.data, 'name', 'file119'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(find.text('file0').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .singleWhere((tile) => tile.selected)
          .title,
      isA<Text>().having((text) => text.data, 'name', isNot('file0')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(reads(), hasLength(1), reason: 'files remain read-only');
  });

  testWidgets('large text keeps notes and rows scrollable in a small window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, textScale: 2);
    await answer(
      tester,
      listing: _listing('/var', {'log': (8192, true)}, incomplete: true),
    );
    await tester.binding.setSurfaceSize(const Size(360, 320));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomScrollView), findsOneWidget);
  });

  testWidgets('says what it could not read, and reads again on request', (
    tester,
  ) async {
    await pump(tester);
    await answer(
      tester,
      listing: _listing('/var', {'lib': (8192, true)}, incomplete: true),
    );
    expect(find.textContaining('could not be read as the login'), findsOne);
    expect(find.textContaining('Turn on admin mode'), findsOneWidget);

    await tester.tap(find.byTooltip('Read again'));
    await tester.pump();
    expect(reads(), hasLength(2));
    expect(reads().last.fresh, isTrue);
    expect(reads().last.root, '/var');
    await answer(tester, failure: DiskUsageReportFailure.transport);
    expect(find.textContaining('ran past its 3 minutes'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(reads(), hasLength(3));
  });

  test('every failure has words', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    for (final failure in DiskUsageReportFailure.values) {
      expect(diskUsageFailureText(l10n, failure), isNotEmpty);
    }
  });
}
