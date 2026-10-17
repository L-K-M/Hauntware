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
}
