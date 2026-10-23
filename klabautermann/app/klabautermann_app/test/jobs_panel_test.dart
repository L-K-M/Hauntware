import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/admin_mode_chip.dart';
import 'package:klabautermann_app/ui/jobs_panel.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_app/ui/sortable_table.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CronDirEntry,
        CronExpression,
        CronJob,
        CronPeriod,
        CronSnapshot,
        CrontabManager,
        LoggedCronRun,
        MonotonicBase,
        TimerLastRun,
        OnCalendarElapse,
        mergeJobs,
        parseUserCrontab;

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';
import 'support/jobs.dart';

const _serverId = 'srv-1';
const _wide = Size(718, 640);
const _phone = Size(390, 844);

final class _Panel {
  _Panel(this.engine, this.visible);

  final FakeEngineClient engine;

  /// Whether the panel's tab shows.
  final ValueNotifier<bool> visible;

  /// The server the panel shows, which a desktop selection changes in
  /// place.
  final server = ValueNotifier(_serverId);

  /// What the monitoring clock reads.
  DateTime now = jobsNow;
  int _seq = 0;

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  /// A reading of [stream] taken [at], by default [jobsNow].
  Future<void> sample(
    WidgetTester tester,
    SampleStream stream,
    SampleResult result, {
    DateTime? at,
  }) => emit(
    tester,
    Sample(
      serverId: _serverId,
      stream: stream,
      seq: ++_seq,
      at: at ?? jobsNow,
      result: result,
    ),
  );

  /// The probe's profile, then a reading of each stream.
  Future<void> all(WidgetTester tester, {bool ownCrontabKnown = true}) async {
    await emit(tester, HostProfileChanged(_serverId, jobsProfile));
    await sample(
      tester,
      SampleStream.cron,
      jobsCron(ownCrontabKnown: ownCrontabKnown),
    );
    await sample(tester, SampleStream.timers, jobsTimers());
  }
}

