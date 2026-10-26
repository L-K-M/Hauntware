import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/processes_panel.dart';
import 'package:klabautermann_app/ui/processes_view.dart'
    show ProcessColumn, kProcessTextLimit;
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_app/ui/sortable_table.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _mib = 1024 * 1024;

const _wide = Size(718, 600);
const _phone = Size(390, 900);

/// When the readings are taken; local, so the words do not depend on the
/// test machine's zone.
final _now = DateTime(2026, 10, 15, 14, 30);
final _booted = DateTime(2026, 10, 3, 11, 23);

/// The login user is `deploy` (uid 1000), the one uid the probe names.
final _profile = HostProfile(
  uid: 1000,
  user: 'deploy',
  container: 'none',
  lxcfsMounts: const [],
);

ProcsResult _procs({int? total = 5, ProcsSelection? selection}) => ProcsResult(
  [
    ProcessRow(
      pid: 1,
      parentPid: 0,
      name: 'systemd',
      state: 'S',
      uid: 0,
      residentBytes: 12 * _mib,
      cpuPercent: 0.1,
      startTicks: 100,
      startedAt: _booted,
      arguments: [MaskedValue.plain('/sbin/init')],
    ),
    ProcessRow(
      pid: 812,
      parentPid: 1,
      name: 'mysqld',
      state: 'S',
      uid: 27,
      residentBytes: 512 * _mib,
      cpuPercent: 12.5,
      startTicks: 5000,
      startedAt: DateTime(2026, 10, 15, 9, 41),
      arguments: [
        MaskedValue.plain('/usr/sbin/mysqld'),
        MaskedValue.redacted('--password=********', '--password=hunter2'),
        MaskedValue.plain('--port=3306'),
      ],
    ),
    ProcessRow(
      pid: 2041,
      parentPid: 1,
      name: 'node',
      state: 'R',
      uid: 1000,
      residentBytes: 180 * _mib,
      cpuPercent: 48.3,
      startTicks: 9000,
      startedAt: DateTime(2026, 10, 15, 13, 2),
      arguments: [MaskedValue.plain('node'), MaskedValue.plain('server.js')],
    ),
    ProcessRow(
      pid: 2,
      parentPid: 0,
      name: 'kthreadd',
      state: 'S',
      uid: 0,
      startTicks: 0,
      startedAt: _booted,
      arguments: const [],
    ),
    // Its first reading: no share, and nothing else read.
    const ProcessRow(pid: 3100, name: 'bash', uid: 1000),
  ],
  totalProcesses: total,
  selection: selection ?? ProcsSelection.all,
);

final class _Panel {
  _Panel(this.engine);

  final FakeEngineClient engine;
  int _seq = 0;

