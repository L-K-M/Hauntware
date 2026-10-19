// The Access tab's Docker facts from a server's endpoint state (CN-24,
// CN-09; 03 §5.3, §5.9): streamlocal by the route's rank or the ladder's
// reason, the compose CLIs, and whether the socket chosen on the device
// is the one in use.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show StreamlocalAccess;
import 'package:test/test.dart';

const _srv = 'srv-1';
const _rootful = '/var/run/docker.sock';

DockerEndpointState _ready(
  DockerRank rank, {
  String socketPath = _rootful,
  DockerEndpointChoice choice = const DockerEndpointAuto(),
}) => DockerEndpointState(
  serverId: _srv,
  phase: DockerEndpointPhase.ready,
  route: DockerEndpointRoute(
    rank: rank,
    socketPath: socketPath,
    runtime: EngineRuntime.docker,
    rootEquivalence: DockerRootEquivalence.rootfulSocket,
    mode: EngineMode.rootful,
  ),
  negotiatedApi: const ApiVersion(1, 47),
  choice: choice,
);

DockerEndpointState _failed(
  DockerEndpointFailure failure, {
  DockerNoRouteReason? reason,
  DockerEndpointChoice choice = const DockerEndpointAuto(),
}) => DockerEndpointState(
  serverId: _srv,
  phase: DockerEndpointPhase.failed,
  failure: failure,
  noRouteReason: reason,
  choice: choice,
);

void main() {
  test('streamlocal is unknown until the ladder has run', () {
    for (final state in [
      null,
      const DockerEndpointState(
        serverId: _srv,
        phase: DockerEndpointPhase.waiting,
      ),
      const DockerEndpointState(
        serverId: _srv,
        phase: DockerEndpointPhase.resolving,
      ),
    ]) {
      expect(dockerAccessFacts(state).streamlocal, isNull, reason: '$state');
    }
  });

  test('a route tells streamlocal by its rank, a failure with one too', () {
    expect(
      dockerAccessFacts(_ready(DockerRank.streamlocal)).streamlocal,
      StreamlocalAccess.allowed,
    );
    for (final relay in [DockerRank.cliRelay, DockerRank.socketRelay]) {
      expect(
        dockerAccessFacts(_ready(relay)).streamlocal,
        StreamlocalAccess.disabled,
      );
    }
    final refused = DockerEndpointState(
      serverId: _srv,
      phase: DockerEndpointPhase.failed,
      failure: DockerEndpointFailure.belowClientFloor,
      route: _ready(DockerRank.streamlocal).route,
    );
    expect(dockerAccessFacts(refused).streamlocal, StreamlocalAccess.allowed);
  });

  test('without a route the ladder\'s reason tells it, and any other '
      'failure tried no socket', () {
    final cases = <DockerEndpointState, StreamlocalAccess>{
      _failed(
        DockerEndpointFailure.noRoute,
        reason: DockerNoRouteReason.noRelay,
      ): StreamlocalAccess.disabled,
      _failed(
        DockerEndpointFailure.noRoute,
        reason: DockerNoRouteReason.socketDenied,
      ): StreamlocalAccess.socketDenied,
      _failed(
        DockerEndpointFailure.noRoute,
        reason: DockerNoRouteReason.needsAdminMode,
      ): StreamlocalAccess.socketDenied,
      for (final reason in [
        DockerNoRouteReason.probeFailed,
        DockerNoRouteReason.noSocket,
        DockerNoRouteReason.socketsUnknown,
      ])
        _failed(DockerEndpointFailure.noRoute, reason: reason):
            StreamlocalAccess.untested,
      for (final failure in [
        DockerEndpointFailure.unreachable,
        DockerEndpointFailure.linkError,
        DockerEndpointFailure.invalidChoice,
      ])
        _failed(failure): StreamlocalAccess.untested,
    };
    for (final MapEntry(key: state, value: want) in cases.entries) {
      expect(
        dockerAccessFacts(state).streamlocal,
        want,
        reason: '${state.failure} ${state.noRouteReason}',
      );
    }
  });

  test('the compose CLIs cross as found, and a failed check only without '
      'them', () {
    final facts = dockerAccessFacts(
      null,
      compose: const DockerComposeCli(
        pluginVersion: '2.29.7',
        standaloneVersion: '1.29.2',
      ),
      composeCheckFailed: true,
    );
    expect(facts.compose!.pluginVersion, '2.29.7');
    expect(facts.compose!.standaloneVersion, '1.29.2');
    expect(facts.compose!.standaloneLegacy, isTrue);
    expect(facts.composeCheckFailed, isFalse);

    expect(dockerAccessFacts(null).compose, isNull);
    expect(
      dockerAccessFacts(null, composeCheckFailed: true).composeCheckFailed,
      isTrue,
    );
  });

  test('a chosen socket is in use once the route reaches it, unsettled '
      'while the endpoint looks, and unavailable otherwise', () {
    const podman = '/run/podman/podman.sock';
    const chosen = DockerEndpointDetected(podman);

    final auto = dockerAccessFacts(_ready(DockerRank.streamlocal));
    expect((auto.chosenSocket, auto.chosenSocketInUse), (null, null));

    final inUse = dockerAccessFacts(
      _ready(DockerRank.streamlocal, socketPath: podman, choice: chosen),
    );
    expect((inUse.chosenSocket, inUse.chosenSocketInUse), (podman, true));

    final fellBack = dockerAccessFacts(
      _ready(DockerRank.streamlocal, choice: chosen),
    );
    expect(fellBack.chosenSocketInUse, isFalse);

    final invalid = dockerAccessFacts(
      _failed(
        DockerEndpointFailure.invalidChoice,
        choice: const DockerEndpointCustom('relative'),
      ),
    );
    expect(
      (invalid.chosenSocket, invalid.chosenSocketInUse),
      ('relative', false),
    );

    final resolving = dockerAccessFacts(
      const DockerEndpointState(
        serverId: _srv,
        phase: DockerEndpointPhase.resolving,
        choice: chosen,
      ),
    );
    expect(
      (resolving.chosenSocket, resolving.chosenSocketInUse),
      (podman, null),
    );
  });

  test('a socket path is absolute and free of NUL and line breaks', () {
    final cases = <String, DockerSocketPathProblem?>{
      '/run/docker.sock': null,
      "/srv/a b'c.sock": null,
      '': DockerSocketPathProblem.notAbsolute,
      'run/docker.sock': DockerSocketPathProblem.notAbsolute,
      ' /run/docker.sock': DockerSocketPathProblem.notAbsolute,
      '/a\nb.sock': DockerSocketPathProblem.unsafeCharacter,
      '/a\rb.sock': DockerSocketPathProblem.unsafeCharacter,
      '/a\u0000b.sock': DockerSocketPathProblem.unsafeCharacter,
    };
    for (final MapEntry(key: path, value: want) in cases.entries) {
      expect(dockerSocketPathProblem(path), want, reason: path);
    }
  });
}
