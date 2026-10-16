import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/access/access_panel.dart';
import 'package:klabautermann_app/ui/jobs_panel.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/logs/logs_panel.dart';
import 'package:klabautermann_app/ui/overview_panel.dart';
import 'package:klabautermann_app/ui/phone_shell.dart';
import 'package:klabautermann_app/ui/processes_panel.dart';
import 'package:klabautermann_app/ui/server_detail_page.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart';
import 'package:klabautermann_app/ui/services_panel.dart';
import 'package:klabautermann_app/ui/services_view.dart' show kUnitLogWindow;
import 'package:klabautermann_app/ui/system_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'access/profiles.dart';
import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _phone = Size(390, 844);

const _background =
    'Reading stops while Klabautermann is in the background and resumes '
    'when you return.';

const _left = 'web-1 is no longer in your fleet, so its screen closed.';

SystemdUnit _unit(String name, String active, String sub, String description) =>
    SystemdUnit(
      unit: name,
      load: 'loaded',
      active: active,
      sub: sub,
      description: description,
    );

final _units = [
  _unit('cron.service', 'active', 'running', 'Regular background jobs'),
  _unit('nginx.service', 'failed', 'failed', 'A high performance web server'),
  _unit('ssh.service', 'active', 'running', 'OpenSSH server'),
];

UnitsResult get _unitsResult => UnitsResult(
  UnitsSnapshot(
    units: _units,
    failed: [
      for (final unit in _units)
        if (unit.active == 'failed') unit,
    ],
    format: UnitListFormat.json,
  ),
);

Sample _unitsSample(int seq, [UnitsResult? result]) => Sample(
  serverId: 'srv-1',
  stream: SampleStream.units,
  seq: seq,
  at: DateTime.utc(2026, 10, 16, 12, 0, seq),
  result: result ?? _unitsResult,
);

JournalRecord _record(String message, LogPriority priority) => JournalRecord(
  message: message,
  priority: priority,
  fields: {
    'MESSAGE': message,
    'PRIORITY': '${priority.index}',
    '_SYSTEMD_UNIT': 'nginx.service',
  },
);

/// nginx's journal, newest first, as a window delivers it.
final _lines = [
  _record('nginx.service: Failed with result exit-code.', LogPriority.warning),
  _record(
    'bind() to 0.0.0.0:80 failed (98: Address in use)',
    LogPriority.error,
  ),
  _record('Starting nginx.service - A web server...', LogPriority.info),
];

const _sampling = SamplingPhase.sampling;

SamplingState _phase(SamplingPhase phase) => SamplingState(
  serverId: 'srv-1',
  phase: phase,
  since: DateTime.utc(2026, 10, 16, 12),
);

