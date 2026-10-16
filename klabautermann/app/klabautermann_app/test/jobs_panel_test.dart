import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/jobs_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show CronDirEntry, CronPeriod, OnCalendarElapse;

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';
import 'support/jobs.dart';

const _serverId = 'srv-1';
const _wide = Size(718, 640);
const _phone = Size(390, 844);

final class _Panel {
  _Panel(this.engine);

  final FakeEngineClient engine;

  /// What the monitoring clock reads.
  DateTime now = jobsNow;
  int _seq = 0;

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  Future<void> sample(
    WidgetTester tester,
    SampleStream stream,
    SampleResult result,
  ) => emit(
    tester,
    Sample(
      serverId: _serverId,
      stream: stream,
      seq: ++_seq,
      at: jobsNow,
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
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: RepaintBoundary(
            child: ColoredBox(color: theme.colorScheme.surface, child: child),
          ),
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
}) async {
  final engine = FakeEngineClient();
  final panel = _Panel(engine);
  final monitoring = MonitoringController(engine, now: () => panel.now);
  addTearDown(() async {
    monitoring.dispose();
    await engine.close();
  });
  await _frame(
    tester,
    JobsPanel(monitoring: monitoring, serverId: _serverId, visible: true),
    size: size,
    textScale: textScale,
    brightness: brightness,
  );
  return panel;
}

Finder _row(String id) => find.byKey(ValueKey('jobs.row.$id'));

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
      // Cron's run on Berlin's clock, the timer's at the probed offset.
      'Sun, Oct 25 2:30 AM',
      'Sat, Oct 24 7:41 PM',
      'Mon, Oct 26 9:00 AM in America/New_York',
    ]) {
      expect(find.text(clock(text)), findsWidgets, reason: text);
    }

    // A DST change marks a run with an icon, and in words for screen
    // readers.
    expect(find.bySemanticsLabel(RegExp(r'2:30\sAM \(DST\)')), findsOneWidget);

    // The next job to run leads; unknown runs sort last.
    final order = [
      for (final element in find.byType(Semantics).evaluate())
        if (element.widget.key case ValueKey<String>(
          :final value,
        ) when value.startsWith('jobs.row.'))
          value.substring('jobs.row.'.length),
    ];
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

  testWidgets('only both readings say the server has no job', (tester) async {
    final panel = await _pump(tester);
    const empty = 'No cron jobs or timers on this server.';
    await panel.sample(
      tester,
      SampleStream.cron,
      CronResult(CronSnapshot(ownCrontabPresent: true)),
    );
    expect(find.text(empty), findsNothing);

    await panel.sample(
      tester,
      SampleStream.timers,
      TimersResult(TimersSnapshot()),
    );
    expect(find.text(empty), findsOneWidget);
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
      });
    }
  });

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
      expect(_inSheet('/home/deploy/bin/sync-assets'), findsWidgets);
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
}
