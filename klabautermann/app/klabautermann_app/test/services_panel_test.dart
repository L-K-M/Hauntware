import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/processes_panel.dart' show kRevealDuration;
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_app/ui/services_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_editor/planchette_editor.dart' show PlanchetteEditor;

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

JournalRecord _record(String message, LogPriority priority) => JournalRecord(
  message: message,
  priority: priority,
  fields: {
    'MESSAGE': message,
    'PRIORITY': '${priority.index}',
    '_SYSTEMD_UNIT': 'nginx.service',
  },
);

/// The journal's newest lines first, as a window delivers them.
final _lines = [
  _record('nginx.service: Failed with result exit-code.', LogPriority.warning),
  _record(
    'bind() to 0.0.0.0:80 failed (98: Address in use)',
    LogPriority.error,
  ),
  _record('Starting nginx.service - A web server...', LogPriority.info),
];

final class _Panel {
  _Panel(this.engine, this.visible, this.serverId);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;
  final ValueNotifier<String> serverId;
  int _seq = 0;

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  Future<void> sample(WidgetTester tester, [SampleResult? result]) => emit(
    tester,
    Sample(
      serverId: serverId.value,
      stream: SampleStream.units,
      seq: ++_seq,
      at: DateTime.utc(2026, 10, 15, 12),
      result: result ?? _result(),
    ),
  );

  List<OpenLogStream> get opens =>
      engine.sentOfType<OpenLogStream>().cast<OpenLogStream>();

  /// The units whose journal the opens read, in order.
  List<String?> get opened => [
    for (final open in opens) (open.spec.source as JournalLogSource).unit,
  ];

  List<String> get closes => [
    for (final close in engine.sentOfType<CloseStream>())
      (close as CloseStream).streamId,
  ];

  /// Answers the latest unit read with [payload].
  Future<void> answerUnit(WidgetTester tester, UnitPayload payload) {
    final query = engine.sentOfType<UnitQuery>().cast<UnitQuery>().last;
    return emit(
      tester,
      UnitQueryResult(
        serverId: query.serverId,
        requestId: query.requestId,
        payload: payload,
      ),
    );
  }

  Future<void> report(WidgetTester tester, LogStreamStatus status) =>
      emit(tester, LogStreamState(opens.last.streamId, status));

