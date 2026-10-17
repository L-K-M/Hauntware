import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/docker_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

/// 03 §5.9, §10.1: the app asks for each server's Docker endpoint as its
/// link comes up, keeps what the engine reports, and reads the engine's
/// details for a Docker tab that shows a ready endpoint.
void main() {
  late FakeEngineClient engine;
  late DockerController docker;

  setUp(() {
    engine = FakeEngineClient();
    docker = DockerController(engine);
  });

  tearDown(() async {
    docker.dispose();
    await engine.close();
  });

  List<DockerQuery> queries() => engine.sentOfType<DockerQuery>().cast();

  Future<void> emit(EngineEvent event) async {
    engine.emit(event);
    await pumpEventQueue();
  }

  test('asks for the endpoint each time a link comes up', () async {
    await emit(const LinkState('srv-1', LinkConnecting()));
    expect(queries(), isEmpty, reason: 'no link yet');

    await emit(const LinkState('srv-1', LinkReady()));
    expect(queries(), hasLength(1));
    expect(queries().single.serverId, 'srv-1');
    expect(queries().single.query, isA<DockerEngineQuery>());

    // The engine follows the link from here; the query is still in flight
    // anyway.
    await emit(const LinkState('srv-1', LinkReady()));
    await emit(
      dockerAnswer(
        queries().last,
        const DockerQueryFailed(DockerQueryFailure.profileUnknown),
      ),
    );
    await emit(const LinkState('srv-1', LinkReady()));
    expect(queries(), hasLength(1), reason: 'the link stayed up');

    // The app let the link go, which ended the session in the engine.
    await emit(const LinkState('srv-1', LinkIdle()));
    await emit(const LinkState('srv-1', LinkReady()));
    expect(queries(), hasLength(2));
    expect(
      queries().map((query) => query.queryId).toSet(),
      hasLength(2),
      reason: 'ids are never reused',
    );
  });

  test('keeps each server\'s endpoint state', () async {
    final endpoint = docker.endpointFor('srv-1');
    expect(endpoint.value, isNull);

    await emit(dockerReady('srv-1', rank: DockerRank.cliRelay));
    expect(endpoint.value?.label, DockerRouteLabel.cliRelay);
    expect(docker.endpointFor('srv-2').value, isNull);

    await emit(
      const DockerEndpointState(
        serverId: 'srv-1',
        phase: DockerEndpointPhase.failed,
        failure: DockerEndpointFailure.noRoute,
        noRouteReason: DockerNoRouteReason.noRelay,
      ),
    );
    expect(endpoint.value?.phase, DockerEndpointPhase.failed);
    expect(endpoint.value?.label, DockerRouteLabel.none);
  });

  test('reads the engine details once a shown tab\'s endpoint is ready, '
      'and again after the route changes', () async {
    docker.openView('srv-1');
    expect(queries(), isEmpty, reason: 'no endpoint yet');

    await emit(dockerReady('srv-1'));
    expect(queries(), hasLength(1));
    await emit(dockerReady('srv-1'));
    expect(queries(), hasLength(1), reason: 'one in flight at a time');

    await emit(dockerAnswer(queries().last, dockerEngine()));
    expect(docker.engineFor('srv-1').value, isA<DockerEnginePayload>());

    // The same endpoint again reads nothing.
    await emit(dockerReady('srv-1'));
    docker
      ..closeView('srv-1')
      ..openView('srv-1');
    expect(queries(), hasLength(1));

    // A new route clears what the old one read.
    await emit(dockerReady('srv-1', rank: DockerRank.socketRelay));
    expect(docker.engineFor('srv-1').value, isNull);
    expect(queries(), hasLength(2));
  });

  test('a hidden tab reads nothing until it shows', () async {
    await emit(dockerReady('srv-1'));
    expect(queries(), isEmpty);

    docker.openView('srv-1');
    expect(queries(), hasLength(1));

    docker.closeView('srv-1');
    await emit(dockerReady('srv-1', rank: DockerRank.cliRelay));
    await emit(dockerAnswer(queries().last, dockerEngine()));
    expect(queries(), hasLength(1));
  });

  test('a failed read is kept and read again on retry or when the tab '
      'shows again', () async {
    docker.openView('srv-1');
    await emit(dockerReady('srv-1'));
    await emit(
      dockerAnswer(
        queries().last,
        const DockerQueryFailed(DockerQueryFailure.daemonError),
      ),
    );
    expect(docker.engineFor('srv-1').value, isA<DockerQueryFailed>());

    docker.retry('srv-1');
    expect(queries(), hasLength(2));
    await emit(
      dockerAnswer(
        queries().last,
        const DockerQueryFailed(DockerQueryFailure.connectionFailed),
      ),
    );

    docker
      ..closeView('srv-1')
      ..openView('srv-1');
    expect(queries(), hasLength(3));
  });

  test('an answer for no ready endpoint leaves the details to the endpoint '
      'state', () async {
    await emit(const LinkState('srv-1', LinkReady()));
    for (final failure in [
      DockerQueryFailure.linkUnavailable,
      DockerQueryFailure.profileUnknown,
      DockerQueryFailure.endpointUnavailable,
      DockerQueryFailure.cancelled,
    ]) {
      docker.retry('srv-1');
      await emit(dockerAnswer(queries().last, DockerQueryFailed(failure)));
      expect(docker.engineFor('srv-1').value, isNull, reason: failure.name);
    }
  });

  test('a failed endpoint is asked again on retry', () async {
    await emit(
      const DockerEndpointState(
        serverId: 'srv-1',
        phase: DockerEndpointPhase.failed,
        failure: DockerEndpointFailure.unreachable,
      ),
    );
    docker.openView('srv-1');
    expect(queries(), isEmpty, reason: 'a failure stands until asked');

    docker.retry('srv-1');
    expect(queries(), hasLength(1));
  });

  test('ignores answers it did not ask for', () async {
    docker.openView('srv-1');
    await emit(dockerReady('srv-1'));
    await emit(
      DockerResult(
        serverId: 'srv-1',
        queryId: 'someone-else',
        payload: dockerEngine(),
      ),
    );
    expect(docker.engineFor('srv-1').value, isNull);
  });

  test('a server that leaves the fleet takes its state with it '
      '(SYN-08)', () async {
    docker.openView('srv-1');
    await emit(dockerReady('srv-1'));
    final inFlight = queries().last;
    final before = docker.endpointFor('srv-1');

    await emit(CatalogReplaced(const []));
    expect(docker.endpointFor('srv-1'), isNot(same(before)));
    expect(docker.endpointFor('srv-1').value, isNull);

    // Late news of it stays out.
    await emit(dockerAnswer(inFlight, dockerEngine()));
    await emit(dockerReady('srv-1'));
    await emit(const LinkState('srv-1', LinkReady()));
    expect(docker.engineFor('srv-1').value, isNull);
    expect(docker.endpointFor('srv-1').value, isNull);
    expect(queries(), hasLength(1));
  });

  test('sends nothing once the engine stopped', () async {
    await emit(dockerReady('srv-1'));
    await engine.close();
    await pumpEventQueue();
    docker
      ..openView('srv-1')
      ..retry('srv-1');
    expect(queries(), isEmpty);
  });

  group('the container watch (CTR-01, CST-01)', () {
    final at = DateTime(2026, 10, 15, 14, 30);

    List<DockerWatch> watches() => engine.sentOfType<DockerWatch>().cast();
    List<DockerUnwatch> unwatches() =>
        engine.sentOfType<DockerUnwatch>().cast();

    ContainerListStats stats(String id, double cpu) => ContainerListStats(
      containerId: id,
      at: at,
      cpuPercent: cpu,
      memoryUsed: 64 << 20,
    );

    test('one watch per server while any view shows, replaced as the rows '
        'on screen change', () async {
      docker.watchContainers('srv-1');
      expect(watches(), hasLength(1));
      final first = watches().single;
      expect(first.serverId, 'srv-1');
      expect(first.lists, {DockerWatchList.containers, DockerWatchList.stats});
      expect(first.statsFor, isEmpty);

      // A second view shares it.
      docker.watchContainers('srv-1', statsFor: ['c-9']);
      expect(watches(), hasLength(1));

      docker.showStatsFor('srv-1', ['c-1', 'c-2']);
      expect(watches(), hasLength(2));
      expect(watches().last.watchId, first.watchId, reason: 'replaces it');
      expect(watches().last.statsFor, {'c-1', 'c-2'});

      docker.showStatsFor('srv-1', ['c-2', 'c-1']);
      expect(watches(), hasLength(2), reason: 'the same rows');

      // No more than the engine reads.
      docker.showStatsFor('srv-1', [for (var i = 0; i < 80; i++) 'c-$i']);
      expect(watches().last.statsFor, hasLength(kDockerStatsForMax));
      expect(watches().last.statsFor, contains('c-0'));
      expect(watches().last.statsFor, isNot(contains('c-79')));

      docker.unwatchContainers('srv-1');
      expect(unwatches(), isEmpty, reason: 'a view still shows');
      docker.unwatchContainers('srv-1');
      expect(unwatches().single.watchId, first.watchId);
      expect(unwatches().single.serverId, 'srv-1');
      docker.unwatchContainers('srv-1');
      expect(unwatches(), hasLength(1));

      // Hidden, rows on screen change nothing; a new view watches anew
      // with the rows it shows.
      docker.showStatsFor('srv-1', ['c-3']);
      final sent = watches().length;
      docker.watchContainers('srv-1', statsFor: ['c-3']);
      expect(watches(), hasLength(sent + 1));
      expect(watches().last.watchId, isNot(first.watchId));
      expect(watches().last.statsFor, {'c-3'});
    });

    test('keeps the latest containers and stats, and a failed read beside '
        'the last list', () async {
      docker.watchContainers('srv-1');
      final list = docker.containersFor('srv-1');
      expect(list.value.containers, isNull);

      await emit(
        dockerContainerList('srv-1', [
          dockerContainer('c-1'),
          dockerContainer('c-2'),
        ], at: at),
      );
      expect(list.value.containers, hasLength(2));
      expect(list.value.at, at);

      await emit(
        dockerStatsRound('srv-1', [stats('c-1', 5), stats('c-2', 7)], at: at),
      );
      await emit(dockerStatsRound('srv-1', [stats('c-1', 9)], at: at));
      expect(list.value.stats['c-1']?.cpuPercent, 9);
      expect(
        list.value.stats['c-2']?.cpuPercent,
        7,
        reason: 'a row off screen keeps its last stats',
      );

      await emit(
        dockerListFailed(
          'srv-1',
          DockerWatchList.stats,
          DockerQueryFailure.connectionFailed,
          at: at,
        ),
      );
      expect(
        list.value.statsFailure?.failure,
        DockerQueryFailure.connectionFailed,
      );
      expect(list.value.stats, hasLength(2));

      await emit(
        dockerListFailed(
          'srv-1',
          DockerWatchList.containers,
          DockerQueryFailure.daemonError,
          at: at,
          detail: 'Error response from daemon',
        ),
      );
      expect(list.value.failure?.failure, DockerQueryFailure.daemonError);
      expect(list.value.failure?.detail, 'Error response from daemon');
      expect(list.value.containers, hasLength(2));

      // A container that went takes its stats along.
      await emit(
        dockerContainerList('srv-1', [dockerContainer('c-1')], at: at),
      );
      expect(list.value.failure, isNull);
      expect(list.value.stats.keys, ['c-1']);
      await emit(dockerStatsRound('srv-1', [stats('c-1', 1)], at: at));
      expect(list.value.statsFailure, isNull);

      // Other lists and servers leave it be.
      await emit(
        DockerListChanged(
          serverId: 'srv-1',
          list: DockerWatchList.images,
          payload: const DockerImagesPayload([]),
          at: at,
        ),
      );
      await emit(dockerContainerList('srv-2', const [], at: at));
      expect(list.value.containers, hasLength(1));
    });

    test('a retry watches anew under a new id', () async {
      docker.watchContainers('srv-1');
      docker.showStatsFor('srv-1', ['c-1']);
      final before = watches().last;
      await emit(
        dockerListFailed(
          'srv-1',
          DockerWatchList.containers,
          DockerQueryFailure.tooManyQueries,
          at: at,
        ),
      );

      docker.retryContainers('srv-1');
      expect(unwatches().single.watchId, before.watchId);
      expect(watches().last.watchId, isNot(before.watchId));
      expect(watches().last.statsFor, {'c-1'});
    });

    test('a server that leaves the fleet drops its watch and lists '
        '(SYN-08)', () async {
      docker.watchContainers('srv-1');
      await emit(
        dockerContainerList('srv-1', [dockerContainer('c-1')], at: at),
      );
      final before = docker.containersFor('srv-1');

      await emit(CatalogReplaced(const []));
      expect(docker.containersFor('srv-1'), isNot(same(before)));
      expect(docker.containersFor('srv-1').value.containers, isNull);

      // The engine ended the watch with the session: nothing to end.
      docker.unwatchContainers('srv-1');
      docker.watchContainers('srv-1');
      expect(unwatches(), isEmpty);
      expect(watches(), hasLength(1), reason: 'not in the fleet');
    });

    test('sends nothing once the engine stopped', () async {
      await engine.close();
      await pumpEventQueue();
      docker
        ..watchContainers('srv-1')
        ..showStatsFor('srv-1', ['c-1'])
        ..unwatchContainers('srv-1');
      expect(watches(), isEmpty);
      expect(unwatches(), isEmpty);
    });
  });

  group('the image watch (IMG-01)', () {
    final at = DateTime(2026, 10, 15, 14, 30);

    List<DockerWatch> watches() => engine.sentOfType<DockerWatch>().cast();
    List<DockerUnwatch> unwatches() =>
        engine.sentOfType<DockerUnwatch>().cast();

    test('one watch per server while any view shows, with the containers, '
        'apart from the container watch', () async {
      docker.watchContainers('srv-1');
      docker.watchImages('srv-1');
      expect(watches(), hasLength(2));
      final images = watches().last;
      expect(images.serverId, 'srv-1');
      expect(images.lists, {
        DockerWatchList.images,
        DockerWatchList.containers,
      });
      expect(images.watchId, isNot(watches().first.watchId));

      // A second view shares it.
      docker.watchImages('srv-1');
      expect(watches(), hasLength(2));
      docker.unwatchImages('srv-1');
      expect(unwatches(), isEmpty, reason: 'a view still shows');
      docker.unwatchImages('srv-1');
      expect(unwatches().single.watchId, images.watchId);
      docker.unwatchImages('srv-1');
      expect(unwatches(), hasLength(1));

      // The container watch is the Containers view's.
      docker.showStatsFor('srv-1', ['c-1']);
      expect(watches().last.watchId, watches().first.watchId);

      docker.watchImages('srv-1');
      expect(watches().last.watchId, isNot(images.watchId));
    });

    test(
      'keeps the latest images, and a failed read beside the last list',
      () async {
        docker.watchImages('srv-1');
        final list = docker.imagesFor('srv-1');
        expect(list.value.images, isNull);

        await emit(
          dockerImageList('srv-1', [
            dockerImage('sha256:aa', tags: ['nginx:1.27']),
          ], at: at),
        );
        expect(list.value.images, hasLength(1));
        expect(list.value.at, at);

        await emit(
          dockerListFailed(
            'srv-1',
            DockerWatchList.images,
            DockerQueryFailure.daemonError,
            at: at.add(const Duration(minutes: 1)),
            detail: 'Error response from daemon',
          ),
        );
        expect(list.value.failure?.failure, DockerQueryFailure.daemonError);
        expect(list.value.failure?.detail, 'Error response from daemon');
        expect(list.value.images, hasLength(1));
        expect(list.value.at, at, reason: 'when the kept list was read');

        // The containers it watches too go where the Containers view reads.
        await emit(
          dockerContainerList('srv-1', [dockerContainer('c-1')], at: at),
        );
        expect(docker.containersFor('srv-1').value.containers, hasLength(1));
        expect(list.value.images, hasLength(1));

        await emit(dockerImageList('srv-1', const [], at: at));
        expect(list.value.images, isEmpty);
        expect(list.value.failure, isNull);

        // Another server's list leaves it be.
        await emit(
          dockerImageList('srv-2', [dockerImage('sha256:bb')], at: at),
        );
        expect(list.value.images, isEmpty);
      },
    );

    test('a retry watches anew under a new id', () async {
      docker.watchImages('srv-1');
      final before = watches().single;
      docker.retryImages('srv-2');
      expect(unwatches(), isEmpty, reason: 'nothing watched there');

      docker.retryImages('srv-1');
      expect(unwatches().single.watchId, before.watchId);
      expect(watches().last.watchId, isNot(before.watchId));
      expect(watches().last.lists, before.lists);
    });

    test('a server that leaves the fleet drops its watch and images '
        '(SYN-08)', () async {
      docker.watchImages('srv-1');
      await emit(dockerImageList('srv-1', [dockerImage('sha256:aa')], at: at));
      final before = docker.imagesFor('srv-1');

      await emit(CatalogReplaced(const []));
      expect(docker.imagesFor('srv-1'), isNot(same(before)));
      expect(docker.imagesFor('srv-1').value.images, isNull);

      docker.unwatchImages('srv-1');
      docker.watchImages('srv-1');
      expect(unwatches(), isEmpty);
      expect(watches(), hasLength(1), reason: 'not in the fleet');
    });

    test('sends nothing once the engine stopped', () async {
      await engine.close();
      await pumpEventQueue();
      docker
        ..watchImages('srv-1')
        ..retryImages('srv-1')
        ..unwatchImages('srv-1');
      expect(watches(), isEmpty);
      expect(unwatches(), isEmpty);
    });
  });

  group('the stack watch (STK-01, STK-05)', () {
    final at = DateTime(2026, 10, 15, 14, 30);

    List<DockerWatch> watches() => engine.sentOfType<DockerWatch>().cast();
    List<DockerUnwatch> unwatches() =>
        engine.sentOfType<DockerUnwatch>().cast();

    ComposeProject web() => dockerStack('web', [
      dockerService('app', [dockerContainer('c-1', project: 'web')]),
    ]);

    test('one watch of the stacks alone per server while any view shows, '
        'apart from the other watches', () async {
      docker.watchContainers('srv-1');
      docker.watchImages('srv-1');
      docker.watchStacks('srv-1');
      expect(watches(), hasLength(3));
      final stacks = watches().last;
      expect(stacks.serverId, 'srv-1');
      expect(stacks.lists, {DockerWatchList.stacks});
      expect(stacks.statsFor, isEmpty);
      expect({for (final watch in watches()) watch.watchId}, hasLength(3));

      // A second view shares it: asking again would run the checks again.
      docker.watchStacks('srv-1');
      expect(watches(), hasLength(3));
      docker.unwatchStacks('srv-1');
      expect(unwatches(), isEmpty, reason: 'a view still shows');
      docker.unwatchStacks('srv-1');
      expect(unwatches().single.watchId, stacks.watchId);
      docker.unwatchStacks('srv-1');
      expect(unwatches(), hasLength(1));

      docker.watchStacks('srv-1');
      expect(watches().last.watchId, isNot(stacks.watchId));
    });

    test('keeps the latest stacks as their verdicts arrive, and a failed '
        'read beside the last list', () async {
      docker.watchStacks('srv-1');
      final list = docker.stacksFor('srv-1');
      expect(list.value.stacks, isNull);

      await emit(dockerStackList('srv-1', [web()], at: at));
      expect(list.value.stacks?.grouping.projects.single.name, 'web');
      expect(list.value.stacks?.verdicts, isEmpty);
      expect(list.value.at, at);

      // The engine sends the list again once it checked the project.
      await emit(
        dockerStackList(
          'srv-1',
          [web()],
          at: at,
          verdicts: const {'web': StackVerified()},
          cli: const DockerComposeCli(pluginVersion: '2.29.7'),
        ),
      );
      expect(list.value.stacks?.verdicts['web'], isA<StackVerified>());
      expect(list.value.stacks?.composeCli?.pluginVersion, '2.29.7');

      await emit(
        dockerListFailed(
          'srv-1',
          DockerWatchList.stacks,
          DockerQueryFailure.connectionFailed,
          at: at.add(const Duration(minutes: 1)),
        ),
      );
      expect(list.value.failure?.failure, DockerQueryFailure.connectionFailed);
      expect(list.value.stacks?.grouping.projects, hasLength(1));
      expect(list.value.at, at, reason: 'when the kept list was read');

      // Other lists and servers leave it be.
      await emit(dockerImageList('srv-1', const [], at: at));
      await emit(dockerStackList('srv-2', const [], at: at));
      expect(list.value.stacks?.grouping.projects, hasLength(1));
      expect(docker.containersFor('srv-1').value.containers, isNull);

      await emit(dockerStackList('srv-1', const [], at: at));
      expect(list.value.stacks?.grouping.projects, isEmpty);
      expect(list.value.failure, isNull);
    });

    test('details views follow the containers the stacks carry', () async {
      docker.watchStacks('srv-1');
      await emit(dockerStackList('srv-1', [web()], at: at));
      final details = docker.openContainer('srv-1', 'c-1');
      final inspect = queries().last;
      await emit(
        dockerAnswer(
          inspect,
          DockerContainerPayload(dockerContainerDetails('c-1')),
        ),
      );
      expect(details.value.removed, isFalse);

      await emit(dockerStackList('srv-1', const [], at: at));
      expect(details.value.removed, isTrue);
      docker.closeContainer('srv-1', 'c-1');
    });

    test('a retry watches anew under a new id', () async {
      docker.watchStacks('srv-1');
      final before = watches().single;
      docker.retryStacks('srv-2');
      expect(unwatches(), isEmpty, reason: 'nothing watched there');

      docker.retryStacks('srv-1');
      expect(unwatches().single.watchId, before.watchId);
      expect(watches().last.watchId, isNot(before.watchId));
      expect(watches().last.lists, before.lists);
    });

    test('a server that leaves the fleet drops its watch and stacks '
        '(SYN-08)', () async {
      docker.watchStacks('srv-1');
      await emit(dockerStackList('srv-1', [web()], at: at));
      final before = docker.stacksFor('srv-1');

      await emit(CatalogReplaced(const []));
      expect(docker.stacksFor('srv-1'), isNot(same(before)));
      expect(docker.stacksFor('srv-1').value.stacks, isNull);

      docker.unwatchStacks('srv-1');
      docker.watchStacks('srv-1');
      expect(unwatches(), isEmpty);
      expect(watches(), hasLength(1), reason: 'not in the fleet');
    });

    test('sends nothing once the engine stopped', () async {
      await engine.close();
      await pumpEventQueue();
      docker
        ..watchStacks('srv-1')
        ..retryStacks('srv-1')
        ..unwatchStacks('srv-1');
      expect(watches(), isEmpty);
      expect(unwatches(), isEmpty);
    });
  });

  group('container details (CTR-03, CTR-04)', () {
    final at = DateTime(2026, 10, 15, 14, 30);

    List<DockerQuery> inspects() => [
      for (final query in queries())
        if (query.query is DockerContainerQuery) query,
    ];

    String containerOf(DockerQuery query) =>
        (query.query as DockerContainerQuery).containerId;

    test('one inspect per container while any view shows it, shared by '
        'its views', () async {
      final details = docker.openContainer('srv-1', 'c-1');
      expect(inspects(), hasLength(1));
      expect(containerOf(inspects().single), 'c-1');
      expect(details.value.container, isNull);
      expect(details.value.failure, isNull);

      expect(docker.openContainer('srv-1', 'c-1'), same(details));
      expect(inspects(), hasLength(1), reason: 'the first view reads');

      await emit(
        dockerAnswer(
          inspects().single,
          DockerContainerPayload(dockerContainerDetails('c-1')),
        ),
      );
      expect(details.value.container?.id, 'c-1');

      // The last view to close lets them go; an answer after that, or
      // for another query, changes nothing.
      docker.closeContainer('srv-1', 'c-1');
      docker.closeContainer('srv-1', 'c-1');
      final again = docker.openContainer('srv-1', 'c-1');
      expect(again, isNot(same(details)));
      expect(inspects(), hasLength(2));
      expect(
        inspects().map((query) => query.queryId).toSet(),
        hasLength(2),
        reason: 'ids are never reused',
      );
      await emit(
        dockerAnswer(
          inspects().first,
          DockerContainerPayload(dockerContainerDetails('c-1')),
        ),
      );
      expect(again.value.container, isNull);
    });

    test('a container the engine cannot find was removed, and keeps what '
        'was read', () async {
      final details = docker.openContainer('srv-1', 'c-1');
      await emit(
        dockerAnswer(
          inspects().single,
          DockerContainerPayload(dockerContainerDetails('c-1')),
        ),
      );
      docker.retryContainer('srv-1', 'c-1');
      await emit(
        dockerAnswer(
          inspects().last,
          const DockerQueryFailed(DockerQueryFailure.notFound),
        ),
      );
      expect(details.value.removed, isTrue);
      expect(details.value.failure, isNull);
      expect(details.value.container?.id, 'c-1');
    });

    test('a failure is kept beside the last read and read again on '
        'retry', () async {
      final details = docker.openContainer('srv-1', 'c-1');
      await emit(
        dockerAnswer(
          inspects().single,
          const DockerQueryFailed(
            DockerQueryFailure.daemonError,
            detail: 'Error response from daemon',
          ),
        ),
      );
      expect(details.value.failure?.failure, DockerQueryFailure.daemonError);
      expect(details.value.failure?.detail, 'Error response from daemon');

      docker.retryContainer('srv-1', 'c-1');
      expect(inspects(), hasLength(2));
      await emit(
        dockerAnswer(
          inspects().last,
          DockerContainerPayload(dockerContainerDetails('c-1')),
        ),
      );
      expect(details.value.failure, isNull);
      expect(details.value.container, isNotNull);
    });

    test('a read that failed on the endpoint runs again once it is ready '
        'on a new route', () async {
      await emit(dockerReady('srv-1'));
      final details = docker.openContainer('srv-1', 'c-1');
      await emit(
        dockerAnswer(
          inspects().single,
          const DockerQueryFailed(DockerQueryFailure.cancelled),
        ),
      );
      expect(details.value.failure?.failure, DockerQueryFailure.cancelled);

      await emit(dockerReady('srv-1'));
      expect(inspects(), hasLength(1), reason: 'the same route');

      await emit(dockerReady('srv-1', rank: DockerRank.cliRelay));
      expect(inspects(), hasLength(2));
    });

    test('follows the container through the lists: a changed row is read '
        'again, once at a time, and a missing one was removed', () async {
      docker.watchContainers('srv-1');
      await emit(
        dockerContainerList('srv-1', [
          dockerContainer('c-1', status: 'Up 2 hours'),
          dockerContainer('c-2'),
        ], at: at),
      );
      final details = docker.openContainer('srv-1', 'c-1');
      expect(inspects(), hasLength(1));

      // Another container changed; this one did not.
      await emit(
        dockerContainerList('srv-1', [
          dockerContainer('c-1', status: 'Up 2 hours'),
          dockerContainer('c-2', state: 'exited'),
        ], at: at),
      );
      expect(inspects(), hasLength(1));

      // A restart while the first read is in flight reads once more after
      // it, not twice at once.
      await emit(
        dockerContainerList('srv-1', [
          dockerContainer('c-1', status: 'Up 1 second'),
        ], at: at),
      );
      await emit(
        dockerContainerList('srv-1', [
          dockerContainer('c-1', status: 'Up 3 seconds'),
        ], at: at),
      );
      expect(inspects(), hasLength(1));
      await emit(
        dockerAnswer(
          inspects().single,
          DockerContainerPayload(dockerContainerDetails('c-1')),
        ),
      );
      expect(inspects(), hasLength(2));

      await emit(dockerContainerList('srv-1', const [], at: at));
      expect(details.value.removed, isTrue);
      expect(inspects(), hasLength(2), reason: 'nothing to read');
    });

    test('a server that leaves the fleet drops the details (SYN-08), and '
        'a stopped engine answers nothing', () async {
      final details = docker.openContainer('srv-1', 'c-1');
      final inFlight = inspects().single;
      await emit(CatalogReplaced(const []));
      await emit(
        dockerAnswer(
          inFlight,
          DockerContainerPayload(dockerContainerDetails('c-1')),
        ),
      );
      expect(details.value.container, isNull);
      docker.closeContainer('srv-1', 'c-1');

      final unlisted = docker.openContainer('srv-1', 'c-1');
      expect(unlisted.value.failure?.failure, DockerQueryFailure.notInFleet);
      expect(inspects(), hasLength(1));

      await emit(
        CatalogReplaced([
          const FleetEntry(
            serverId: 'srv-2',
            label: 'web-2',
            host: 'web-2.example.net',
            port: kSshDefaultPort,
            origin: FleetEntryOrigin.sshConfig,
          ),
        ]),
      );
      final pending = docker.openContainer('srv-2', 'c-9');
      await engine.close();
      await pumpEventQueue();
      expect(pending.value.failure?.failure, DockerQueryFailure.cancelled);
      final late = docker.openContainer('srv-2', 'c-8');
      expect(late.value.failure?.failure, DockerQueryFailure.cancelled);
      expect(inspects(), hasLength(2));
    });
  });
}
