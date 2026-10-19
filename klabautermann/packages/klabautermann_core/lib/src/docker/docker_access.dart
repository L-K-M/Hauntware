/// The Access tab's Docker facts (CN-24, CN-09; 03 §5.9, §10.4): what a
/// server's [DockerEndpointState] and the compose CLIs found tell the
/// access check that the capability probe cannot.
library;

import 'package:klabautermann_host/klabautermann_host.dart'
    show ComposeFacts, DockerAccessFacts, StreamlocalAccess;

import '../engine/protocol.dart';
import 'docker_ladder.dart' show DockerNoRouteReason, DockerRank;

/// The facts in [endpoint], what the engine last said of the server's
/// endpoint (null before it said anything), and [compose], the CLIs a
/// [DockerComposeQuery] or a stacks list found, or [composeCheckFailed]
/// when that query failed.
///
/// Streamlocal is known once the ladder has run on the link: a route
/// found tells by its rank, since the ladder takes a relay only for a
/// socket sshd refused although the user can write it (03 §5.3); with
/// no route, the ladder's reason tells a refused writable socket from
/// one the user cannot write, and any other failure tried no socket.
DockerAccessFacts dockerAccessFacts(
  DockerEndpointState? endpoint, {
  DockerComposeCli? compose,
  bool composeCheckFailed = false,
}) {
  final chosen = switch (endpoint?.choice) {
    DockerEndpointSocket(:final socketPath) => socketPath,
    DockerEndpointAuto() || null => null,
  };
  final settled = switch (endpoint?.phase) {
    DockerEndpointPhase.ready || DockerEndpointPhase.failed => true,
    DockerEndpointPhase.waiting ||
    DockerEndpointPhase.resolving ||
    null => false,
  };
  return DockerAccessFacts(
    streamlocal: settled ? _streamlocal(endpoint!) : null,
    compose: switch (compose) {
      final cli? => ComposeFacts(
        pluginVersion: cli.pluginVersion,
        standaloneVersion: cli.standaloneVersion,
        standaloneLegacy: cli.standaloneLegacy,
      ),
      null => null,
    },
    composeCheckFailed: compose == null && composeCheckFailed,
    chosenSocket: chosen,
    chosenSocketInUse: chosen == null || !settled
        ? null
        : endpoint!.route?.socketPath == chosen,
  );
}

StreamlocalAccess _streamlocal(DockerEndpointState endpoint) {
  if (endpoint.route case final route?) {
    return route.rank == DockerRank.streamlocal
        ? StreamlocalAccess.allowed
        : StreamlocalAccess.disabled;
  }
  return switch (endpoint.noRouteReason) {
    DockerNoRouteReason.noRelay => StreamlocalAccess.disabled,
    DockerNoRouteReason.needsAdminMode ||
    DockerNoRouteReason.socketDenied => StreamlocalAccess.socketDenied,
    DockerNoRouteReason.probeFailed ||
    DockerNoRouteReason.noSocket ||
    DockerNoRouteReason.socketsUnknown ||
    null => StreamlocalAccess.untested,
  };
}
