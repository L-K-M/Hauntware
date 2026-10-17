import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/fleet_rows.dart';
import 'package:klabautermann_app/ui/sidebar_kit.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';
import 'support/link_failures.dart';

final _t0 = DateTime.utc(2026, 10, 15, 12);
const _gibibyte = 1024 * 1024 * 1024;
const _sceneKey = ValueKey('fleet-rows');

/// A column wide enough for the bar beside a connected row in the test
/// font, whose glyphs are 1 em wide; the 260 px rail fits it in the
/// goldens' Roboto.
const _barColumn = Size(420, 480);

/// The controllers a row test drives, with the clock it reads.
final class _Rows {
  _Rows(this.engine, this.fleet, this.monitoring);

  final FakeEngineClient engine;
  final FleetController fleet;
  final MonitoringController monitoring;
  final List<String> opened = [];
  DateTime now = _t0;

  var _seq = 0;

  /// Lets the engine's broadcast events reach both controllers, then
  /// draws the frame they scheduled.
  Future<void> emit(WidgetTester tester, Iterable<EngineEvent> events) async {
    events.forEach(engine.emit);
    await tester.pump();
    await tester.pump();
  }

  Sample sample(String serverId, SampleStream stream, SampleResult result) =>
      Sample(
        serverId: serverId,
        stream: stream,
        seq: ++_seq,
        at: now,
        result: result,
      );
}

