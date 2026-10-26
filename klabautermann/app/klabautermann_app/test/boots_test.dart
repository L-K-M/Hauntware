// BOOT-02 and BOOT-03's Boots section: it reads the kernels, the boots
// and their ends one after another when it shows, flags a kernel a
// reboot would load and an unclean end, and reads again on request.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/boots.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

JournalBootEntry _boot(int offset) => JournalBootEntry(
  offset: offset,
  id: ('${-offset}' * 32).substring(0, 32),
  firstEntry: DateTime.utc(2026, 10, 10 + offset, 8),
  lastEntry: DateTime.utc(2026, 10, 10 + offset, 20),
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

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BootsSection(monitoring: monitoring, serverId: _server),
          ),
        ),
      ),
    );
  }

  List<HostQuery> queries() =>
      engine.sentOfType<HostQuery>().cast<HostQuery>().toList();

  /// Answers the last query sent with [payload].
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

  Future<void> answerAll(
    WidgetTester tester, {
    KernelState state = KernelState.newerInstalled,
    HostPayload? ends,
  }) async {
    await answer(
      tester,
      Kernels(
        KernelCheck(
          running: '6.1.0-9-amd64',
          installed: ['6.1.0-9-amd64', '6.1.0-13-amd64'],
          state: state,
        ),
      ),
    );
    await answer(tester, JournalBoots([_boot(-2), _boot(0), _boot(-1)]));
    await answer(
      tester,
      ends ??
          BootEnds({
            _boot(-1).id: BootEnd.unclean,
            _boot(-2).id: BootEnd.clean,
          }),
    );
  }

  testWidgets('it reads one query at a time, flags a kernel a reboot loads, '
      'and lists the boots newest first with how each ended', (tester) async {
    await pump(tester);
    expect(find.text('Reading kernels and boots…'), findsOneWidget);
    expect(queries().single.query, isA<KernelsQuery>());
    expect(queries().single.serverId, _server);

    await answerAll(tester);
    expect(queries().map((q) => q.query.runtimeType), [
      KernelsQuery,
      BootsQuery,
      BootEndsQuery,
    ]);
    expect(find.text('Running kernel 6.1.0-9-amd64'), findsOneWidget);
    expect(
      find.text('Kernel 6.1.0-13-amd64 is installed. A reboot loads it.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.restart_alt), findsOneWidget);

    expect(find.text('This boot'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('This boot')).dy,
      lessThan(tester.getTopLeft(find.text('Previous boot')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Previous boot')).dy,
      lessThan(tester.getTopLeft(find.text('2 boots ago')).dy),
    );
    expect(find.textContaining(', ran 12 hours, 0 minutes'), findsNWidgets(3));
    expect(
      find.text('Ended without a shutdown: a crash, power loss or hard reset'),
      findsOneWidget,
    );
    expect(find.text('Shut down cleanly'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
  });

  testWidgets('a current kernel has no flag, failed ends say so, and Read '
      'again reads everything again', (tester) async {
    await pump(tester);
    await answerAll(
      tester,
      state: KernelState.current,
      ends: const HostQueryFailed(HostQueryFailure.denied),
    );
    expect(find.text('This is the newest kernel installed.'), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt), findsNothing);
    expect(
      find.text('How the earlier boots ended could not be read.'),
      findsOneWidget,
    );
    expect(find.text('Shut down cleanly'), findsNothing);
    // The boots still show, with their ends unknown.
    expect(find.text('Previous boot'), findsOneWidget);

    await tester.tap(find.text('Read again'));
    await tester.pump();
    expect(queries().last.query, isA<KernelsQuery>());
    expect(queries(), hasLength(4));
  });

  testWidgets('a failed kernel check and boot list say why', (tester) async {
    await pump(tester);
    await answer(tester, const HostQueryFailed(HostQueryFailure.noLink));
    expect(find.text('Not connected to the server.'), findsOneWidget);
    await answer(tester, const HostQueryFailed(HostQueryFailure.missing));
    expect(
      find.text('The server has no journal to list boots from.'),
      findsOneWidget,
    );
  });

  test('the timeline keeps the newest boots and leaves the current one '
      'without an end', () {
    final boots = [for (var i = -15; i <= 0; i++) _boot(i)];
    final rows = bootRows(boots, {_boot(0).id: BootEnd.clean});
    expect(rows, hasLength(kBootsListed));
    expect(rows.first.boot.offset, 0);
    expect(rows.first.end, isNull);
    expect(rows.last.boot.offset, 1 - kBootsListed);
  });
}
