// MEM-03: the System tab's out-of-memory kills, counted since boot, named
// newest first and linked to their reports in the kernel log.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/oom_kills.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

OomKillsRead _read({
  int? count = 2,
  OomLogSource source = OomLogSource.journal,
  bool logRead = true,
  List<OomKill> kills = const [],
}) => OomKillsRead(
  killsSinceBoot: count,
  source: source,
  logRead: logRead,
  kills: kills,
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

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: OomKillsSection(monitoring: monitoring, serverId: _server),
        ),
      ),
    ),
  );

  List<HostQuery> queries() =>
      engine.sentOfType<HostQuery>().cast<HostQuery>().toList();

  Future<void> answer(WidgetTester tester, HostPayload payload) async {
    engine.emit(
      HostResult(
        serverId: _server,
        queryId: queries().last.queryId,
        payload: payload,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('counts the kills since boot and names them newest first', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Reading the kernel\'s out-of-memory kills.'), findsOne);
    expect(queries().single.query, isA<OomKillsQuery>());

    await answer(
      tester,
      OomKills(
        _read(
          kills: [
            OomKill(
              pid: 4321,
              command: 'stress',
              at: DateTime(2026, 10, 26, 3, 12),
              anonRssKb: 2 * 1024 * 1024,
              cgroup: '/user.slice/user-1000.slice/session-3.scope',
            ),
            OomKill(
              pid: 777,
              command: 'java',
              at: DateTime(2026, 10, 26, 4, 30),
              cgroupLimit: true,
            ),
          ],
        ),
      ),
    );
    expect(
      find.text('2 processes were killed for lack of memory since boot.'),
      findsOneWidget,
    );
    expect(find.text('stress (PID 4321)'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'^Killed Oct 26, 2026 3:12\sAM$')),
      findsOneWidget,
    );
    expect(find.text('2 GiB of its own memory when killed'), findsOneWidget);
    expect(
      find.text('/user.slice/user-1000.slice/session-3.scope'),
      findsOneWidget,
    );
    expect(find.textContaining('A memory limit ran out'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('java (PID 777)')).dy,
      lessThan(tester.getTopLeft(find.text('stress (PID 4321)')).dy),
    );

    await tester.tap(find.text('Read again'));
    await tester.pump();
    expect(queries(), hasLength(2));
    await answer(tester, OomKills(_read(count: 0)));
    expect(
      find.text('No process was killed for lack of memory since boot.'),
      findsOneWidget,
    );
    expect(find.text('Show in kernel log'), findsNothing);
  });

  testWidgets('links to the reports in the current boot\'s kernel log', (
    tester,
  ) async {
    await pump(tester);
    await answer(
      tester,
      OomKills(_read(kills: const [OomKill(pid: 1, command: 'a')])),
    );
    await tester.tap(find.text('Show in kernel log'));
    await tester.pumpAndSettle();

    expect(find.text('Out-of-memory reports'), findsOneWidget);
    final open = engine.sentOfType<OpenLogStream>().cast<OpenLogStream>().last;
    final source = open.spec.source as JournalLogSource;
    expect(source.identifier, 'kernel');
    expect(source.currentBootOnly, isTrue);
    expect(source.grep, '(?i)$kOomLogPattern');
  });

  testWidgets('dmesg kills count from boot, and an unreadable log, an old '
      'kernel and a failed read say so', (tester) async {
    await pump(tester);
    await answer(
      tester,
      OomKills(
        _read(
          source: OomLogSource.dmesg,
          kills: const [
            OomKill(pid: 9, command: 'x', sinceBoot: Duration(hours: 5)),
          ],
        ),
      ),
    );
    expect(find.text('Killed 5 hours, 0 minutes after boot'), findsOneWidget);
    // dmesg's lines have no journal entries to show.
    expect(find.text('Show in kernel log'), findsNothing);

    await tester.tap(find.text('Read again'));
    await tester.pump();
    await answer(tester, OomKills(_read(count: null, logRead: false)));
    expect(find.textContaining('does not count out-of-memory'), findsOne);
    expect(find.textContaining('may not read the kernel log'), findsOne);

    await tester.tap(find.text('Read again'));
    await tester.pump();
    await answer(tester, const HostQueryFailed(HostQueryFailure.noLink));
    expect(find.textContaining('Not connected'), findsOneWidget);
  });
}
