import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/services_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _wide = Size(718, 900);
const _phone = Size(390, 844);

SystemdUnit _unit(
  String name,
  String active,
  String sub, [
  String? description,
  String? load = 'loaded',
]) => SystemdUnit(
  unit: name,
  load: load,
  active: active,
  sub: sub,
  description: description,
);

final _units = [
  _unit('cron.service', 'active', 'running', 'Regular jobs'),
  _unit('backup.service', 'failed', 'failed', 'Nightly backup'),
  _unit('nginx.service', 'failed', 'failed', 'A high performance web server'),
  _unit('ssh.service', 'active', 'running', 'OpenSSH server'),
  _unit('ssh.socket', 'active', 'listening', 'OpenSSH socket'),
  _unit('tmp.mount', 'active', 'mounted', 'Temporary Directory'),
];

UnitsResult _result({
  List<SystemdUnit>? units,
  UnitListFormat format = UnitListFormat.json,
}) {
  final all = units ?? _units;
  return UnitsResult(
    UnitsSnapshot(
      units: all,
      failed: [
        for (final unit in all)
          if (unit.active == 'failed') unit,
      ],
      format: format,
    ),
  );
}

final class _Panel {
  _Panel(this.engine);

  final FakeEngineClient engine;
  int _seq = 0;

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  Future<void> sample(WidgetTester tester, [SampleResult? result]) => emit(
    tester,
    Sample(
      serverId: 'srv-1',
      stream: SampleStream.units,
      seq: ++_seq,
      at: DateTime.utc(2026, 10, 15, 12),
      result: result ?? _result(),
    ),
  );
}

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine);
  addTearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  final base = brightness == Brightness.light
      ? GhostTheme.light(klabautermannThemeStyle, platform: platform)
      : GhostTheme.dark(klabautermannThemeStyle, platform: platform);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: RepaintBoundary(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: ServicesPanel(monitoring: monitoring, serverId: 'srv-1'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine);
}

Finder _row(String unit) => find.byKey(ValueKey('units.row.$unit'));

Finder _unknownIn(String unit) =>
    find.descendant(of: _row(unit), matching: find.text('unknown'));

/// The type and state filters' menus.
enum _Menu { type, state }

Future<void> _choose(WidgetTester tester, _Menu menu, String choice) async {
  await tester.tap(
    find.byWidgetPredicate((widget) => widget is DropdownButton).at(menu.index),
  );
  await tester.pumpAndSettle();
  // The open menu's items come after the panel's cells.
  await tester.tap(find.text(choice).last);
  await tester.pumpAndSettle();
}