/// The rail's list in a 260 px column (03 §10.2) on the Linux brand theme,
/// over controllers whose clock reads [_Rows.now]; [layout], [density]
/// and [platform] pick the kit's other row geometries.
Future<_Rows> _pump(
  WidgetTester tester, {
  List<FleetServer> servers = twoServers,
  Brightness brightness = Brightness.light,
  String? fontFamily,
  Size size = const Size(260, 480),
  bool collapsed = false,
  SidebarKitLayout layout = SidebarKitLayout.rail,
  SidebarKitDensity density = SidebarKitDensity.comfortable,
  TargetPlatform? platform,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  late final _Rows rows;
  rows = _Rows(
    engine,
    FleetController(engine, servers: servers),
    MonitoringController(engine, linkGrace: Duration.zero, now: () => rows.now),
  );
  addTearDown(() async {
    rows.fleet.dispose();
    rows.monitoring.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: chartTheme(
        brightness,
        fontFamily: fontFamily,
      ).copyWith(platform: platform),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Material(
        child: Builder(
          builder: (context) => SidebarKitScope(
            strings: klabautermannSidebarStrings(AppLocalizations.of(context)),
            layout: layout,
            density: density,
            child: RepaintBoundary(
              key: _sceneKey,
              child: ColoredBox(
                color: SidebarThemeTokens.of(context).sidebarBackground,
                child: FleetServerList(
                  fleet: rows.fleet,
                  monitoring: rows.monitoring,
                  collapsed: collapsed,
                  showSelection: true,
                  onOpen: (server) {
                    rows.opened.add(server.id);
                    rows.fleet.select(server.id);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rows;
}

/// The kit row of the server [id], found by the row's key: a title the
/// test font cannot fit is middle-ellipsized.
SidebarRow _row(WidgetTester tester, String id) => tester.widget<SidebarRow>(
  find.descendant(
    of: find.byKey(ValueKey(id)),
    matching: find.byType(SidebarRow),
  ),
);

/// The age beside the row of the server [id], or null without one;
/// [skipOffstage] false finds it under a pushed route too.
String? _age(WidgetTester tester, String id, {bool skipOffstage = true}) {
  final ages = find.descendant(
    of: find.byKey(ValueKey(id), skipOffstage: skipOffstage),
    matching: find.byKey(kFleetRowAgeKey, skipOffstage: skipOffstage),
    skipOffstage: skipOffstage,
  );
  return ages.evaluate().isEmpty ? null : tester.widget<Text>(ages).data;
}

CoreResult _core({double? cpu, int? usedGiB, int totalGiB = 8}) => CoreResult(
  cpu: cpu == null ? null : CpuPercentages(const [], cpu),
  memory: MemoryUsage(
    usedBytes: usedGiB == null ? null : usedGiB * _gibibyte,
    totalBytes: totalGiB * _gibibyte,
  ),
);

FsResult _fs(int rootPercent) => FsResult(
  FsSnapshot([
    FsMount(
      device: '/dev/vda1',
      type: 'ext4',
      mountPoint: '/',
      capacityPercent: rootPercent,
    ),
  ]),
);

void main() {
  group('state (FL-04, A11Y-01)', () {
    testWidgets('the probe speaks in a word, an icon and a ring', (
      tester,
    ) async {
      final rows = await _pump(tester);
      expect(find.text('web-1.example'), findsOneWidget);

      await rows.emit(tester, const [
        Reachability('srv-1', ReachabilityStatus.online),
        Reachability('srv-2', ReachabilityStatus.offline),
      ]);

      expect(find.text('Online · web-1.example'), findsOneWidget);
      expect(_row(tester, 'srv-1').trailingIcon, Icons.cloud_done_outlined);
      expect(_row(tester, 'srv-1').status?.style, SidebarDotStyle.ring);
      expect(find.text('Offline · 10.0.0.4'), findsOneWidget);
      expect(_row(tester, 'srv-2').trailingIcon, Icons.cloud_off_outlined);
      expect(
        find.bySemanticsLabel('db-1, 10.0.0.4, Server status: Offline'),
        findsOneWidget,
      );
    });

    testWidgets('a live link outranks the probe and frames the mark', (
      tester,
    ) async {
      final rows = await _pump(tester);
      await rows.emit(tester, const [
        Reachability('srv-1', ReachabilityStatus.unknown),
        LinkState('srv-1', LinkReady()),
      ]);

      final row = _row(tester, 'srv-1');
      expect(find.text('Connected · web-1.example'), findsOneWidget);
      expect(row.trailingIcon, Icons.link);
      expect(row.status?.style, SidebarDotStyle.solid);
      expect(row.markRing, isNotNull);

      await rows.emit(tester, const [
        LinkState(
          'srv-1',
          LinkNeedsUser(promptId: 'p-1', kind: PromptKind.credential),
        ),
      ]);
      expect(find.text('Needs your input · web-1.example'), findsOneWidget);
      expect(_row(tester, 'srv-1').trailingIcon, Icons.block);
      expect(_row(tester, 'srv-1').status?.style, SidebarDotStyle.blocked);
      expect(_row(tester, 'srv-1').markRing, isNull);
    });
  });

  group('a failed link (03 §5.3, §10.1)', () {
    for (final MapEntry(key: failure, value: text) in failureTexts.entries) {
      testWidgets('${failure.name} says why in the tooltip and the label', (
        tester,
      ) async {
        final rows = await _pump(tester);
        await rows.emit(tester, [
          LinkState(
            'srv-1',
            LinkClosed(LinkClosedReason.connectFailed, failure: failure),
          ),
        ]);

        // The row keeps its one line of state.
        expect(find.text('Failed · web-1.example'), findsOneWidget);
        expect(_row(tester, 'srv-1').tooltip, contains(text));
        expect(
          find.bySemanticsLabel(
            'web-1, web-1.example, Server status: Failed, $text',
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('an unclassified one names no reason', (tester) async {
      final rows = await _pump(tester);
      await rows.emit(tester, const [
        LinkState('srv-1', LinkClosed(LinkClosedReason.connectFailed)),
      ]);

      expect(_row(tester, 'srv-1').tooltip, 'web-1.example\nFailed');
    });
  });

  group('filter (FL-05)', () {
    const servers = [
      FleetServer(
        id: 'ssh-config:web-1',
        displayName: 'web-1',
        address: 'web-1.example',
        searchText: 'web-1 deploy@web-1.example:22 production',
      ),
      FleetServer(id: 'srv-2', displayName: 'db-1', address: '10.0.0.4'),
    ];

    testWidgets('narrows the rows, counts them and opens the first on Enter', (
      tester,
    ) async {
      final rows = await _pump(tester, servers: servers);

      await tester.enterText(find.byType(TextField), 'deploy prod');
      await tester.pump();
      expect(find.text('db-1'), findsNothing);
      expect(find.text('web-1'), findsOneWidget);
      expect(find.text('1 of 2 · Enter opens the first'), findsOneWidget);

      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(rows.opened, ['ssh-config:web-1']);
    });

    testWidgets('says when nothing matches and clears from there or on Esc', (
      tester,
    ) async {
      await _pump(tester, servers: servers);

      await tester.enterText(find.byType(TextField), 'mail');
      await tester.pump();
      expect(find.text('No servers match'), findsOneWidget);
      expect(find.text('0 of 2'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Clear filter'));
      await tester.pump();
      expect(find.text('web-1'), findsOneWidget);
      expect(find.text('db-1'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'db');
      await tester.pump();
      expect(find.text('web-1'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('web-1'), findsOneWidget);
    });

    testWidgets('a query shows its matches in a collapsed section', (
      tester,
    ) async {
      await _pump(tester, servers: servers, collapsed: true);
      expect(find.byType(FleetServerRow), findsNothing);

      await tester.enterText(find.byType(TextField), 'db');
      await tester.pump();
      expect(find.text('db-1'), findsOneWidget);
      expect(find.text('web-1'), findsNothing);
    });
  });

  group('pressure bar and freshness (FL-07, 03 §9.5 item 4)', () {
    testWidgets('only a server with a reading shows the bar, and its age '
        'counts on', (tester) async {
      final rows = await _pump(tester, size: _barColumn);
      expect(find.byType(PressureBar), findsNothing);

      await rows.emit(tester, [
        const LinkState('srv-1', LinkReady()),
        rows.sample('srv-1', SampleStream.core, _core(cpu: 12, usedGiB: 2)),
        rows.sample('srv-1', SampleStream.fs, _fs(41)),
      ]);

      final bar = tester.widget<PressureBar>(find.byType(PressureBar));
      expect([for (final cell in bar.cells) cell.percent], [12, 25, 41]);
      expect(bar.stale, isFalse);
      expect(find.text('Connected · web-1.example'), findsOneWidget);
      expect(_age(tester, 'srv-1'), '0 s');
      expect(
        find.bySemanticsLabel(
          'web-1, web-1.example, Server status: Connected, Updated 0 s ago, '
          '${pressureSummary(bar.cells, testChartStrings)}',
        ),
        findsOneWidget,
        reason: 'one node per row, the bar folded into it',
      );

      rows.now = _t0.add(const Duration(seconds: 5));
      await tester.pump(kFreshnessTick);
      expect(_age(tester, 'srv-1'), '5 s');
      expect(_row(tester, 'srv-1').tooltip, contains('Updated 5 s ago'));

      // A lost link greys the last values at once (03 §5.3); its word
      // says why, and the age beside the stale icon how old they are.
      await rows.emit(tester, const [
        LinkState('srv-1', LinkClosed(LinkClosedReason.pingTimeout)),
      ]);
      expect(tester.widget<PressureBar>(find.byType(PressureBar)).stale, true);
      expect(find.text('Connection lost · web-1.example'), findsOneWidget);
      expect(_age(tester, 'srv-1'), '5 s');
      expect(find.byIcon(Icons.history), findsOneWidget);
      expect(_row(tester, 'srv-1').tooltip, contains('Updated 5 s ago'));
    });

    testWidgets('stale values say so in an icon and words, whatever the '
        'link says (03 §9.5 item 4, A11Y-01)', (tester) async {
      final rows = await _pump(tester, size: _barColumn);
      Finder staleIcon() => find.descendant(
        of: find.byKey(const ValueKey('srv-1')),
        matching: find.byIcon(Icons.history),
      );
      await rows.emit(tester, [
        const LinkState('srv-1', LinkReady()),
        const Reachability('srv-1', ReachabilityStatus.online),
        rows.sample('srv-1', SampleStream.core, _core(cpu: 12)),
      ]);
      expect(_age(tester, 'srv-1'), '0 s');
      expect(staleIcon(), findsNothing);

      // Past core's 20 s with the link still up.
      rows.now = _t0.add(const Duration(seconds: 25));
      await tester.pump(kFreshnessTick);
      expect(tester.widget<PressureBar>(find.byType(PressureBar)).stale, true);
      expect(_age(tester, 'srv-1'), 'Stale · 25 s');
      expect(staleIcon(), findsOneWidget);

      // A clean close lets the probe's word speak, which says nothing of
      // the values, so the age still does.
      rows.now = _t0.add(const Duration(seconds: 40));
      await rows.emit(tester, const [
        LinkState('srv-1', LinkClosed(LinkClosedReason.closedByOwner)),
      ]);
      expect(find.text('Online · web-1.example'), findsOneWidget);
      expect(_age(tester, 'srv-1'), 'Stale · 40 s');
      expect(staleIcon(), findsOneWidget);
    });

    testWidgets('a row under a pushed screen stops counting until it shows '
        'again', (tester) async {
      final rows = await _pump(tester, size: _barColumn);
      await rows.emit(tester, [
        const LinkState('srv-1', LinkReady()),
        rows.sample('srv-1', SampleStream.core, _core(cpu: 12)),
      ]);
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
      );
      await tester.pumpAndSettle();
      expect(_age(tester, 'srv-1'), isNull, reason: 'offstage');

      rows.now = _t0.add(const Duration(seconds: 7));
      await tester.pump(kFreshnessTick);
      expect(_age(tester, 'srv-1', skipOffstage: false), '0 s');

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(_age(tester, 'srv-1'), '7 s');
    });
  });

  group('keyboard and screen reader (03 §10.10)', () {
    testWidgets('a focused row keeps its focus when its first reading '
        'lands', (tester) async {
      final rows = await _pump(tester, size: _barColumn);
      await tester.tap(find.text('web-1'));
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(
        focused?.context?.findAncestorWidgetOfExactType<SidebarRow>()?.title,
        'web-1',
      );

      await rows.emit(tester, [
        const LinkState('srv-1', LinkReady()),
        rows.sample('srv-1', SampleStream.core, _core(cpu: 12)),
      ]);
      expect(find.byType(PressureBar), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(focused));
    });

    testWidgets('a monitored row is one named stop, its bar folded into '
        'it', (tester) async {
      final rows = await _pump(tester, size: _barColumn);
      await rows.emit(tester, [
        const LinkState('srv-1', LinkReady()),
        rows.sample('srv-1', SampleStream.core, _core(cpu: 12)),
      ]);

      final tappable = [
        for (final node
            in find.semantics.byAction(SemanticsAction.tap).evaluate())
          node.label,
      ];
      expect(tappable, [
        isNotEmpty,
        startsWith('web-1, '),
        startsWith('db-1, '),
      ], reason: 'the filter field, then one node per row');
      final bar = tester.widget<PressureBar>(find.byType(PressureBar));
      expect(
        find.bySemanticsLabel(pressureSummary(bar.cells, testChartStrings)),
        findsNothing,
        reason: 'the summary is said only inside the row\'s label',
      );
    });

    testWidgets('a tap on the locator warning shows what it means', (
      tester,
    ) async {
      final rows = await _pump(
        tester,
        servers: const [
          FleetServer(
            id: 'srv-1',
            displayName: 'web-1',
            address: '10.0.0.4',
            locatorConflict: ['srv-2'],
          ),
          FleetServer(id: 'srv-2', displayName: 'db-1', address: '10.0.0.4'),
        ],
      );

      await tester.tap(find.byIcon(Icons.warning_amber_rounded));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text(
          'Host key conflict with db-1: they reach the same address '
          'through a different jump route.',
        ),
        findsOneWidget,
      );
      expect(rows.opened, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('without announcements, link changes go to a live region '
        '(A11Y-15)', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final rows = await _pump(tester);

      await rows.emit(tester, const [LinkState('srv-1', LinkConnecting())]);
      expect(tester.takeAnnouncements(), isEmpty);
      expect(
        tester.getSemantics(find.bySemanticsLabel('web-1: Connecting')),
        isSemantics(label: 'web-1: Connecting', isLiveRegion: true),
      );
      expect(
        find.bySemanticsLabel(RegExp('^web-1, ')),
        findsOneWidget,
        reason: 'the rows stay nodes of their own',
      );
    });
  });

  testWidgets('the locator warning shows on the row with the other '
      'server\'s name (03 §4.6)', (tester) async {
    await _pump(
      tester,
      servers: const [
        FleetServer(
          id: 'srv-1',
          displayName: 'web-1',
          address: '10.0.0.4',
          locatorConflict: ['srv-2'],
        ),
        FleetServer(
          id: 'srv-2',
          displayName: 'db-1',
          address: '10.0.0.4',
          locatorConflict: ['srv-1'],
        ),
      ],
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsNWidgets(2));
    const warning =
        'Host key conflict with db-1: they reach the same address '
        'through a different jump route.';
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(warning))), findsOne);
    expect(_row(tester, 'srv-1').tooltip, contains(warning));
  });

  testWidgets('the screen reader hears link changes, not samples or probe '
      'answers (A11Y-15)', (tester) async {
    final rows = await _pump(tester);
    List<String> heard() => [
      for (final announcement in tester.takeAnnouncements())
        announcement.message,
    ];

    await rows.emit(tester, const [LinkState('srv-1', LinkConnecting())]);
    expect(heard(), ['web-1: Connecting']);

    // The same shared state worded otherwise is no news.
    await rows.emit(tester, const [LinkState('srv-1', LinkAuthenticating())]);
    expect(heard(), isEmpty);

    await rows.emit(tester, [
      const LinkState('srv-1', LinkReady()),
      const Reachability('srv-2', ReachabilityStatus.offline),
      rows.sample('srv-1', SampleStream.core, _core(cpu: 3)),
    ]);
    expect(heard(), ['web-1: Connected']);

    rows.now = _t0.add(const Duration(seconds: 3));
    await tester.pump(kFreshnessTick);
    await rows.emit(tester, [
      rows.sample('srv-1', SampleStream.core, _core(cpu: 4)),
    ]);
    expect(heard(), isEmpty);

    // States the shared dot draws alike still read differently.
    await rows.emit(tester, const [
      LinkState('srv-1', LinkDegraded(LinkDegradedReason.sessionLimitLearned)),
    ]);
    expect(heard(), ['web-1: Connected with limits']);
    await rows.emit(tester, const [
      LinkState(
        'srv-1',
        LinkNeedsUser(promptId: 'p-1', kind: PromptKind.credential),
      ),
    ]);
    expect(heard(), ['web-1: Needs your input']);
    await rows.emit(tester, const [
      LinkState('srv-1', LinkBlocked(LinkBlockedReason.hostKeyChanged)),
    ]);
    expect(heard(), ['web-1: Blocked']);

    // A retry loop's waits and dials are one attempt in flight.
    await rows.emit(tester, [
      LinkState('srv-1', LinkBackoff(_t0.add(const Duration(seconds: 9)))),
    ]);
    expect(heard(), ['web-1: Waiting to reconnect']);
    await rows.emit(tester, const [LinkState('srv-1', LinkConnecting())]);
    expect(heard(), isEmpty);
  });

  group('fixed height (03 §10.3, FL-07)', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('phone rows keep one height whatever they show, at '
          '${scale}x text', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final harness = await pumpApp(
          tester,
          size: const Size(480, 800),
          servers: const [
            FleetServer(id: 'srv-1', displayName: 'web-1', address: 'a'),
            FleetServer(id: 'srv-2', displayName: 'db-1', address: 'b'),
            FleetServer(
              id: 'srv-3',
              displayName: 'cache-1',
              address: 'c',
              locatorConflict: ['srv-2'],
            ),
          ],
        );
        harness.engine
          ..emit(const LinkState('srv-1', LinkReady()))
          ..emit(
            Sample(
              serverId: 'srv-1',
              stream: SampleStream.core,
              seq: 1,
              at: DateTime.now(),
              result: _core(cpu: 97, usedGiB: 7),
            ),
          )
          ..emit(const Reachability('srv-2', ReachabilityStatus.offline));
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(PressureBar), findsOneWidget);
        expect(find.byType(FleetServerRow), findsNWidgets(3));
        final heights = {
          for (final row in tester.widgetList<FleetServerRow>(
            find.byType(FleetServerRow),
          ))
            tester.getSize(find.byWidget(row)).height,
        };
        expect(heights, hasLength(1));
      });
    }

    testWidgets('at 2x text the rail\'s bar and age give way to the name, '
        'the warning stays', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final rows = await _pump(
        tester,
        servers: const [
          FleetServer(
            id: 'srv-1',
            displayName: 'db-1',
            address: '10.0.0.4',
            locatorConflict: ['srv-2'],
          ),
          FleetServer(id: 'srv-2', displayName: 'db-2', address: '10.0.0.4'),
        ],
      );
      await rows.emit(tester, [
        const LinkState('srv-1', LinkReady()),
        rows.sample('srv-1', SampleStream.core, _core(cpu: 85, usedGiB: 1)),
      ]);

      expect(tester.takeException(), isNull);
      expect(find.byType(PressureBar), findsNothing);
      expect(find.byKey(kFleetRowAgeKey), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('db-1'), findsOneWidget, reason: 'not ellipsized');
      final tooltip = _row(tester, 'srv-1').tooltip;
      expect(tooltip, contains('Updated 0 s ago'));
      expect(tooltip, contains('CPU 85%'), reason: 'the bar\'s values too');
    });

    for (final (layout, density, platform) in const [
      (
        SidebarKitLayout.rail,
        SidebarKitDensity.comfortable,
        TargetPlatform.linux,
      ),
      (SidebarKitLayout.rail, SidebarKitDensity.compact, TargetPlatform.linux),
      (
        SidebarKitLayout.rail,
        SidebarKitDensity.comfortable,
        TargetPlatform.android,
      ),
      (
        SidebarKitLayout.rail,
        SidebarKitDensity.compact,
        TargetPlatform.android,
      ),
      (
        SidebarKitLayout.list,
        SidebarKitDensity.comfortable,
        TargetPlatform.android,
      ),
    ]) {
      for (final scale in [1.0, 1.4, 2.0]) {
        testWidgets('the bar and age show only where the name, state word '
            'and age fit in full: ${layout.name}, ${density.name}, '
            '${platform.name}, ${scale}x text', (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          const name = 'prod-web-01';
          // No address, so the second line is the state word alone.
          final rows = await _pump(
            tester,
            servers: const [FleetServer(id: 'srv-1', displayName: name)],
            size: const Size(900, 480),
            layout: layout,
            density: density,
            platform: platform,
          );
          await rows.emit(tester, [
            const LinkState('srv-1', LinkReady()),
            rows.sample('srv-1', SampleStream.core, _core(cpu: 12)),
          ]);
          // Past core's 20 s: the widest age a connected row shows.
          rows.now = _t0.add(const Duration(seconds: 25));
          await tester.pump(kFreshnessTick);
          expect(_age(tester, 'srv-1'), 'Stale · 25 s');

          Future<bool> barAt(double width) async {
            tester.view.physicalSize = Size(width, 480);
            await tester.pump();
            return find.byType(PressureBar).evaluate().isNotEmpty;
          }

          // The narrowest row that shows the bar.
          var (fits, short) = (900.0, 200.0);
          expect(await barAt(fits), isTrue);
          expect(await barAt(short), isFalse);
          while (fits - short > 1) {
            final mid = ((fits + short) / 2).roundToDouble();
            if (await barAt(mid)) {
              fits = mid;
            } else {
              short = mid;
            }
          }
          await barAt(fits);
          expect(tester.takeException(), isNull);

          RenderParagraph paragraph(Finder text) => tester.renderObject(
            find.descendant(of: text, matching: find.byType(RichText)),
          );
          final age = paragraph(find.byKey(kFleetRowAgeKey));
          expect(age.didExceedMaxLines, isFalse, reason: 'the age in full');
          // Found only while not middle-ellipsized.
          final title = paragraph(find.text(name));
          var need = title.getMaxIntrinsicWidth(double.infinity);
          if (density == SidebarKitDensity.comfortable) {
            final word = paragraph(find.text('Connected'));
            expect(word.didExceedMaxLines, isFalse, reason: 'the word in full');
            need = math.max(need, word.getMaxIntrinsicWidth(double.infinity));
          }
          // Rounding aside, the label has no room to spare at that width:
          // the bar does not give way while all of it fits.
          final room = tester
              .renderObject<RenderBox>(
                find
                    .ancestor(
                      of: find.text(name),
                      matching: find.byType(LayoutBuilder),
                    )
                    .first,
              )
              .constraints
              .maxWidth;
          expect(room - need, inInclusiveRange(0, 3));
        });
      }
    }
  });

  group('golden', () {
    setUpAll(() async {
      if (goldensCompareHere) await loadGoldenFonts();
    });

    for (final brightness in Brightness.values) {
      testWidgets('fleet rows in every state, ${brightness.name}', (
        tester,
      ) async {
        final rows = await _pump(
          tester,
          brightness: brightness,
          fontFamily: goldenFontFamily,
          size: const Size(260, 492),
          servers: const [
            FleetServer(id: 'web', displayName: 'web-1', address: 'web-1'),
            FleetServer(id: 'db', displayName: 'db-1', address: '10.0.0.4'),
            FleetServer(id: 'cache', displayName: 'cache-1', address: 'c1'),
            FleetServer(id: 'mail', displayName: 'mail', address: 'm1'),
            FleetServer(id: 'edge', displayName: 'edge', address: 'e1'),
            FleetServer(
              id: 'jump',
              displayName: 'bastion',
              address: '10.0.0.4',
              locatorConflict: ['db'],
            ),
            FleetServer(id: 'new', displayName: 'new-host', address: 'n1'),
            FleetServer(id: 'left', displayName: 'left-1', address: 'l1'),
          ],
        );
        await rows.emit(tester, [
          const LinkState('web', LinkReady()),
          rows.sample('web', SampleStream.core, _core(cpu: 85, usedGiB: 3)),
          rows.sample('web', SampleStream.fs, _fs(93)),
          const LinkState('db', LinkReady()),
          rows.sample('db', SampleStream.core, _core(cpu: 20, usedGiB: 6)),
          const LinkState('left', LinkReady()),
          const Reachability('left', ReachabilityStatus.online),
          rows.sample('left', SampleStream.core, _core(cpu: 40, usedGiB: 4)),
        ]);
        rows.now = _t0.add(const Duration(seconds: 12));
        await rows.emit(tester, [
          const LinkState('db', LinkClosed(LinkClosedReason.linkLost)),
          const LinkState('left', LinkClosed(LinkClosedReason.closedByOwner)),
          const Reachability('cache', ReachabilityStatus.online),
          const Reachability('mail', ReachabilityStatus.offline),
          const Reachability('edge', ReachabilityStatus.unknown),
          const LinkState(
            'jump',
            LinkBlocked(LinkBlockedReason.hostKeyChanged),
          ),
        ]);
        await tester.pump(kFreshnessTick);

        await expectLater(
          find.byKey(_sceneKey),
          matchesGoldenFile('goldens/fleet_rows_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