  Future<void> sample(WidgetTester tester, SampleResult result) async {
    engine.emit(
      Sample(
        serverId: _serverId,
        stream: SampleStream.procs,
        seq: ++_seq,
        at: _now,
        result: result,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> all(WidgetTester tester, [ProcsResult? procs]) async {
    engine.emit(HostProfileChanged(_serverId, _profile));
    await sample(tester, procs ?? _procs());
  }
}

/// What the monitoring clock reads; tests move it.
late DateTime _clock;

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
  SafetyPolicy? safety,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  _clock = _now;
  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _clock);
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
              child: ProcessesPanel(
                monitoring: monitoring,
                serverId: _serverId,
                visible: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine);
}

Finder _row(int pid) => find.byKey(ValueKey('procs.row.$pid'));

/// The pids the panel shows, top to bottom.
List<int> _order(WidgetTester tester) {
  const prefix = 'procs.row.';
  final rows = [
    for (final element in find.byType(Semantics).evaluate())
      if (element.widget.key case ValueKey<String>(
        :final value,
      ) when value.startsWith(prefix))
        (
          pid: int.parse(value.substring(prefix.length)),
          top: tester.getTopLeft(find.byWidget(element.widget)).dy,
        ),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return [for (final row in rows) row.pid];
}

/// 03 §10.4's Processes tab (PRC-01, SAF-07) over the `procs` stream.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('PRC-01: the table shows each figure in IEC units, unknowns as '
      'unknown, and no row actions yet', (tester) async {
    final panel = await _pump(tester);
    await panel.all(tester);

    for (final text in [
      '/usr/sbin/mysqld --password=******** --port=3306',
      'UID 27',
      'deploy',
      '12.5%',
      '512 MiB',
      DateFormat.jm('en').format(DateTime(2026, 10, 15, 9, 41)),
      'Oct 3, 2026',
      'kthreadd (command line unavailable)',
      'bash (command line unavailable)',
    ]) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    // bash's CPU, memory and start, and the kernel thread's CPU and
    // memory.
    expect(find.text('unknown'), findsNWidgets(5));
    expect(find.textContaining('hunter2'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SortableTable<ProcessRow>),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
  });

  testWidgets('PRC-03: the tree shows children under their parent, in the '
      'sort\'s order, and keeps a match\'s parents', (tester) async {
    final panel = await _pump(tester);
    await panel.all(tester);
    expect(_order(tester), [2041, 812, 1, 2, 3100]);

    await tester.tap(find.widgetWithText(FilterChip, 'Tree'));
    await tester.pumpAndSettle();
    // systemd's children by CPU under it; kthreadd and bash are roots.
    expect(_order(tester), [1, 2041, 812, 2, 3100]);
    final indent =
        tester.getTopLeft(find.text('node server.js')).dx -
        tester.getTopLeft(find.text('/sbin/init')).dx;
    expect(indent, greaterThan(0));

    await tester.enterText(find.byType(TextField), 'mysqld');
    await tester.pumpAndSettle();
    expect(_order(tester), [1, 812]);
  });

  testWidgets('PRC-06: zombies and processes stuck on I/O are flagged in '
      'words and counted', (tester) async {
    final panel = await _pump(tester);
    final base = _procs();
    await panel.all(
      tester,
      ProcsResult(
        [
          ...base.processes,
          const ProcessRow(
            pid: 4000,
            parentPid: 2041,
            name: 'defunct-worker',
            state: 'Z',
            uid: 1000,
          ),
          ProcessRow(
            pid: 4001,
            parentPid: 1,
            name: 'rsync',
            state: 'D',
            uid: 0,
            arguments: [MaskedValue.plain('rsync'), MaskedValue.plain('-a')],
          ),
        ],
        totalProcesses: 7,
        selection: ProcsSelection.all,
      ),
    );
    expect(
      find.text(
        '1 zombie process; 1 process waiting on I/O it cannot be '
        'interrupted from',
      ),
      findsOneWidget,
    );
    expect(find.text('zombie'), findsOneWidget);
    expect(find.text('waiting on I/O'), findsOneWidget);
  });

  testWidgets('a masked argument reads as masked, never as its secret or '
      'asterisks (SAF-07)', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(tester);
    await panel.all(tester);

    expect(
      tester.getSemantics(_row(812)),
      isSemantics(
        label:
            'Command: /usr/sbin/mysqld --password=(masked) --port=3306\n'
            'PID: 812\nUser: UID 27\nCPU: 12.5%\nMemory: 512 MiB\n'
            'Started: ${DateFormat.jm('en').format(DateTime(2026, 10, 15, 9, 41))}',
      ),
    );
    handle.dispose();
  });

  testWidgets('PRC-01 sorts by CPU first, then by memory, user, start time '
      'and command', (tester) async {
    final panel = await _pump(tester);
    await panel.all(tester);

    // Unknown shares sort last.
    expect(_order(tester), [2041, 812, 1, 2, 3100]);
    for (final (column, order) in [
      ('memory', [812, 2041, 1, 2, 3100]),
      // Named users first, then by uid.
      ('user', [2041, 3100, 1, 2, 812]),
      ('started', [2, 1, 812, 2041, 3100]),
      ('command', [1, 812, 3100, 2, 2041]),
    ]) {
      await tester.tap(find.byKey(ValueKey('procs.column.$column')));
      await tester.pumpAndSettle();
      expect(_order(tester), order, reason: column);
    }
  });