/// [child] in the app's localizations and brand theme at [size]: a
/// phone's with its touch rows.
Future<void> _frame(
  WidgetTester tester,
  Widget child, {
  required Size size,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  Widget Function(Widget child)? scopes,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final platform = size == _phone
      ? TargetPlatform.android
      : TargetPlatform.linux;
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
      // Above the Navigator, so a row's details sheet scales too.
      builder: (context, navigator) {
        final scaled = MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: navigator!,
        );
        return scopes?.call(scaled) ?? scaled;
      },
      home: Scaffold(
        body: RepaintBoundary(
          child: ColoredBox(color: theme.colorScheme.surface, child: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool visible = true,
  SafetyPolicy? safety,
}) async {
  final engine = FakeEngineClient();
  final admin = AdminController(engine);
  addTearDown(admin.dispose);
  final shown = ValueNotifier(visible);
  final panel = _Panel(engine, shown);
  final monitoring = MonitoringController(engine, now: () => panel.now);
  addTearDown(() async {
    shown.dispose();
    panel.server.dispose();
    monitoring.dispose();
    await engine.close();
  });
  final operations = OperationsController(engine);
  addTearDown(operations.dispose);
  final policy = safety == null
      ? null
      : SafetyController(initial: safety, apply: (_) {});
  if (policy != null) addTearDown(policy.dispose);
  await _frame(
    tester,
    scopes: policy == null
        ? null
        : (child) => SafetyScope(
            safety: policy,
            child: AdminScope(
              admin: admin,
              child: OperationsScope(operations: operations, child: child),
            ),
          ),
    ValueListenableBuilder(
      valueListenable: shown,
      builder: (context, visible, _) => ValueListenableBuilder(
        valueListenable: panel.server,
        builder: (context, serverId, _) => JobsPanel(
          monitoring: monitoring,
          serverId: serverId,
          visible: visible,
        ),
      ),
    ),
    size: size,
    textScale: textScale,
    brightness: brightness,
  );
  return panel;
}

const _timerOneRun =
    "systemd's timer list gives only the next run, so later runs are not "
    'shown.';

Finder _row(String id) => find.byKey(ValueKey('jobs.row.$id'));

/// The table's row ids, top to bottom.
List<String> _rowOrder() => [
  for (final element in find.byType(Semantics).evaluate())
    if (element.widget.key case ValueKey<String>(
      :final value,
    ) when value.startsWith('jobs.row.'))
      value.substring('jobs.row.'.length),
];

Finder _inSheet(String text) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

/// 03 §10.2's Jobs tab: JOB-01's unified list and JOB-02's schedules in
/// words with next runs on the server's clock, from the cron and timers
/// streams and the probe's profile.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('the desktop Jobs tab samples cron and timers while shown', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      servers: twoServers,
      size: const Size(1280, 900),
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    final tab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text('Jobs'),
    );
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();

    final jobs = harness.engine.sentOfType<Subscribe>().cast<Subscribe>().last;
    expect(jobs.streams, {SampleStream.cron, SampleStream.timers});
    expect(find.text('Waiting for the first reading.'), findsOneWidget);
  });

  testWidgets('JOB-01 lists every source with its user, next run first', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.all(tester);

    expect(
      find.text("Cron times are in Europe/Berlin, the server's time zone."),
      findsOneWidget,
    );
    expect(
      find.text(
        "Timer times are at the server's offset now, UTC+02:00; a DST "
        'change before a run does not show.',
      ),
      findsOneWidget,
    );
    for (final text in [
      'Your crontab',
      '/etc/cron.d/backup, as root',
      '/etc/cron.daily',
      'systemd timer',
      'Runs every 15 minutes',
      'Runs at 2:30 AM',
      'Runs at 9:00 AM, on Monday to Friday (America/New_York time)',
      'anacron runs this directory; its timing is not shown in this version.',
      'Triggers are not read in this version.',
      // Cron's run on Berlin's clock, a timer's at the probed offset,
      // which it names: after the DST change, Berlin's clock reads 1:12.
      'Sun, Oct 25 2:30 AM',
      'Sat, Oct 24 7:41 PM UTC+02:00',
      'Mon, Oct 26 2:12 AM UTC+02:00',
      'Mon, Oct 26 9:00 AM in America/New_York',
    ]) {
      expect(find.text(clock(text)), findsWidgets, reason: text);
    }

    // A row without runs says why in its next-run cell, which the phone
    // keeps when it drops the schedule.
    for (final (row, text) in [
      ('cron|crontab|1', 'At cron start'),
      ('periodic|daily|logrotate', 'Timed by anacron'),
    ]) {
      expect(
        find.descendant(of: _row(row), matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }

    // A DST change marks a run with an icon, and in words for screen
    // readers.
    expect(find.bySemanticsLabel(RegExp(r'2:30\sAM \(DST\)')), findsOneWidget);

    // The next job to run leads; unknown runs sort last.
    final order = _rowOrder();
    expect(order.take(2), ['cron|crontab|0', 'timer|apt-daily.timer']);
    expect(order.last, 'timer|certbot.timer');
  });

  testWidgets('a row opens its runs with offsets and DST notes', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.all(tester);

    await tester.tap(_row('cron|/etc/cron.d/backup|0'));
    await tester.pumpAndSettle();
    for (final text in [
      '/usr/local/bin/backup',
      '30 2 * * *',
      'Sun, Oct 25, 2026 2:30 AM UTC+02:00',
      '2:30 AM occurs twice at this DST change; the job runs at the first '
          'only.',
      'Mon, Oct 26, 2026 2:30 AM UTC+01:00',
    ]) {
      expect(_inSheet(clock(text)), findsWidgets, reason: text);
    }
  });

  testWidgets('a script run from two zones names each next run\'s offset', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
    await panel.sample(
      tester,
      SampleStream.cron,
      cronResultOf(
        CronSnapshot(
          jobs: [
            cronLine(
              '/etc/crontab',
              '0 23 * * *',
              'run-parts /etc/cron.daily',
              user: 'root',
            ),
            cronLine(
              '/etc/crontab',
              '0 13 * * *',
              'run-parts /etc/cron.daily',
              user: 'root',
              cronTz: 'America/New_York',
            ),
          ],
          dirEntries: const [
            CronDirEntry(period: CronPeriod.daily, name: 'logrotate'),
          ],
          ownCrontabPresent: true,
        ),
      ),
    );

    // New York's 1:00 PM comes first, 7:00 PM in Berlin, whose zone the
    // notice names: the row's time says its offset.
    expect(
      find.descendant(
        of: _row('periodic|daily|logrotate'),
        matching: find.text(clock('Sat, Oct 24 1:00 PM UTC−04:00')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failed or stale reading keeps its rows under the reason', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.all(tester, ownCrontabKnown: false);
    expect(find.text('Updated 0 s ago'), findsOneWidget);
    expect(
      find.text(
        'Your own crontab could not be read, so its jobs may be '
        'missing.',
      ),
      findsOneWidget,
    );

    await panel.sample(
      tester,
      SampleStream.timers,
      const CollectorUnavailable(
        CollectorUnavailableReason.timeout,
        detail: 'systemctl: timed out',
      ),
    );
    panel.now = jobsNow.add(const Duration(minutes: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Stale: updated 3 min ago'), findsOneWidget);
    expect(
      find.text(
        'Timers could not be read: this reading took too long, so '
        'the server stopped it.',
      ),
      findsOneWidget,
    );
    expect(find.text('systemctl: timed out'), findsOneWidget);
    expect(find.text('apt-daily.timer'), findsOneWidget);
  });

  testWidgets('a clock tick ages the freshness line, not the table', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.all(tester);
    final table = find.byType(SortableTable<JobEntry>);
    final before = tester.widget(table);
    Color? next() => tester
        .widget<Text>(find.text(clock('Sat, Oct 24 7:41 PM UTC+02:00')))
        .style
        ?.color;
    expect(next(), isNull);

    // A long list is not sorted again every second.
    panel.now = jobsNow.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Updated 5 s ago'), findsOneWidget);
    expect(tester.widget(table), same(before));

    // It follows the clock once its times turn stale.
    panel.now = jobsNow.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Stale: updated 2 min ago'), findsOneWidget);
    expect(
      next(),
      Theme.of(tester.element(table)).colorScheme.onSurfaceVariant,
    );
  });

  testWidgets('the clock runs only while the tab shows', (tester) async {
    final panel = await _pump(tester, visible: false);
    await panel.all(tester);
    expect(find.text('Updated 0 s ago'), findsOneWidget);
    final table = find.byType(SortableTable<JobEntry>);
    final before = tester.widget(table);

    // Hidden: nothing ages, and the table does not follow the clock past
    // the instant its times turn stale.
    panel.now = jobsNow.add(const Duration(minutes: 3));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Updated 0 s ago'), findsOneWidget);
    expect(tester.widget(table), same(before));

    panel.visible.value = true;
    await tester.pump();
    expect(find.text('Stale: updated 3 min ago'), findsOneWidget);

    panel.now = jobsNow.add(const Duration(minutes: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Stale: updated 4 min ago'), findsOneWidget);
  });

  testWidgets('the list is as fresh as its older stream', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
    await panel.sample(tester, SampleStream.cron, jobsCron());
    await panel.sample(
      tester,
      SampleStream.timers,
      jobsTimers(),
      at: jobsNow.subtract(const Duration(minutes: 3)),
    );

    expect(find.text('Stale: updated 3 min ago'), findsOneWidget);
    final next = find.text(clock('Sat, Oct 24 7:41 PM UTC+02:00'));
    expect(
      tester.widget<Text>(next).style?.color,
      Theme.of(tester.element(next)).colorScheme.onSurfaceVariant,
    );
  });

  testWidgets('a run the clock has passed no longer reads as next', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
    await panel.sample(
      tester,
      SampleStream.cron,
      cronResultOf(
        CronSnapshot(
          jobs: [
            cronLine('crontab', '* * * * *', '/usr/local/bin/tick'),
            // 12:01 and 12:05 UTC, and 12:03 between them.
            cronLine('crontab', '1,5 14 * * *', '/usr/local/bin/twice'),
            cronLine('crontab', '3 14 * * *', '/usr/local/bin/once'),
          ],
          ownCrontabPresent: true,
        ),
      ),
    );
    await panel.sample(
      tester,
      SampleStream.timers,
      TimersResult(
        TimersSnapshot(
          timers: [
            SystemdTimer(
              unit: 'tick.timer',
              nextUs: jobsNow
                  .add(const Duration(seconds: 45))
                  .microsecondsSinceEpoch,
            ),
          ],
        ),
      ),
    );
    Finder next(String row, String text) =>
        find.descendant(of: _row(row), matching: find.text(clock(text)));
    expect(next('cron|crontab|0', 'Sat, Oct 24 2:01 PM'), findsOneWidget);
    expect(
      next('timer|tick.timer', 'Sat, Oct 24 2:00 PM UTC+02:00'),
      findsOneWidget,
    );
    final before = _rowOrder();
    expect(before.first, 'timer|tick.timer');
    expect(
      before.indexOf('cron|crontab|1'),
      lessThan(before.indexOf('cron|crontab|2')),
    );

    // Still fresh, the reading's first run and the timer's one elapse
    // have passed: the next listed run leads, and the timer waits for
    // the next reading.
    panel.now = jobsNow.add(const Duration(seconds: 90));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Updated 1 min ago'), findsOneWidget);
    expect(next('cron|crontab|0', 'Sat, Oct 24 2:02 PM'), findsOneWidget);
    expect(next('timer|tick.timer', 'unknown'), findsOneWidget);
    // The rows sort by the runs they show.
    expect(_rowOrder(), [
      'cron|crontab|0',
      'cron|crontab|2',
      'cron|crontab|1',
      'timer|tick.timer',
    ]);

    await tester.tap(_row('cron|crontab|0'));
    await tester.pumpAndSettle();
    expect(
      _inSheet(clock('Sat, Oct 24, 2026 2:01 PM UTC+02:00')),
      findsNothing,
    );
    expect(
      _inSheet(clock('Sat, Oct 24, 2026 2:02 PM UTC+02:00')),
      findsOneWidget,
    );
  });

  testWidgets('a timer without a next instant reads unknown on both paths', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
    await panel.sample(
      tester,
      SampleStream.cron,
      CronResult(CronSnapshot(ownCrontabPresent: true)),
    );
    await panel.sample(
      tester,
      SampleStream.timers,
      TimersResult(
        TimersSnapshot(
          timers: const [
            // systemd's text table prints n/a where its JSON gives null.
            SystemdTimer(unit: 'na.timer', nextText: 'n/a'),
            SystemdTimer(unit: 'none.timer'),
          ],
        ),
      ),
    );
    for (final row in ['timer|na.timer', 'timer|none.timer']) {
      expect(
        find.descendant(of: _row(row), matching: find.text('unknown')),
        findsOneWidget,
        reason: row,
      );
    }
    expect(find.text('n/a'), findsNothing);

    await tester.tap(_row('timer|na.timer'));
    await tester.pumpAndSettle();
    expect(_inSheet('n/a'), findsNothing);
    expect(_inSheet('unknown'), findsOneWidget);
  });

  testWidgets('an empty list names only the sources read', (tester) async {
    final panel = await _pump(tester);
    const all =
        'No jobs found in your crontab, the system cron files or systemd '
        'timers.';
    await panel.sample(
      tester,
      SampleStream.cron,
      CronResult(CronSnapshot(ownCrontabPresent: true)),
    );
    expect(find.text(all), findsNothing);

    await panel.sample(
      tester,
      SampleStream.timers,
      TimersResult(TimersSnapshot()),
    );
    expect(find.text(all), findsOneWidget);

    // An unclear crontab -l leaves the user's own jobs unknown.
    await panel.sample(tester, SampleStream.cron, CronResult(CronSnapshot()));
    expect(find.text(all), findsNothing);
    expect(
      find.text('No jobs found in the system cron files or systemd timers.'),
      findsOneWidget,
    );
  });

  testWidgets('a server without crontab has no own crontab to miss', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      HostProfileChanged(
        _serverId,
        HostProfile(zoneOffset: '+0000', tools: const {'crontab': null}),
      ),
    );
    // Without the command the parser cannot tell the user's crontab.
    await panel.sample(tester, SampleStream.cron, CronResult(CronSnapshot()));
    await panel.sample(
      tester,
      SampleStream.timers,
      TimersResult(TimersSnapshot()),
    );

    expect(find.textContaining('Your own crontab'), findsNothing);
    expect(
      find.text('No jobs found in the system cron files or systemd timers.'),
      findsOneWidget,
    );
  });

  testWidgets('a server without systemd has no timers to fail', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      HostProfileChanged(
        _serverId,
        HostProfile(zoneOffset: '+0000', systemdDir: false),
      ),
    );
    await panel.sample(
      tester,
      SampleStream.cron,
      CronResult(CronSnapshot(ownCrontabPresent: true)),
    );
    await panel.sample(
      tester,
      SampleStream.timers,
      const CollectorUnavailable(CollectorUnavailableReason.missing),
    );

    expect(find.textContaining('Timers could not be read'), findsNothing);
    expect(
      find.text('This server does not run systemd, so it has no timers.'),
      findsOneWidget,
    );
    expect(
      find.text('No jobs found in your crontab or the system cron files.'),
      findsOneWidget,
    );
  });

  testWidgets('the notices name the clock without zone rules, and a pause', (
    tester,
  ) async {
    final panel = await _pump(tester);
    // Before the probe answers, timer times are in UTC.
    await panel.sample(tester, SampleStream.timers, jobsTimers());
    expect(
      find.text(
        "Timer times are in UTC, as the server's offset is not known yet.",
      ),
      findsOneWidget,
    );
    expect(find.text(clock('Sat, Oct 24 5:41 PM UTC')), findsOneWidget);

    // A zone name this device does not know: cron runs at the offset.
    await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
    final cron = jobsCron();
    await panel.sample(
      tester,
      SampleStream.cron,
      CronResult(
        cron.cron,
        jobs: cron.jobs,
        zoneFallback: CronZoneFallback.unknownZone,
      ),
    );
    expect(
      find.text(
        "Cron times are at the server's offset now, UTC+02:00, as this "
        'device does not know its time zone, so later DST changes do not '
        'show.',
      ),
      findsOneWidget,
    );

    panel.engine.emit(
      SamplingState(
        serverId: _serverId,
        phase: SamplingPhase.pausedInBackground,
        since: jobsNow,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Paused: app in background'), findsOneWidget);
    expect(find.text('apt-daily.timer'), findsOneWidget);
  });

  group('a timer with its triggers read', () {
    final elapse = OnCalendarElapse(
      text: 'Sun 2026-10-25 06:00:00 CET',
      atUtc: DateTime.utc(2026, 10, 25, 5),
    );
    TimerJobEntry timer() => TimerJobEntry(
      timer: SystemdTimer(
        unit: 'backup.timer',
        activates: 'backup.service',
        nextUs: DateTime.utc(2026, 10, 25, 5, 12).microsecondsSinceEpoch,
      ),
      triggers: [
        CalendarSchedule(normalized: '*-*-* 06:00:00', elapses: [elapse]),
      ],
      randomizedDelay: const Duration(minutes: 30),
    );

    for (final (version, cut) in [(239, true), (252, false)]) {
      testWidgets('on systemd $version', (tester) async {
        await _frame(
          tester,
          SingleChildScrollView(
            child: JobDetails(
              job: timer(),
              now: jobsNow,
              profile: HostProfile(
                zoneOffset: '+0200',
                systemdVersion: version,
              ),
            ),
          ),
          size: _phone,
        );
        for (final text in [
          'On calendar *-*-* 06:00:00',
          'Sun, Oct 25, 2026 7:12 AM UTC+02:00',
          'Sun 2026-10-25 06:00:00 CET',
          'Each run starts up to 30 min late, at random (RandomizedDelaySec).',
        ]) {
          expect(find.text(clock(text)), findsWidgets, reason: text);
        }
        expect(
          find.text(
            'systemd before version 242 lists only the next run, so '
            'later runs are not shown.',
          ),
          cut ? findsOneWidget : findsNothing,
        );
        expect(find.text(_timerOneRun), findsNothing);
      });
    }

    testWidgets('says only the next run is known without its elapses', (
      tester,
    ) async {
      for (final job in [
        TimerJobEntry(timer: timer().timer),
        TimerJobEntry(
          timer: timer().timer,
          triggers: [
            MonotonicSchedule(
              base: MonotonicBase.unitActive,
              span: const Duration(hours: 1),
            ),
          ],
        ),
      ]) {
        await _frame(
          tester,
          SingleChildScrollView(
            child: JobDetails(
              job: job,
              now: jobsNow,
              profile: HostProfile(zoneOffset: '+0200', systemdVersion: 252),
            ),
          ),
          size: _phone,
        );
        expect(
          find.text(clock('Sun, Oct 25, 2026 7:12 AM UTC+02:00')),
          findsOneWidget,
        );
        expect(find.text(_timerOneRun), findsOneWidget);
      }
    });

    testWidgets('drops a calendar run the clock has passed', (tester) async {
      await _frame(
        tester,
        SingleChildScrollView(
          child: JobDetails(
            job: timer(),
            now: DateTime.utc(2026, 10, 25, 5, 0, 30),
            profile: HostProfile(zoneOffset: '+0200', systemdVersion: 252),
          ),
        ),
        size: _phone,
      );
      expect(find.text('Sun 2026-10-25 06:00:00 CET'), findsNothing);
      // The list-timers elapse at 05:12 has not passed; the calendar's
      // only listed run has, until the next reading.
      expect(
        find.text(clock('Sun, Oct 25, 2026 7:12 AM UTC+02:00')),
        findsOneWidget,
      );
      expect(find.text('unknown'), findsOneWidget);
    });
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets('the phone keeps the clock a next run follows at '
        '${(textScale * 100).round()} % text', (tester) async {
      final panel = await _pump(tester, size: _phone, textScale: textScale);
      await panel.all(tester);

      // A touch row holds a second line, where the offset or zone that
      // tells the time from the server's clock wraps instead of being
      // cut.
      final rows = find.descendant(
        of: find.byType(SortableTable<JobEntry>),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      for (final text in [
        'Sat, Oct 24 7:41 PM UTC+02:00',
        'Mon, Oct 26 2:12 AM UTC+02:00',
        'Mon, Oct 26 9:00 AM in America/New_York',
      ]) {
        final cell = find.text(clock(text));
        await tester.scrollUntilVisible(cell, 48, scrollable: rows);
        expect(
          tester.renderObject<RenderParagraph>(cell).didExceedMaxLines,
          isFalse,
          reason: text,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final (width, textScale) in [
    (718.0, 1.0),
    (1400.0, 1.0),
    (1000.0, 2.0),
  ]) {
    testWidgets('the desktop keeps the clock a next run follows at '
        '${width.round()} px and ${(textScale * 100).round()} % text', (
      tester,
    ) async {
      final panel = await _pump(
        tester,
        size: Size(width, 640),
        textScale: textScale,
      );
      await panel.all(tester);

      // A dense row holds one line, so the column is as wide as its
      // longest time: the offset or zone after it is never cut, in the
      // wide layout or in the narrow one large text brings.
      final rows = find.descendant(
        of: find.byType(SortableTable<JobEntry>),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      for (final text in [
        'Sat, Oct 24 7:41 PM UTC+02:00',
        'Mon, Oct 26 2:12 AM UTC+02:00',
        'Mon, Oct 26 9:00 AM in America/New_York',
      ]) {
        final cell = find.text(clock(text));
        await tester.scrollUntilVisible(cell, 22, scrollable: rows);
        expect(
          tester.renderObject<RenderParagraph>(cell).didExceedMaxLines,
          isFalse,
          reason: text,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('desktop', _wide), ('phone', _phone)]) {
    testWidgets('lays out without overflow at 200 % text on the $name', (
      tester,
    ) async {
      final panel = await _pump(tester, size: size, textScale: 2);
      await panel.all(tester);
      expect(tester.takeException(), isNull);

      await tester.tap(_row('cron|crontab|0'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final command = _inSheet('/home/deploy/bin/sync-assets');
      expect(command, findsWidgets);
      final sheetText = tester.element(command.first);
      expect(MediaQuery.textScalerOf(sheetText).scale(10), 20);
    });
  }

  group('golden', () {
    for (final brightness in Brightness.values) {
      for (final (name, size) in [('desktop', _wide), ('phone', _phone)]) {
        testWidgets('$name, ${brightness.name}', (tester) async {
          final panel = await _pump(tester, size: size, brightness: brightness);
          await panel.all(tester);
          await expectLater(
            find.byType(JobsPanel),
            matchesGoldenFile(
              'goldens/jobs_panel_${name}_${brightness.name}.png',
            ),
          );
        }, skip: !goldensCompareHere);
      }
    }
  });

  group('run timer now (JOB-08, M4 E21)', () {
    const managed = SafetyPolicy(
      servers: {_serverId: ServerSafety(management: true)},
    );

    ActionPreview preview() => ActionPreview(
      intent: const StartTimer(_serverId, timer: 'certbot.timer'),
      targetName: 'certbot.timer',
      steps: [
        ShellStep([
          'systemctl',
          '--no-ask-password',
          'start',
          '--',
          'certbot.service',
        ]),
      ],
      requiredLevel: RequiredLevel.login,
      runner: const RunnerFacts(identity: 'deploy'),
      requiredTier: ConfirmationTier.acknowledge,
      followUnit: 'certbot.service',
    );

    testWidgets('the row menu runs the timer and follows its service\'s '
        'journal', (tester) async {
      final panel = await _pump(tester, safety: managed);
      await panel.all(tester);

      await tester.tap(
        find.byKey(const ValueKey('jobs.rowActions.timer|certbot.timer')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run now'));
      await tester.pumpAndSettle();
      final intent =
          (panel.engine.sentOfType<PlanAction>().single as PlanAction).intent;
      expect((intent as StartTimer).timer, 'certbot.timer');

      await panel.emit(tester, ActionPlanned('plan-1', preview()));
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Output of certbot.service'), findsOneWidget);
      final follow = panel.engine
          .sentOfType<OpenLogStream>()
          .cast<OpenLogStream>()
          .single
          .spec;
      expect(follow.follow, isTrue);
      expect((follow.source as JournalLogSource).unit, 'certbot.service');

      await tester.tap(find.byTooltip('Close output'));
      await tester.pumpAndSettle();
      expect(panel.engine.sentOfType<CloseStream>(), hasLength(1));
    });

    testWidgets('a timer\'s details run it too', (tester) async {
      final panel = await _pump(tester, safety: managed);
      await panel.all(tester);
      await tester.tap(_row('timer|certbot.timer'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Run now'));
      await tester.pumpAndSettle();
      expect(panel.engine.sentOfType<PlanAction>(), hasLength(1));
    });

    testWidgets('observe-only offers none', (tester) async {
      final panel = await _pump(tester, safety: const SafetyPolicy());
      await panel.all(tester);
      expect(
        find.byKey(const ValueKey('jobs.rowActions.timer|certbot.timer')),
        findsNothing,
      );
    });
  });

  group('cron lines (JOB-05, JOB-07, JOB-09, JOB-19, M5 plan M27c)', () {
    const managed = SafetyPolicy(
      servers: {_serverId: ServerSafety(management: true)},
    );

    /// The login user's crontab: a line, a paused one and Dokku's.
    CronResult lines() => cronResultOf(
      CronSnapshot(
        jobs: [
          cronLine('crontab', '*/15 * * * *', '/home/deploy/bin/sync-assets'),
          CronJob(
            source: 'crontab',
            schedule: '0 3 * * *',
            command: '/home/deploy/bin/backup',
            raw:
                '# klabautermann:paused 2026-10-20T00:00:00Z 0 3 * * * '
                '/home/deploy/bin/backup',
            expression: CronExpression.parse('0 3 * * *'),
            paused: true,
          ),
          CronJob(
            source: 'crontab',
            schedule: '0 4 * * *',
            command: 'dokku ps:report',
            raw: '0 4 * * * dokku ps:report',
            expression: CronExpression.parse('0 4 * * *'),
            managedBy: CrontabManager.dokku,
          ),
        ],
        ownCrontabPresent: true,
      ),
    );

    ActionPreview preview() => ActionPreview(
      intent: const RunCronJob(
        _serverId,
        source: 'crontab',
        raw: '*/15 * * * *  /home/deploy/bin/sync-assets',
      ),
      targetName: '/home/deploy/bin/sync-assets',
      steps: [
        ShellStep(['sh', '-c', '/home/deploy/bin/sync-assets']),
      ],
      requiredLevel: RequiredLevel.login,
      runner: const RunnerFacts(identity: 'deploy'),
      requiredTier: ConfirmationTier.acknowledge,
    );

    testWidgets('a line runs now from its row and shows what it printed', (
      tester,
    ) async {
      final panel = await _pump(tester, safety: managed);
      await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
      await panel.sample(tester, SampleStream.cron, lines());

      await tester.tap(
        find.byKey(const ValueKey('jobs.rowActions.cron|crontab|0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run now'));
      await tester.pumpAndSettle();
      final intent =
          (panel.engine.sentOfType<PlanAction>().single as PlanAction).intent
              as RunCronJob;
      expect(
        (intent.source, intent.raw),
        ('crontab', '*/15 * * * *  /home/deploy/bin/sync-assets'),
      );

      await panel.emit(tester, ActionPlanned('plan-1', preview()));
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('Running…'), findsOneWidget);

      await panel.emit(
        tester,
        const ActionFinished(
          planId: 'plan-1',
          outcome: ActionOutcome.succeeded,
          output: ExecOutput(stdout: 'synced 3 files\n', stderr: ''),
        ),
      );
      expect(find.text('It finished with exit status 0.'), findsOneWidget);
      expect(find.text('synced 3 files\n'), findsOneWidget);
    });

    testWidgets('on a phone the details run a line and its output follows', (
      tester,
    ) async {
      final panel = await _pump(tester, size: _phone, safety: managed);
      await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
      await panel.sample(tester, SampleStream.cron, lines());

      await tester.tap(_row('cron|crontab|0'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Run now'));
      await tester.pumpAndSettle();
      await panel.emit(tester, ActionPlanned('plan-1', preview()));
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await panel.emit(
        tester,
        const ActionFinished(
          planId: 'plan-1',
          outcome: ActionOutcome.failed,
          failure: ActionFailure.stepFailed,
          exitCode: 3,
          output: ExecOutput(stdout: '', stderr: 'no route to host\n'),
        ),
      );
      expect(find.text('It finished with exit status 3.'), findsOneWidget);
      expect(find.text('no route to host\n'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed run with no exit status says a step failed', (
      tester,
    ) async {
      final panel = await _pump(tester, size: _phone, safety: managed);
      await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
      await panel.sample(tester, SampleStream.cron, lines());

      await tester.tap(_row('cron|crontab|0'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Run now'));
      await tester.pumpAndSettle();
      await panel.emit(tester, ActionPlanned('plan-1', preview()));
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await panel.emit(
        tester,
        const ActionFinished(
          planId: 'plan-1',
          outcome: ActionOutcome.failed,
          failure: ActionFailure.stepFailed,
        ),
      );
      expect(find.textContaining('did not finish: a step failed.'), findsOne);
      expect(find.textContaining('exit status'), findsNothing);
    });

    testWidgets("a paused line says so and reads no last run; Dokku's line "
        'is badged and offers no run', (tester) async {
      final panel = await _pump(tester, safety: managed);
      await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
      await panel.sample(tester, SampleStream.cron, lines());

      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      // The cells say what the icons show.
      final labels = [
        for (final e in find.byType(Semantics).evaluate())
          ?(e.widget as Semantics).properties.label,
      ];
      expect(labels, contains('Job: /home/deploy/bin/backup, Paused'));
      expect(labels, contains('Job: dokku ps:report, Managed by Dokku'));
      expect(
        find.byKey(const ValueKey('jobs.rowActions.cron|crontab|2')),
        findsNothing,
      );

      await tester.tap(_row('cron|crontab|1'));
      await tester.pumpAndSettle();
      expect(
        _inSheet('Paused: cron skips this line until it is resumed.'),
        findsOneWidget,
      );
      expect(panel.engine.sentOfType<JobHistoryQuery>(), isEmpty);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.tap(_row('cron|crontab|2'));
      await tester.pumpAndSettle();
      expect(
        _inSheet(
          'Dokku manages this line. Change it there; a change here may be '
          'overwritten.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, 'Run now'), findsNothing);
    });

    testWidgets("a line's details read the newest start cron logged for it", (
      tester,
    ) async {
      final panel = await _pump(tester);
      await panel.emit(tester, HostProfileChanged(_serverId, jobsProfile));
      await panel.sample(tester, SampleStream.cron, lines());

      await tester.tap(_row('cron|crontab|0'));
      await tester.pumpAndSettle();
      expect(_inSheet('Reading…'), findsOneWidget);
      final query =
          panel.engine.sentOfType<JobHistoryQuery>().single as JobHistoryQuery;
      expect(query.query, isA<CronRunsQuery>());

      await panel.emit(
        tester,
        JobHistoryResult(
          serverId: _serverId,
          requestId: query.requestId,
          payload: CronRunsPayload([
            LoggedCronRun(
              at: DateTime.utc(2026, 10, 24, 11, 45),
              user: 'deploy',
              command: '/home/deploy/bin/sync-assets',
            ),
            LoggedCronRun(
              at: DateTime.utc(2026, 10, 24, 11, 30),
              user: 'deploy',
              command: '/home/deploy/bin/sync-assets',
            ),
          ]),
        ),
      );
      expect(
        _inSheet(clock('Sat, Oct 24, 2026 1:45 PM UTC+02:00')),
        findsOneWidget,
      );
      expect(
        _inSheet('When cron started it; cron logs no exit status.'),
        findsOneWidget,
      );
    });

    testWidgets("a timer's details read its last trigger and result", (
      tester,
    ) async {
      final panel = await _pump(tester);
      await panel.all(tester);

      await tester.tap(_row('timer|apt-daily.timer'));
      await tester.pumpAndSettle();
      final query =
          panel.engine.sentOfType<JobHistoryQuery>().single as JobHistoryQuery;
      final spec = query.query as TimerLastRunQuery;
      expect(
        (spec.timer, spec.service),
        ('apt-daily.timer', 'apt-daily.service'),
      );

      await panel.emit(
        tester,
        JobHistoryResult(
          serverId: _serverId,
          requestId: query.requestId,
          payload: TimerLastRunPayload(
            TimerLastRun(
              lastTrigger: DateTime.utc(2026, 10, 24, 6, 10),
              result: 'exit-code',
              exitStatus: 2,
            ),
          ),
        ),
      );
      expect(_inSheet('It ended as exit-code, exit status 2.'), findsOneWidget);
    });
  });

  group('other users\' crontabs (JOB-03, M4 E21)', () {
    const managed = SafetyPolicy(
      servers: {_serverId: ServerSafety(management: true)},
    );

    UserCrontabs others(String requestId) {
      final lines = parseUserCrontab(
        '0 3 * * * /usr/local/bin/backup --token=********\n',
        user: 'alice',
      ).value;
      return UserCrontabs(
        serverId: _serverId,
        requestId: requestId,
        directory: '/var/spool/cron/crontabs',
        jobs: mergeJobs(
          cron: CronSnapshot(jobs: lines),
          nowUtc: jobsNow,
          zone: jobsProfile.serverZone,
        ),
        unreadable: const ['carol'],
      );
    }

    testWidgets('admin mode adds the switch, which reads them read-only', (
      tester,
    ) async {
      final panel = await _pump(tester, safety: managed);
      await panel.all(tester);
      expect(find.text('Other users'), findsNothing);

      await panel.emit(
        tester,
        const AdminModeState(_serverId, AdminModePhase.on),
      );
      await tester.tap(find.text('Other users'));
      await tester.pumpAndSettle();
      final request =
          panel.engine.sentOfType<ReadUserCrontabs>().single
              as ReadUserCrontabs;
      expect(find.text("Reading other users' crontabs."), findsOneWidget);

      await panel.emit(tester, others(request.requestId));
      expect(find.text("alice's crontab"), findsOneWidget);
      expect(find.text('Could not read the crontab of carol.'), findsOneWidget);
      expect(
        find.textContaining('/usr/local/bin/backup --token=********'),
        findsWidgets,
      );
      expect(
        find.byKey(
          const ValueKey('jobs.others.rowActions.cron|crontab -u alice|0'),
        ),
        findsNothing,
        reason: 'read-only',
      );

      await tester.tap(find.text('Read again'));
      await tester.pumpAndSettle();
      expect(panel.engine.sentOfType<ReadUserCrontabs>(), hasLength(2));

      // Admin mode that ends takes the view with it.
      await panel.emit(
        tester,
        const AdminModeState(
          _serverId,
          AdminModePhase.expired,
          ended: AdminEnd.inactivity,
        ),
      );
      expect(find.text("alice's crontab"), findsNothing);
      expect(find.text('Other users'), findsNothing);

      // Back on, the tab starts from the streams' rows again.
      await panel.emit(
        tester,
        const AdminModeState(_serverId, AdminModePhase.on),
      );
      expect(find.text("alice's crontab"), findsNothing);
    });

    testWidgets('another server shows none of the last one\'s crontabs', (
      tester,
    ) async {
      final panel = await _pump(tester, safety: managed);
      await panel.all(tester);
      for (final id in [_serverId, 'srv-2']) {
        await panel.emit(tester, AdminModeState(id, AdminModePhase.on));
      }
      await tester.tap(find.text('Other users'));
      await tester.pumpAndSettle();
      final first =
          panel.engine.sentOfType<ReadUserCrontabs>().single
              as ReadUserCrontabs;

      // The desktop selection moves while the read is under way.
      panel.server.value = 'srv-2';
      await tester.pumpAndSettle();
      await panel.emit(tester, others(first.requestId));
      expect(find.text("alice's crontab"), findsNothing);
      expect(find.text("Reading other users' crontabs."), findsNothing);
    });

    testWidgets('a failed read says why', (tester) async {
      final panel = await _pump(tester, safety: managed);
      await panel.all(tester);
      await panel.emit(
        tester,
        const AdminModeState(_serverId, AdminModePhase.on),
      );
      await tester.tap(find.text('Other users'));
      await tester.pumpAndSettle();
      final request =
          panel.engine.sentOfType<ReadUserCrontabs>().single
              as ReadUserCrontabs;
      await panel.emit(
        tester,
        UserCrontabs(
          serverId: _serverId,
          requestId: request.requestId,
          failure: UserCrontabsFailure.spoolDenied,
        ),
      );
      expect(
        find.text('Even admin mode may not list the crontab spool.'),
        findsOneWidget,
      );
    });
  });
}