Finder _destination(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Finder _moreEntry(String label) => find.widgetWithText(ListTile, label);

/// The panels' subscriptions, without the Overview coverage card's one
/// `units` read (03 §9.5 item 3).
List<Subscribe> _subscribes(FakeEngineClient engine) => [
  for (final request in engine.sentOfType<Subscribe>().cast<Subscribe>())
    if (!request.subscriptionId.startsWith('coverage-')) request,
];

List<OpenLogStream> _opens(FakeEngineClient engine) =>
    engine.sentOfType<OpenLogStream>().cast<OpenLogStream>();

List<String> _closes(FakeEngineClient engine) => [
  for (final close in engine.sentOfType<CloseStream>().cast<CloseStream>())
    close.streamId,
];

/// Pumps the app on a phone and opens web-1 (srv-1).
Future<AppHarness> _openWeb1(WidgetTester tester) async {
  final harness = await pumpApp(tester, size: _phone, servers: twoServers);
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Opens [label] from More.
Future<void> _openMore(WidgetTester tester, String label) async {
  await _tap(tester, _destination('More'));
  await _tap(tester, _moreEntry(label));
}

/// Pulls [finder] down from its top, and lets the indicator arm. A panel
/// whose content fits may have nothing to hit at its centre but the
/// scroll view around it, which is what a pull reaches there.
Future<void> _pull(WidgetTester tester, Finder finder) async {
  await tester.fling(finder, const Offset(0, 300), 1000, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// Opens nginx's page on the Services panel More opened, with units
/// listed.
Future<void> _openNginx(WidgetTester tester, AppHarness harness) async {
  await _openMore(tester, 'Services');
  harness.engine.emit(_unitsSample(1));
  await tester.pumpAndSettle();
  await _tap(tester, find.byKey(const ValueKey('units.row.nginx.service')));
}

/// Answers the unit sheet's read with its window of lines.
Future<void> _readLines(WidgetTester tester, FakeEngineClient engine) async {
  final id = _opens(engine).last.streamId;
  engine
    ..emit(LogStreamState(id, const LogStreamRunning()))
    ..emit(LogBatch(streamId: id, records: _lines));
  await tester.pumpAndSettle();
}

/// 03 §10.5 and plan K40: the phone's server screen lists the other panels
/// under More and opens each full-screen, opens a unit's log lines in a
/// sheet, pulls to refresh, says that reading stops in the background, and
/// closes when its server leaves the fleet.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  group('More', () {
    testWidgets('lists the other panels in the desktop strip\'s order and '
        'samples nothing itself', (tester) async {
      final harness = await _openWeb1(tester);
      final overview = _subscribes(harness.engine).single;

      await _tap(tester, _destination('More'));
      final titles = [
        for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
          (tile.title! as Text).data,
      ];
      expect(titles, ['Processes', 'Services', 'Jobs', 'System', 'Access']);
      expect(
        harness.monitoring.isSubscribed('srv-1', overview.subscriptionId),
        isFalse,
      );
      expect(_subscribes(harness.engine), hasLength(1));
    });

    for (final (label, type) in [
      ('Processes', ProcessesPanel),
      ('Services', ServicesPanel),
      ('Jobs', JobsPanel),
      ('System', SystemPanel),
    ]) {
      testWidgets('opens $label full-screen, sampling it while it shows', (
        tester,
      ) async {
        final harness = await _openWeb1(tester);
        await _openMore(tester, label);

        expect(find.text('$label on web-1'), findsOneWidget);
        expect(find.byType(type), findsOneWidget);
        final panel = ServerPanel.values.byName(label.toLowerCase());
        final subscribe = _subscribes(harness.engine).last;
        expect(subscribe.streams, panel.streams);
        expect(
          harness.monitoring.isSubscribed('srv-1', subscribe.subscriptionId),
          isTrue,
        );

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(type), findsNothing);
        expect(
          harness.monitoring.isSubscribed('srv-1', subscribe.subscriptionId),
          isFalse,
        );
        // Still on the server screen, at More.
        expect(_moreEntry(label), findsOneWidget);
      });
    }

    testWidgets('opens Access full-screen', (tester) async {
      await _openWeb1(tester);
      await _openMore(tester, 'Access');

      expect(find.text('Access on web-1'), findsOneWidget);
      expect(find.byType(AccessPanel), findsOneWidget);
    });

    testWidgets('a panel the probe hides links to Access from its page', (
      tester,
    ) async {
      final harness = await _openWeb1(tester);
      // No systemd, so no units.
      harness.engine.emit(HostProfileChanged('srv-1', alpineContainer()));
      await _openMore(tester, 'Services');
      expect(find.byType(ServicesPanel), findsNothing);

      await _tap(tester, find.text('Open Access'));
      expect(find.text('Access on web-1'), findsOneWidget);
    });
  });

  group('unit logs in a sheet (03 §10.5, PLT-02)', () {
    testWidgets('a unit\'s page opens its lines in a sheet, which reads them '
        'while open and closes a running read', (tester) async {
      final harness = await _openWeb1(tester);
      await _openNginx(tester, harness);

      // The page shows the unit's states and reads nothing inline.
      expect(find.text('A high performance web server'), findsOneWidget);
      expect(find.byType(LogView), findsNothing);
      expect(_opens(harness.engine), isEmpty);

      await _tap(tester, find.text('Show recent log lines'));
      final [open] = _opens(harness.engine);
      expect((open.spec.source as JournalLogSource).unit, 'nginx.service');
      expect(open.spec.window, kUnitLogWindow);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Recent log lines'), findsOneWidget);

      await _readLines(tester, harness.engine);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(LogView),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Address in use', findRichText: true),
        findsOneWidget,
      );

      await _tap(tester, find.byTooltip('Close log lines'));
      expect(find.byType(BottomSheet), findsNothing);
      expect(_closes(harness.engine), [open.streamId]);
      // Back on the unit's page.
      expect(find.text('Show recent log lines'), findsOneWidget);
    });

    testWidgets('a finished read has nothing to close, and the next opening '
        'reads afresh', (tester) async {
      final harness = await _openWeb1(tester);
      await _openNginx(tester, harness);
      await _tap(tester, find.text('Show recent log lines'));
      await _readLines(tester, harness.engine);
      final first = _opens(harness.engine).single.streamId;
      harness.engine.emit(
        LogStreamState(
          first,
          const LogStreamEnded(LogStreamEndReason.windowFilled),
        ),
      );
      await tester.pumpAndSettle();

      // Dragged down past its least height, the sheet closes.
      await tester.fling(
        find.text('Recent log lines'),
        const Offset(0, 800),
        2000,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(_closes(harness.engine), isEmpty);

      await _tap(tester, find.text('Show recent log lines'));
      expect(_opens(harness.engine), hasLength(2));
    });

    testWidgets('the desktop keeps the lines on the unit\'s page', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        size: const Size(1280, 900),
        servers: twoServers,
      );
      await _tap(tester, find.text('web-1'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(TabBar),
          matching: find.text('Services'),
        ),
      );
      harness.engine.emit(_unitsSample(1));
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('units.row.nginx.service')));

      expect(_opens(harness.engine), hasLength(1));
      expect(find.text('Show recent log lines'), findsNothing);
      expect(find.text('Recent log lines'), findsOneWidget);
    });
  });

  group('pull to refresh (PLT-02)', () {
    testWidgets('a pushed panel has the engine read its streams at once, '
        'and the indicator waits for the readings', (tester) async {
      final harness = await _openWeb1(tester);
      await _openMore(tester, 'Services');
      final subscribe = _subscribes(harness.engine).last;
      harness.engine
        ..emit(_phase(_sampling))
        ..emit(_unitsSample(1));
      await tester.pumpAndSettle();

      await _pull(tester, find.byType(ServicesPanel));
      final refresh =
          harness.engine.sentOfType<RefreshSubscription>().single
              as RefreshSubscription;
      expect(
        (refresh.serverId, refresh.subscriptionId),
        ('srv-1', subscribe.subscriptionId),
      );
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      harness.engine.emit(_unitsSample(2));
      await tester.pumpAndSettle();
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    });

    testWidgets('a pull on a list that scrolls refreshes from its top', (
      tester,
    ) async {
      final harness = await _openWeb1(tester);
      await _openMore(tester, 'Services');
      final many = [
        for (var i = 0; i < 40; i++)
          _unit('app-$i.service', 'active', 'running', 'App $i'),
      ];
      harness.engine.emit(
        _unitsSample(
          1,
          UnitsResult(
            UnitsSnapshot(
              units: many,
              failed: const [],
              format: UnitListFormat.json,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scrolled down, the list scrolls back up rather than refreshing.
      await tester.drag(find.text('app-3.service'), const Offset(0, -400));
      await tester.pumpAndSettle();
      await _pull(tester, find.text('app-12.service'));
      await tester.pumpAndSettle();
      expect(harness.engine.sentOfType<RefreshSubscription>(), isEmpty);
      expect(find.text('app-0.service'), findsOneWidget);

      await _pull(tester, find.text('app-3.service'));
      expect(harness.engine.sentOfType<RefreshSubscription>(), hasLength(1));
    });

    testWidgets('with nothing sampling, as with links off, the indicator '
        'ends at once', (tester) async {
      final harness = await _openWeb1(tester);
      await _openMore(tester, 'Jobs');

      await _pull(tester, find.byType(JobsPanel));
      expect(harness.engine.sentOfType<RefreshSubscription>(), hasLength(1));
      await tester.pumpAndSettle();
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    });

    testWidgets('the Overview refreshes, the Logs destination does not', (
      tester,
    ) async {
      final harness = await _openWeb1(tester);
      final overview = _subscribes(harness.engine).single;

      await _pull(tester, find.byType(OverviewPanel));
      await tester.pumpAndSettle();
      final refresh =
          harness.engine.sentOfType<RefreshSubscription>().single
              as RefreshSubscription;
      expect(refresh.subscriptionId, overview.subscriptionId);

      await _tap(tester, _destination('Logs'));
      expect(
        find.ancestor(
          of: find.byType(LogsPanel),
          matching: find.byType(RefreshIndicator),
        ),
        findsNothing,
      );
    });
  });

  group('the background (PLT-04)', () {
    testWidgets(
      'iOS and Android say that reading stops in the background',
      (tester) async {
        await _openWeb1(tester);
        expect(find.text(_background), findsOneWidget);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets('a desktop window on the phone stack keeps reading, so it '
        'does not say so', (tester) async {
      await _openWeb1(tester);
      expect(find.text(_background), findsNothing);
    }, variant: TargetPlatformVariant.desktop());
  });

  group('a server that leaves the fleet (SYN-08)', () {
    testWidgets('closes its screen and everything opened over it, and the '
        'fleet says why until dismissed', (tester) async {
      final harness = await _openWeb1(tester);
      await _openNginx(tester, harness);
      await _tap(tester, find.text('Show recent log lines'));
      final open = _opens(harness.engine).single;

      harness.engine.emit(
        CatalogReplaced([
          FleetEntry(
            serverId: 'srv-2',
            label: 'db-1',
            host: '10.0.0.4',
            port: kSshDefaultPort,
            origin: FleetEntryOrigin.sshConfig,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ServerDetailPage), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(ServicesPanel), findsNothing);
      expect(find.byType(PhoneShell), findsOneWidget);
      expect(find.text(_left), findsOneWidget);
      expect(_closes(harness.engine), [open.streamId]);
      expect(harness.fleet.selectedServerId, isNull);

      await _tap(tester, find.text('Dismiss'));
      expect(find.text(_left), findsNothing);
    });

    testWidgets('opening another server clears the notice', (tester) async {
      final harness = await _openWeb1(tester);
      harness.engine.emit(
        CatalogReplaced([
          FleetEntry(
            serverId: 'srv-2',
            label: 'db-1',
            host: '10.0.0.4',
            port: kSshDefaultPort,
            origin: FleetEntryOrigin.sshConfig,
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text(_left), findsOneWidget);

      await _tap(tester, find.text('db-1'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(_left), findsNothing);
    });

    testWidgets('another server leaving keeps the screen open', (tester) async {
      final harness = await _openWeb1(tester);
      harness.engine.emit(
        CatalogReplaced([
          FleetEntry(
            serverId: 'srv-1',
            label: 'web-1',
            host: 'web-1.example',
            port: kSshDefaultPort,
            origin: FleetEntryOrigin.sshConfig,
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ServerDetailPage), findsOneWidget);
    });
  });

  group('golden', () {
    /// The server screen alone on a phone, in the brand theme with the
    /// golden font, on Android, where the background line shows.
    Future<FakeEngineClient> pumpScreen(
      WidgetTester tester,
      Brightness brightness,
    ) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final engine = FakeEngineClient();
      final fleet = FleetController(engine, servers: twoServers);
      final monitoring = MonitoringController(engine, linkGrace: Duration.zero);
      addTearDown(() async {
        fleet.dispose();
        monitoring.dispose();
        await engine.close();
      });

      final base = brightness == Brightness.light
          ? GhostTheme.light(
              klabautermannThemeStyle,
              platform: TargetPlatform.android,
            )
          : GhostTheme.dark(
              klabautermannThemeStyle,
              platform: TargetPlatform.android,
            );
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerDetailPage(
            server: twoServers.first,
            fleet: fleet,
            monitoring: monitoring,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return engine;
    }

    for (final brightness in Brightness.values) {
      testWidgets('More, ${brightness.name}', (tester) async {
        await pumpScreen(tester, brightness);
        await _tap(tester, _destination('More'));
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/phone_more_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);

      testWidgets('Services through More, ${brightness.name}', (tester) async {
        final engine = await pumpScreen(tester, brightness);
        await _openMore(tester, 'Services');
        engine.emit(_unitsSample(1));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/phone_services_page_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);

      testWidgets('unit log sheet, ${brightness.name}', (tester) async {
        final engine = await pumpScreen(tester, brightness);
        await _openMore(tester, 'Services');
        engine.emit(_unitsSample(1));
        await tester.pumpAndSettle();
        await _tap(
          tester,
          find.byKey(const ValueKey('units.row.nginx.service')),
        );
        await _tap(tester, find.text('Show recent log lines'));
        await _readLines(tester, engine);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/phone_log_sheet_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