/// 03 §10.2's Services tab: SVC-01's units and filters, SVC-02's failed
/// units and CN-10's unknown states.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('the desktop Services tab samples units and lists services', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      servers: twoServers,
      size: const Size(1280, 900),
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();

    final subscribe = harness.engine.sentOfType<Subscribe>().last as Subscribe;
    expect(subscribe.streams, {SampleStream.units});
    expect(find.text('Waiting for the first list of units…'), findsOneWidget);

    harness.engine.emit(
      Sample(
        serverId: 'srv-1',
        stream: SampleStream.units,
        seq: 1,
        at: DateTime.utc(2026, 10, 15, 12),
        result: _result(),
      ),
    );
    await tester.pumpAndSettle();
    // Services lead; other types wait behind the type filter.
    expect(_row('ssh.service'), findsOneWidget);
    expect(_row('ssh.socket'), findsNothing);
    expect(find.text('2 failed units'), findsOneWidget);
    expect(find.text('nginx.service: failed'), findsOneWidget);
  });

  testWidgets('filters by type and by active state', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(tester);

    await _choose(tester, _Menu.state, 'failed');
    expect(_row('nginx.service'), findsOneWidget);
    expect(_row('cron.service'), findsNothing);

    await _choose(tester, _Menu.type, 'All types');
    await _choose(tester, _Menu.state, 'active');
    expect(_row('ssh.socket'), findsOneWidget);
    expect(_row('tmp.mount'), findsOneWidget);
    expect(_row('nginx.service'), findsNothing);

    await _choose(tester, _Menu.type, 'socket');
    expect(_row('ssh.socket'), findsOneWidget);
    expect(_row('ssh.service'), findsNothing);

    // A refresh without the chosen value keeps the choice, now empty.
    await panel.sample(tester, _result(units: [_units.first]));
    expect(find.text('No units match these filters.'), findsOneWidget);
  });

  testWidgets('old systemd: says so and shows unreadable states as unknown', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      _result(
        format: UnitListFormat.text,
        units: [
          _unit('cron.service', 'active', 'running'),
          _unit('odd.service', 'sleeping', 'Dead', null, null),
          // A bullet-led row read by position (CN-10), the sub state
          // leading the description as the host's text parser leaves it.
          _unit(
            '●',
            'loaded',
            'failed',
            'failed A web server',
            'nginx.service',
          ),
        ],
      ),
    );

    expect(find.textContaining('older than version 246'), findsOneWidget);
    // Load, active, sub and description.
    expect(_unknownIn('odd.service'), findsNWidgets(4));
    expect(_row('●'), findsNothing);

    await _choose(tester, _Menu.type, 'All types');
    await _choose(tester, _Menu.type, 'unknown');
    expect(_unknownIn('●'), findsNWidgets(4));
    expect(find.text('loaded'), findsNothing);
    expect(find.text('failed A web server'), findsNothing);
  });

  testWidgets('words an unavailable unit list', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      const CollectorUnavailable(
        CollectorUnavailableReason.missing,
        detail: 'systemctl: not found',
      ),
    );

    expect(
      find.text('This server has no systemctl, so there are no units to list.'),
      findsOneWidget,
    );
    expect(find.text('systemctl: not found'), findsOneWidget);
  });

  testWidgets('the keyboard reaches the filters and the table', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(tester);

    // Reading order: the filters, the sortable headers, then the table's
    // body.
    final stops = <String?>[];
    while (stops.length < 12 && stops.lastOrNull != 'SortableTable') {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      stops.add(FocusManager.instance.primaryFocus?.debugLabel);
    }
    expect(stops.where((stop) => stop != null && stop.contains('Dropdown')), [
      contains('UnitType'),
      contains('UnitActiveState'),
    ]);
    expect(stops.last, 'SortableTable');
  });

  testWidgets('a phone keeps the unit and state columns', (tester) async {
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.sample(tester);

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Description'), findsNothing);
    expect(find.text('Load'), findsNothing);
  });

  for (final (name, size, platform) in [
    ('desktop', const Size(1280, 800), TargetPlatform.linux),
    ('phone', _phone, TargetPlatform.android),
  ]) {
    testWidgets('lays out at 200% text on a $name without overflow', (
      tester,
    ) async {
      final panel = await _pump(
        tester,
        size: size,
        textScale: 2,
        platform: platform,
      );
      await panel.sample(tester, _result(format: UnitListFormat.text));

      expect(tester.takeException(), isNull);
      expect(_row('nginx.service'), findsOneWidget);
    });
  }

  group('golden', () {
    // 03 §11.1: the desktop scene lists services with two failed; the
    // phone scene is old systemd's list.
    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, brightness: brightness);
        await panel.sample(tester);
        await expectLater(
          find.byType(ServicesPanel),
          matchesGoldenFile(
            'goldens/services_panel_desktop_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);

      testWidgets('phone, ${brightness.name}', (tester) async {
        final panel = await _pump(
          tester,
          size: _phone,
          brightness: brightness,
          platform: TargetPlatform.android,
        );
        await panel.sample(tester, _result(format: UnitListFormat.text));
        await expectLater(
          find.byType(ServicesPanel),
          matchesGoldenFile(
            'goldens/services_panel_phone_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