  /// The latest read's lines: running, then the window, then its end.
  Future<void> readLines(WidgetTester tester) async {
    await report(tester, const LogStreamRunning());
    await emit(
      tester,
      LogBatch(streamId: opens.last.streamId, records: _lines),
    );
    await report(tester, const LogStreamEnded(LogStreamEndReason.windowFilled));
  }
}

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
  UnitLogPlacement logPlacement = UnitLogPlacement.inline,
  SafetyPolicy? safety,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine);
  final visible = ValueNotifier(true);
  final serverId = ValueNotifier('srv-1');
  addTearDown(() async {
    monitoring.dispose();
    visible.dispose();
    serverId.dispose();
    await engine.close();
  });

  final base = brightness == Brightness.light
      ? GhostTheme.light(klabautermannThemeStyle, platform: platform)
      : GhostTheme.dark(klabautermannThemeStyle, platform: platform);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
  );
  final operations = OperationsController(engine);
  addTearDown(operations.dispose);
  final policy = safety == null
      ? null
      : SafetyController(initial: safety, apply: (_) {});
  if (policy != null) addTearDown(policy.dispose);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Actions show only with safety preferences that allow them.
      builder: (context, child) => policy == null
          ? child!
          : SafetyScope(
              safety: policy,
              child: OperationsScope(operations: operations, child: child!),
            ),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: RepaintBoundary(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: ListenableBuilder(
                listenable: Listenable.merge([visible, serverId]),
                builder: (context, _) => ServicesPanel(
                  monitoring: monitoring,
                  serverId: serverId.value,
                  visible: visible.value,
                  logPlacement: logPlacement,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine, visible, serverId);
}

Finder _row(String unit) => find.byKey(ValueKey('units.row.$unit'));

Finder _line(String text) => find.textContaining(text, findRichText: true);

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

Future<void> _open(WidgetTester tester, String unit) async {
  await tester.tap(_row(unit));
  await tester.pumpAndSettle();
}

/// 03 §10.2's Services tab: SVC-01's units and filters, SVC-02's failed
/// units, SVC-04's unit logs and CN-10's unknown states.
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
    // A bullet-led row read by position (CN-10), the sub state leading
    // the description as the host's text parser leaves it; `systemctl
    // --failed` leads its rows with the bullet.
    final misread = _unit(
      '●',
      'loaded',
      'failed',
      'failed A web server',
      'nginx.service',
    );
    await panel.sample(
      tester,
      UnitsResult(
        UnitsSnapshot(
          units: [
            _unit('cron.service', 'active', 'running'),
            _unit('odd.service', 'sleeping', 'Dead', null, null),
            misread,
          ],
          failed: [misread],
          format: UnitListFormat.text,
        ),
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

    // A misread name is no unit's, so neither its row nor the failed
    // units summary opens a page that would read its journal.
    expect(find.text('●: unknown'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '●: unknown'), findsNothing);
    await _open(tester, '●');
    expect(find.text('Recent log lines'), findsNothing);
    expect(panel.opens, isEmpty);
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

  testWidgets('a failed unit opens its page, which reads 50 journal lines', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester);

    await tester.tap(find.text('nginx.service: failed'));
    await tester.pumpAndSettle();

    final spec = panel.opens.single.spec;
    expect((spec.serverId, spec.window, spec.follow), ('srv-1', 50, false));
    expect((spec.source as JournalLogSource).unit, 'nginx.service');
    expect(find.text('A high performance web server'), findsWidgets);
    expect(
      find.text('Asking the server for recent log lines…'),
      findsOneWidget,
    );

    // The engine refuses the open, as it does for a server outside its
    // fleet.
    await panel.emit(
      tester,
      const RequestRejected('OpenLogStream', 'no fleet server srv-1'),
    );
    expect(
      find.text('Reading unit logs is not available in this version yet.'),
      findsOneWidget,
    );
    expect(_line('Address in use'), findsNothing);
  });

  testWidgets('shows the lines oldest first; reopening reads again', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester);
    await _open(tester, 'nginx.service');

    await panel.report(tester, const LogStreamRunning());
    expect(find.text('Reading recent log lines…'), findsOneWidget);
    await panel.readLines(tester);
    expect(find.text('Reading recent log lines…'), findsNothing);
    final tops = [
      for (final text in ['Starting', 'Address in use', 'Failed with'])
        tester.getTopLeft(_line(text)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));

    await tester.tap(find.byTooltip('Close unit details'));
    await tester.pumpAndSettle();
    await _open(tester, 'nginx.service');
    expect(panel.opens, hasLength(2));
    // The finished read had nothing left to stop.
    expect(panel.closes, isEmpty);
    await panel.report(
      tester,
      const LogStreamEnded(
        LogStreamEndReason.denied,
        detail: 'No journal files were opened due to insufficient permissions.',
      ),
    );
    expect(
      find.text("The server refused to read this unit's journal."),
      findsOneWidget,
    );
    expect(find.textContaining('insufficient permissions'), findsOneWidget);
  });

  testWidgets('a hidden tab stops a running read and reads again when shown', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester);
    await _open(tester, 'nginx.service');
    await panel.report(tester, const LogStreamRunning());

    panel.visible.value = false;
    await tester.pumpAndSettle();
    expect(panel.closes, [panel.opens.single.streamId]);
    panel.visible.value = true;
    await tester.pumpAndSettle();
    expect(panel.opens, hasLength(2));

    // A finished read stays across a tab switch.
    await panel.readLines(tester);
    panel.visible.value = false;
    await tester.pumpAndSettle();
    panel.visible.value = true;
    await tester.pumpAndSettle();
    expect(panel.opens, hasLength(2));
    expect(_line('Address in use'), findsOneWidget);
  });

  testWidgets('closing the page or switching servers stops its read', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester);
    await _open(tester, 'nginx.service');
    await panel.report(tester, const LogStreamRunning());

    await tester.tap(find.byTooltip('Close unit details'));
    await tester.pumpAndSettle();
    expect(panel.closes, [panel.opens.last.streamId]);
    expect(find.text('Recent log lines'), findsNothing);

    await _open(tester, 'cron.service');
    panel.serverId.value = 'srv-2';
    await tester.pumpAndSettle();
    expect(panel.closes, hasLength(2));
    expect(find.text('Recent log lines'), findsNothing);
  });

  testWidgets('the keyboard reaches the filters, the table and the page', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester);

    // Reading order: the failed units, the filters, the sortable headers,
    // then the table's body.
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

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(panel.opens, hasLength(1));
    // Opening the page leaves the table focused, and the page's close
    // button comes next.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SortableTable');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Recent log lines'), findsNothing);
  });

  testWidgets('a phone shows the page in place of the list, and Back closes', (
    tester,
  ) async {
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.sample(tester);
    expect(find.text('Description'), findsNothing);
    expect(find.text('Load'), findsNothing);

    await _open(tester, 'nginx.service');
    expect(_row('cron.service'), findsNothing);
    expect(find.text('Recent log lines'), findsOneWidget);
    await tester.tap(find.byTooltip('Close unit details'));
    await tester.pumpAndSettle();
    expect(_row('cron.service'), findsOneWidget);

    await _open(tester, 'nginx.service');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_row('cron.service'), findsOneWidget);
    expect(panel.closes, hasLength(2));
  });

  testWidgets('a page keeps its read across the wide and narrow layouts', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester);
    await _open(tester, 'nginx.service');
    await panel.report(tester, const LogStreamRunning());

    // The panel crosses the 600 px width that moves the page in place.
    tester.view.physicalSize = _phone;
    await tester.pumpAndSettle();
    expect(_row('cron.service'), findsNothing);
    expect(panel.opens, hasLength(1));
    expect(panel.closes, isEmpty);

    await panel.readLines(tester);
    tester.view.physicalSize = _wide;
    await tester.pumpAndSettle();
    expect(_row('cron.service'), findsOneWidget);
    expect(panel.opens, hasLength(1));
    expect(_line('Address in use'), findsOneWidget);
  });

  testWidgets('a narrow page takes focus off the hidden table and returns it', (
    tester,
  ) async {
    // A narrow desktop panel: a click focuses the table behind the page.
    final panel = await _pump(tester, size: const Size(560, 800));
    await panel.sample(tester);
    await _open(tester, 'cron.service');
    expect(_row('backup.service'), findsNothing);

    // The keys stay on the page, never reaching the hidden table: down
    // moves to the page's own controls, and up comes back to its close
    // button.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_row('backup.service'), findsNothing);
    expect(panel.opened, ['cron.service']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(panel.opened, ['cron.service']);
    expect(_row('backup.service'), findsOneWidget);

    // Closing gives the table its focus back.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(panel.opened, ['cron.service', 'backup.service']);
  });

  testWidgets('a desktop panel narrow at 200% text keeps keys on the page', (
    tester,
  ) async {
    final panel = await _pump(
      tester,
      size: const Size(1000, 800),
      textScale: 2,
    );
    await panel.sample(tester);
    // Tab to the table's body, then open its second unit.
    var stops = 0;
    while (stops++ < 12 &&
        FocusManager.instance.primaryFocus?.debugLabel != 'SortableTable') {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_row('cron.service'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_row('cron.service'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(panel.opened, ['backup.service', 'nginx.service']);
  });

  testWidgets('Back on another tab leaves the hidden page open', (
    tester,
  ) async {
    var exits = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.sample(tester);
    await _open(tester, 'nginx.service');

    panel.visible.value = false;
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(exits, 1);

    panel.visible.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Recent log lines'), findsOneWidget);
    expect(_row('cron.service'), findsNothing);
  });

  testWidgets('touch platforms give the filters 48 dp tap targets', (
    tester,
  ) async {
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.sample(tester);

    // androidTapTargetGuideline skips these: they touch the edge of the
    // scrolling header. Each menu's button is its whole tap target.
    for (final menu in _Menu.values) {
      final button = find
          .byWidgetPredicate((widget) => widget is DropdownButton)
          .at(menu.index);
      expect(tester.getSize(button).height, 48, reason: menu.name);
    }
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
      await _open(tester, 'nginx.service');
      await panel.readLines(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Recent log lines'), findsOneWidget);
    });
  }

  for (final textScale in [1.0, 2.0]) {
    testWidgets('on a phone a unit\'s lines open in a sheet, which reads '
        'them while open and closes its read (PLT-02), at '
        '${textScale * 100}% text', (tester) async {
      final panel = await _pump(
        tester,
        size: _phone,
        textScale: textScale,
        platform: TargetPlatform.android,
        logPlacement: UnitLogPlacement.sheet,
      );
      await panel.sample(tester);
      await _open(tester, 'nginx.service');
      expect(panel.opens, isEmpty);
      expect(find.text('Recent log lines'), findsNothing);

      await tester.tap(find.text('Show recent log lines'));
      await tester.pumpAndSettle();
      expect(panel.opened, ['nginx.service']);
      await panel.report(tester, const LogStreamRunning());
      await panel.emit(
        tester,
        LogBatch(streamId: panel.opens.last.streamId, records: _lines),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(LogView),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Close log lines'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(panel.closes, [panel.opens.last.streamId]);
    });
  }

  group('golden', () {
    // 03 §11.1: the desktop scene lists services with two failed and the
    // page of one with its lines; the phone scene is old systemd's list.
    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, brightness: brightness);
        await panel.sample(tester);
        await _open(tester, 'nginx.service');
        await panel.answerUnit(
          tester,
          const UnitResourcesPayload(
            UnitResources(
              memoryBytes: 12 * 1024 * 1024,
              cpu: Duration(milliseconds: 4200),
              tasks: 3,
              restarts: 0,
              mainPid: 812,
              // Shown in local time, which a golden cannot pin.
            ),
          ),
        );
        await panel.readLines(tester);
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

  group('unit verbs (SVC-03, M4 E21)', () {
    List<(String, SystemctlVerb)> planned(_Panel panel) => [
      for (final PlanAction(:intent)
          in panel.engine.sentOfType<PlanAction>().cast<PlanAction>())
        switch (intent) {
          UnitAction(:final unit, :final verb) => (unit, verb),
          _ => throw StateError('$intent'),
        },
    ];

    testWidgets('the row menu and the unit page start, stop, restart and '
        'reload', (tester) async {
      final panel = await _pump(
        tester,
        safety: const SafetyPolicy(
          servers: {'srv-1': ServerSafety(management: true)},
        ),
      );
      await panel.sample(tester);

      await tester.tap(
        find.byKey(const ValueKey('units.rowActions.nginx.service')),
      );
      await tester.pumpAndSettle();
      for (final verb in ['Start', 'Stop', 'Restart', 'Reload']) {
        expect(find.text(verb), findsOneWidget, reason: verb);
      }
      await tester.tap(find.text('Restart'));
      await tester.pumpAndSettle();
      // A second preview waits for the first's answer.
      panel.engine.emit(
        const ActionRefused(
          ActionRefusalReason.readOnly,
          intent: UnitAction(
            'srv-1',
            unit: 'nginx.service',
            verb: SystemctlVerb.restart,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _open(tester, 'nginx.service');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Reload'));
      await tester.pumpAndSettle();
      expect(planned(panel), [
        ('nginx.service', SystemctlVerb.restart),
        ('nginx.service', SystemctlVerb.reload),
      ]);
    });

    testWidgets('observe-only offers none', (tester) async {
      final panel = await _pump(tester, safety: const SafetyPolicy());
      await panel.sample(tester);
      expect(
        find.byKey(const ValueKey('units.rowActions.nginx.service')),
        findsNothing,
      );
      await _open(tester, 'nginx.service');
      expect(find.widgetWithText(OutlinedButton, 'Restart'), findsNothing);
    });
  });

  group('the v1 unit page (SVC-05 to SVC-08)', () {
    testWidgets('reads the unit\'s resources beside its states', (
      tester,
    ) async {
      final panel = await _pump(tester);
      await panel.sample(tester);
      await _open(tester, 'nginx.service');

      final query = panel.engine.sentOfType<UnitQuery>().cast<UnitQuery>();
      expect((query.single.query as UnitResourcesQuery).unit, 'nginx.service');
      await panel.answerUnit(
        tester,
        const UnitResourcesPayload(
          UnitResources(memoryBytes: 2 * 1024 * 1024, tasks: 4, restarts: 1),
        ),
      );
      expect(find.text('2 MiB'), findsOneWidget);
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);

      // A unit read that fails says why in the same place.
      await _open(tester, 'cron.service');
      await panel.answerUnit(
        tester,
        const UnitQueryFailed(UnitQueryFailure.notFound),
      );
      expect(find.text('The manager has no such unit.'), findsOneWidget);
    });

    testWidgets('the unit file shows masked, reveals for a while and hides '
        'again', (tester) async {
      final panel = await _pump(tester);
      await panel.sample(tester);
      await _open(tester, 'nginx.service');

      await tester.tap(find.byTooltip('Show unit file'));
      await tester.pumpAndSettle();
      final query = panel.engine.sentOfType<UnitQuery>().cast<UnitQuery>().last;
      expect((query.query as UnitFileQuery).unit, 'nginx.service');
      await panel.answerUnit(
        tester,
        UnitFilePayload([
          MaskedValue.plain('[Service]\nEnvironment='),
          MaskedValue.secret('TOKEN=abc'),
          MaskedValue.plain('\n'),
        ]),
      );

      String text() => tester
          .widget<PlanchetteEditor>(find.byType(PlanchetteEditor))
          .controller
          .text
          .text;
      expect(find.text('nginx.service file'), findsOneWidget);
      expect(text(), '[Service]\nEnvironment=********\n');
      await tester.tap(find.text('Reveal values'));
      await tester.pumpAndSettle();
      expect(text(), '[Service]\nEnvironment=TOKEN=abc\n');

      // The reveal ends by itself after kRevealDuration.
      await tester.pump(kRevealDuration);
      await tester.pumpAndSettle();
      expect(text(), '[Service]\nEnvironment=********\n');
      expect(find.text('Reveal values'), findsOneWidget);

      await tester.tap(find.text('Reveal values'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide values'));
      await tester.pumpAndSettle();
      expect(text(), '[Service]\nEnvironment=********\n');
    });

    testWidgets('the unit file dialog fits a window narrower than its size', (
      tester,
    ) async {
      const window = Size(700, 560);
      final panel = await _pump(tester, size: window);
      await panel.sample(tester);
      await _open(tester, 'nginx.service');

      await tester.tap(find.byTooltip('Show unit file'));
      await tester.pumpAndSettle();
      await panel.answerUnit(
        tester,
        UnitFilePayload([MaskedValue.plain('[Service]\n')]),
      );
      expect(tester.takeException(), isNull);
      final dialog = tester.getRect(find.byType(Dialog));
      expect(Offset.zero & window, _contains(dialog));
      final close = tester.getRect(find.byTooltip('Close'));
      expect(dialog, _contains(close));
    });

    testWidgets('"More" plans the v1 verbs where actions are allowed', (
      tester,
    ) async {
      final panel = await _pump(
        tester,
        safety: const SafetyPolicy(
          servers: {'srv-1': ServerSafety(management: true)},
        ),
      );
      await panel.sample(tester);
      await _open(tester, 'nginx.service');

      await tester.tap(find.widgetWithText(OutlinedButton, 'More'));
      await tester.pumpAndSettle();
      for (final label in [
        'Enable',
        'Disable',
        'Mask',
        'Unmask',
        'Reset failed state',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('Enable'));
      await tester.pump();

      final plan = panel.engine.sentOfType<PlanAction>().cast<PlanAction>();
      final intent = plan.single.intent as UnitAction;
      expect(
        (intent.unit, intent.verb),
        ('nginx.service', SystemctlVerb.enable),
      );
    });
  });
}

/// Matches a [Rect] that lies wholly inside the expected one.
Matcher _contains(Rect inner) => predicate<Rect>(
  (outer) =>
      outer.left <= inner.left &&
      outer.top <= inner.top &&
      outer.right >= inner.right &&
      outer.bottom >= inner.bottom,
  'contains $inner',
);
