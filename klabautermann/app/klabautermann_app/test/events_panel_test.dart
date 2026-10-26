// DKE-03: the Docker tab's Events sub-tab over the events watch, newest
// first, filtered by type and searched, with a marker where the stream
// was lost.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/docker/events_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _serverId = 'srv-1';

final _die = DockerTimelineEvent(
  at: DateTime.utc(2026, 10, 26, 12),
  type: 'container',
  action: 'die',
  actorId: 'abc',
  name: 'web',
  image: 'nginx:1',
  exitCode: 137,
);
final _gap = DockerTimelineGap(
  at: DateTime.utc(2026, 10, 26, 12, 1),
  until: DateTime.utc(2026, 10, 26, 12, 5),
  resumed: true,
);
final _pull = DockerTimelineEvent(
  at: DateTime.utc(2026, 10, 26, 12, 6),
  type: 'image',
  action: 'pull',
  name: 'redis:7',
);

DockerListChanged _timeline(List<DockerTimelineEntry> entries) =>
    DockerListChanged(
      serverId: _serverId,
      list: DockerWatchList.events,
      payload: DockerEventsPayload(entries),
      at: DateTime.utc(2026, 10, 26, 12, 7),
    );

void main() {
  test('rows are newest first; a filter keeps the gaps', () {
    final entries = [_die, _gap, _pull];
    expect(timelineRows(entries), [_pull, _gap, _die]);
    expect(timelineRows(entries, kind: DockerEventKind.container), [
      _gap,
      _die,
    ]);
    expect(timelineRows(entries, terms: ['nginx']), [_gap, _die]);
    expect(timelineRows(entries, terms: ['redis', 'pull']), [_pull, _gap]);
  });

  late FakeEngineClient engine;
  late MonitoringController monitoring;
  late ValueNotifier<bool> visible;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
    visible = ValueNotifier(true);
  });

  tearDown(() async {
    monitoring.dispose();
    visible.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: visible,
            builder: (context, shows, _) => EventsPanel(
              monitoring: monitoring,
              serverId: _serverId,
              visible: shows,
              now: () => DateTime.utc(2026, 10, 26, 12, 30),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<DockerWatch> watches() =>
      engine.sentOfType<DockerWatch>().cast<DockerWatch>().toList();

  testWidgets('watches the events while it shows and lists them', (
    tester,
  ) async {
    await pump(tester);
    expect(watches().single.lists, {DockerWatchList.events});
    expect(find.text('Waiting for the events stream…'), findsOneWidget);

    engine.emit(_timeline(const []));
    await tester.pumpAndSettle();
    expect(find.textContaining('No events yet.'), findsOneWidget);

    engine.emit(_timeline([_die, _gap, _pull]));
    await tester.pumpAndSettle();
    expect(find.text('web: die'), findsOneWidget);
    expect(find.textContaining('image nginx:1'), findsOneWidget);
    expect(find.textContaining('exit code 137'), findsOneWidget);
    expect(find.text('redis:7: pull'), findsOneWidget);
    expect(
      find.textContaining('The engine sent the events it still held'),
      findsOneWidget,
    );
    // Newest first.
    expect(
      tester.getTopLeft(find.text('redis:7: pull')).dy,
      lessThan(tester.getTopLeft(find.text('web: die')).dy),
    );

    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    expect(find.text('web: die'), findsNothing);
    expect(find.text('redis:7: pull'), findsOneWidget);

    await tester.tap(find.text('All'));
    await tester.enterText(find.byType(TextField), 'postgres');
    await tester.pumpAndSettle();
    expect(find.text('No event matches the filter.'), findsNothing);
    // The gap stays, so the list is not empty.
    expect(find.text('web: die'), findsNothing);

    visible.value = false;
    await tester.pumpAndSettle();
    expect(
      engine.sentOfType<DockerUnwatch>().cast<DockerUnwatch>().single.watchId,
      watches().single.watchId,
    );

    // Shown again, it watches again and keeps the last timeline meanwhile.
    visible.value = true;
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(watches(), hasLength(2));
    expect(find.text('redis:7: pull'), findsOneWidget);
  });

  testWidgets('a row from another day shows its date', (tester) async {
    await pump(tester);
    final old = DockerTimelineEvent(
      at: DateTime.utc(2026, 10, 20, 12),
      type: 'container',
      action: 'start',
      name: 'db',
    );
    engine.emit(_timeline([old, _pull]));
    await tester.pumpAndSettle();
    expect(find.textContaining('Oct 20, 2026'), findsOneWidget);
    expect(find.textContaining('Oct 26, 2026'), findsNothing);
  });

  testWidgets('a failed watch says why and can be tried again', (tester) async {
    await pump(tester);
    engine.emit(
      DockerListChanged(
        serverId: _serverId,
        list: DockerWatchList.events,
        payload: const DockerQueryFailed(DockerQueryFailure.connectionFailed),
        at: DateTime.utc(2026, 10, 26, 12),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The connection to the engine failed while following its events.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(watches(), hasLength(2));
  });
}