  testWidgets('the filter reads shown text only, and a cut list says how '
      'many it shows (D48)', (tester) async {
    final panel = await _pump(tester);
    await panel.all(
      tester,
      _procs(total: 900, selection: ProcsSelection.cpuAndMemory),
    );
    expect(find.text('Showing 5 of 900 processes'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'MYSQL');
    await tester.pumpAndSettle();
    expect(_order(tester), [812]);

    // The user as the column shows it.
    await tester.enterText(find.byType(TextField), 'UID 27');
    await tester.pumpAndSettle();
    expect(_order(tester), [812]);

    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pumpAndSettle();
    expect(_order(tester), isEmpty);
    expect(find.text('No process matches the filter.'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear filter'));
    await tester.pumpAndSettle();
    expect(_order(tester), hasLength(5));
  });

  testWidgets('the list ages, turns grey once stale, and stays through a '
      'failed reading with why it failed', (tester) async {
    final panel = await _pump(tester);
    await panel.all(tester);
    expect(find.text('Updated 0 s ago'), findsOneWidget);

    _clock = _now.add(const Duration(seconds: 25));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Stale: updated 25 s ago'), findsOneWidget);
    final theme = Theme.of(tester.element(find.text('512 MiB')));
    expect(
      tester.widget<Text>(find.text('512 MiB')).style?.color,
      theme.colorScheme.onSurfaceVariant,
    );

    await panel.sample(
      tester,
      const CollectorUnavailable(
        CollectorUnavailableReason.denied,
        detail: 'head: permission denied',
      ),
    );
    expect(find.text('The server refused the process list.'), findsOneWidget);
    expect(find.text('head: permission denied'), findsOneWidget);
    expect(_order(tester), hasLength(5));
  });

  testWidgets('the details say how old their reading is, grey once stale', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.all(tester);
    _clock = _now.add(const Duration(seconds: 25));
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(_row(812));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(
        of: sheet,
        matching: find.text('Stale: updated 25 s ago'),
      ),
      findsOneWidget,
    );
    final memory = find.descendant(of: sheet, matching: find.text('512 MiB'));
    expect(
      tester.widget<Text>(memory).style?.color,
      Theme.of(tester.element(memory)).colorScheme.onSurfaceVariant,
    );
  });

  testWidgets('the details follow a sampling change made while they show', (
    tester,
  ) async {
    final panel = await _pump(tester);
    panel.engine.emit(
      SamplingState(
        serverId: _serverId,
        phase: SamplingPhase.sampling,
        since: _now,
      ),
    );
    await panel.all(tester);
    await tester.tap(_row(812));
    await tester.pumpAndSettle();

    panel.engine.emit(
      SamplingState(
        serverId: _serverId,
        phase: SamplingPhase.waitingForLink,
        since: _now,
      ),
    );
    _clock = _now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Disconnected 3 s ago'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failure before any list says so instead of waiting', (
    tester,
  ) async {
    final panel = await _pump(tester);
    expect(find.text('Waiting for the first process list.'), findsOneWidget);

    await panel.sample(
      tester,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
    );

    expect(
      find.text('The process list did not finish in time.'),
      findsOneWidget,
    );
    expect(find.text('Waiting for the first process list.'), findsNothing);
    expect(find.byType(SortableTable<ProcessRow>), findsNothing);
  });

  testWidgets('SAF-07: a tap reveals one argument in the details, for 30 s, '
      'and leaving the app masks it again', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(tester);
    await panel.all(tester);

    await tester.tap(_row(812));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('Parent PID')),
      findsOneWidget,
    );
    expect(
      find.text('Select a masked argument to show it for 30 seconds.'),
      findsOneWidget,
    );
    final masked = find.descendant(
      of: sheet,
      matching: find.text('--password=********'),
    );
    expect(
      tester.getSemantics(masked),
      isSemantics(
        label: '--password=(masked)',
        hint: 'Show the masked value',
        isButton: true,
      ),
    );

    await tester.tap(masked);
    await tester.pumpAndSettle();
    expect(find.text('--password=hunter2'), findsOneWidget);
    await tester.pump(kRevealDuration);
    expect(find.text('--password=hunter2'), findsNothing);

    await tester.tap(masked);
    await tester.pumpAndSettle();
    expect(find.text('--password=hunter2'), findsOneWidget);
    // Inactive comes before hidden, while the app still draws a frame
    // that an app switcher's snapshot would keep.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('--password=hunter2'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    handle.dispose();
  });

  testWidgets('PRC-04, PRC-05: the details read the process, with its '
      'owner, and its environment masked until revealed', (tester) async {
    final panel = await _pump(tester);
    await panel.all(tester);

    await tester.tap(_row(812));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(find.text('Reading details…'), findsOneWidget);
    final read = panel.engine.sentOfType<HostQuery>().cast<HostQuery>().last;
    final query = read.query as ProcessDetailQuery;
    expect(
      (read.serverId, query.pid, query.startTicks),
      (_serverId, 812, 5000),
    );

    panel.engine.emit(
      HostResult(
        serverId: _serverId,
        queryId: read.queryId,
        payload: ProcessDetails(
          ProcessDetail(
            cwdDenied: true,
            threads: 37,
            swapKb: 2048,
            voluntarySwitches: 120,
            involuntarySwitches: 4,
            attribution: const ProcessAttribution(
              unit: 'docker-0123456789abcdef.scope',
              containerId: '0123456789abcdef0123',
              runtime: ContainerRuntime.docker,
            ),
            openFiles: 61,
            openFilesLimit: const ProcessLimit(soft: 1024, hard: 524288),
            processesLimit: const ProcessLimit(),
          ),
          environment: [
            EnvVar('LANG', MaskedValue.plain('C.UTF-8')),
            EnvVar(
              'MYSQL_PASSWORD',
              MaskedValue.redacted('********', 'hunter2'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reading details…'), findsNothing);
    for (final text in [
      'docker-0123456789abcdef.scope',
      'Docker 0123456789ab',
      'Not readable as this user',
      '37',
      '2 MiB',
      '120 voluntary, 4 involuntary',
      '61 of 1024',
      'Unlimited',
    ]) {
      expect(
        find.descendant(of: sheet, matching: find.text(text)),
        findsOneWidget,
      );
    }

    final list = find.descendant(of: sheet, matching: find.byType(Scrollable));
    // The variables end the sheet, so scrolling to its end shows them.
    await tester.fling(list, const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    expect(find.text('C.UTF-8'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('********')),
      isSemantics(
        label: 'MYSQL_PASSWORD: (masked)',
        hint: 'Show the masked value',
        isButton: true,
      ),
    );
    await tester.tap(find.text('********'));
    await tester.pumpAndSettle();
    expect(find.text('hunter2'), findsOneWidget);

    // A new read masks the variables again and says what it found.
    await tester.dragUntilVisible(
      find.text('Read again'),
      list,
      const Offset(0, 200),
    );
    await tester.tap(find.text('Read again'));
    await tester.pump();
    final again = panel.engine.sentOfType<HostQuery>().cast<HostQuery>().last;
    expect(again.queryId, isNot(read.queryId));
    panel.engine.emit(
      HostResult(
        serverId: _serverId,
        queryId: again.queryId,
        payload: const ProcessEnded(ProcessEnd.reused),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Its process ID now belongs to another process, so nothing was read.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('MYSQL_PASSWORD'), findsNothing);
  });

  testWidgets('a process without a start time is not read', (tester) async {
    final panel = await _pump(tester);
    await panel.all(tester);
    final sent = panel.engine.sentOfType<HostQuery>().length;

    await tester.tap(_row(3100));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The server did not report when this process started, so its '
        'details are not read.',
      ),
      findsOneWidget,
    );
    expect(find.text('Read again'), findsNothing);
    expect(panel.engine.sentOfType<HostQuery>(), hasLength(sent));
  });

  testWidgets('a long masked argument reads cut, as it draws', (tester) async {
    final panel = await _pump(tester);
    final script = '${'x' * 5000} TOKEN=';
    await panel.all(
      tester,
      ProcsResult([
        ProcessRow(
          pid: 900,
          name: 'sh',
          arguments: [
            MaskedValue.plain('sh'),
            MaskedValue.plain('-c'),
            MaskedValue.redacted('$script********', '${script}hunter2'),
          ],
        ),
      ]),
    );

    await tester.tap(_row(900));
    await tester.pumpAndSettle();
    final masked = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.hint == 'Show the masked value',
      ),
    );
    expect(masked.properties.label, '${'x' * kProcessTextLimit}…');
  });

  testWidgets('SAF-07: touch platforms give a masked argument a 48 dp tap '
      'target', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.all(tester);

    await tester.tap(_row(812));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('a phone lists two-line rows with a sort menu, not a squeezed '
      'table', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.all(tester);

    expect(find.byType(SortableTable<ProcessRow>), findsNothing);
    expect(_order(tester), [2041, 812, 1, 2, 3100]);
    expect(find.text('Memory: 512 MiB'), findsOneWidget);
    // A row reads as the table's does, the mask as "(masked)" (SAF-07).
    expect(
      tester.getSemantics(_row(812)),
      isSemantics(
        label:
            'Command: /usr/sbin/mysqld --password=(masked) --port=3306\n'
            'PID: 812\nUser: UID 27\nCPU: 12.5%\nMemory: 512 MiB\n'
            'Started: ${DateFormat.jm('en').format(DateTime(2026, 10, 15, 9, 41))}',
        isButton: true,
      ),
    );

    await tester.tap(find.byType(DropdownButton<ProcessColumn>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Started').last);
    await tester.pumpAndSettle();
    expect(_order(tester), [2, 1, 812, 2041, 3100]);

    await tester.tap(find.byTooltip('Sorted ascending'));
    await tester.pumpAndSettle();
    expect(_order(tester), [2041, 812, 1, 2, 3100]);
    handle.dispose();
  });

  for (final (name, size) in [('phone', _phone), ('desktop', _wide)]) {
    testWidgets('the $name layout holds at 200% text', (tester) async {
      final panel = await _pump(tester, size: size, textScale: 2);
      await panel.all(tester);

      expect(tester.takeException(), isNull);
      // Larger text takes the list before the table would scroll sideways.
      expect(find.byType(SortableTable<ProcessRow>), findsNothing);
      expect(_order(tester), isNotEmpty);
    });
  }

  group('golden', () {
    // 03 §11.1: a list with a masked argument, a kernel thread, unknown
    // figures and a cut list, on desktop and on a phone.
    for (final brightness in Brightness.values) {
      for (final (name, size, platform) in [
        ('desktop', _wide, TargetPlatform.linux),
        ('phone', _phone, TargetPlatform.android),
      ]) {
        testWidgets('$name, ${brightness.name}', (tester) async {
          final panel = await _pump(
            tester,
            size: size,
            brightness: brightness,
            platform: platform,
          );
          await panel.all(
            tester,
            _procs(total: 900, selection: ProcsSelection.cpuAndMemory),
          );
          await expectLater(
            find.byType(ProcessesPanel),
            matchesGoldenFile(
              'goldens/processes_panel_${name}_${brightness.name}.png',
            ),
          );
        }, skip: !goldensCompareHere);
      }
    }
  });

  group('signals (PRC-02, M4 E21)', () {
    const managed = SafetyPolicy(
      servers: {_serverId: ServerSafety(management: true)},
    );

    List<KillProcess> planned(_Panel panel) => [
      for (final PlanAction(:intent)
          in panel.engine.sentOfType<PlanAction>().cast<PlanAction>())
        intent as KillProcess,
    ];

    testWidgets('the row menu terminates, kills or sends any signal, with '
        'the row\'s start time', (tester) async {
      final panel = await _pump(tester, safety: managed);
      await panel.all(tester);

      await tester.tap(find.byKey(const ValueKey('procs.rowActions.812')));
      await tester.pumpAndSettle();
      expect(find.text('Terminate'), findsOneWidget);
      expect(find.text('Send signal'), findsOneWidget);
      await tester.tap(find.text('Kill'));
      await tester.pumpAndSettle();

      final kill = planned(panel).single;
      expect(
        (kill.serverId, kill.pid, kill.startTicks, kill.signal),
        (_serverId, 812, 5000, KillSignal.sigkill),
      );
      expect(
        find.byKey(const ValueKey('procs.rowActions.3100')),
        findsNothing,
        reason: 'no start time to guard the kill',
      );
    });

    testWidgets('a process\'s details offer the same signals', (tester) async {
      final panel = await _pump(tester, safety: managed);
      await panel.all(tester);
      await tester.tap(_row(2041));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Terminate'),
        ),
      );
      await tester.pumpAndSettle();
      expect(planned(panel).single.signal, KillSignal.sigterm);
    });

    for (final (name, policy) in [
      ('observe-only', const SafetyPolicy()),
      (
        'read-only',
        const SafetyPolicy(
          globalReadOnly: true,
          servers: {_serverId: ServerSafety(management: true)},
        ),
      ),
    ]) {
      testWidgets('$name offers none', (tester) async {
        final panel = await _pump(tester, safety: policy);
        await panel.all(tester);
        expect(
          find.byKey(const ValueKey('procs.rowActions.812')),
          findsNothing,
        );
        await tester.tap(_row(2041));
        await tester.pumpAndSettle();
        expect(find.text('Terminate'), findsNothing);
      });
    }
  });
}
