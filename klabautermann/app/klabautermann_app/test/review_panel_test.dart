// DKE-06, DKE-07: the Review sub-tab reviews on request and shows the
// containers with findings, the most severe first.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/docker/review_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';

void main() {
  late FakeEngineClient engine;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ReviewPanel(docker: monitoring.docker, serverId: _serverId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<DockerQuery> reviews() => [
    for (final query in engine.sentOfType<DockerQuery>().cast<DockerQuery>())
      if (query.query is DockerReviewQuery) query,
  ];

  testWidgets('nothing is read until asked; then the flagged containers '
      'show, the most severe first', (tester) async {
    await pump(tester);
    expect(reviews(), isEmpty);

    await tester.tap(find.text('Review containers'));
    await tester.pump();
    expect(find.text("Reading each container's configuration…"), findsOne);
    expect(find.text('Review containers'), findsOne, reason: 'no review yet');
    expect(reviews(), hasLength(1));

    engine.emit(
      dockerAnswer(
        reviews().single,
        const DockerReviewPayload(
          [
            ContainerReview(
              containerId: 'a',
              name: 'cache',
              state: 'running',
              findings: [ContainerFinding(ContainerRisk.noHealthcheck)],
            ),
            ContainerReview(
              containerId: 'b',
              name: 'clean',
              state: 'running',
              findings: [],
            ),
            ContainerReview(
              containerId: 'c',
              name: 'agent',
              state: 'running',
              project: 'ops',
              findings: [
                ContainerFinding(
                  ContainerRisk.socketMount,
                  detail: '/var/run/docker.sock',
                ),
                ContainerFinding(ContainerRisk.logsUnrotated),
              ],
            ),
          ],
          omitted: 3,
          unreadable: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Containers with findings: 2 of 3'), findsOne);
    expect(
      find.text(
        '3 more containers were not read: a review reads at most '
        '$kDockerReviewMax.',
      ),
      findsOne,
    );
    expect(
      find.text(
        'The engine refused to inspect 1 container, so it is not reviewed.',
      ),
      findsOne,
    );
    expect(find.text('clean'), findsNothing);
    final agent = tester.getTopLeft(find.text('agent in ops'));
    final cache = tester.getTopLeft(find.text('cache'));
    expect(agent.dy, lessThan(cache.dy), reason: 'high before low');
    expect(find.text('High: Engine socket mounted'), findsOne);
    expect(find.text('/var/run/docker.sock'), findsOne);
    expect(find.text('Medium: Logs never rotate'), findsOne);
    expect(
      find.text(
        'It logs with json-file and no max-size, so its log file grows '
        'until the disk is full.',
      ),
      findsOne,
    );
    expect(find.text('Low: No health check'), findsOne);

    await tester.tap(find.text('Review again'));
    await tester.pump();
    expect(reviews(), hasLength(2));
  });

  testWidgets('a clean engine says so, and a failed review says why', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Review containers'));
    await tester.pump();
    engine.emit(
      dockerAnswer(
        reviews().single,
        const DockerReviewPayload([
          ContainerReview(
            containerId: 'b',
            name: 'clean',
            state: 'running',
            findings: [],
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('The one container carries no finding.'), findsOne);

    await tester.tap(find.text('Review again'));
    await tester.pump();
    engine.emit(
      dockerAnswer(
        reviews().last,
        const DockerQueryFailed(DockerQueryFailure.endpointUnavailable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('The Docker engine cannot be reached.'), findsOne);
  });
}
