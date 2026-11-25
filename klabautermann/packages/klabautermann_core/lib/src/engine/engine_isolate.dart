import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:seance_core/catalog.dart' show EndpointPinStore;
import 'package:seance_core/seance_core.dart'
    show Prober, SshLink, TcpBannerProber;

import '../catalog/engine_sync.dart';
import '../links/connection_tester.dart';
import '../links/link_connector.dart';
import '../runtime/engine_state.dart';
import '../sampling/subscriptions.dart';
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'protocol.dart';

/// Tells the app of an [error] the engine caught rather than answered.
void reportEngineFault(SendPort uiPort, Object error, StackTrace stack) =>
    uiPort.send(EngineFault('$error', stack: '$stack'));

/// What the engine isolate starts with, sent once by `Isolate.spawn`
/// (D18): the port it answers on and the app's support directory, where it
/// keeps the files it owns (03 §4.10). Plain data; the app resolves the
/// directory through Flutter's `path_provider`, which this pure-Dart
/// package cannot reach.
@immutable
final class EngineStart {
  const EngineStart({
    required this.uiPort,
    required this.supportDirectory,
    this.linksEnabled = false,
    this.probesEnabled = false,
    this.supportDirectoryAccess = SupportDirectoryAccess.unguarded,
    this.deviceId,
    this.pinPublicationRelease = kPinPublicationRelease,
  });

  /// The client isolate's port.
  final SendPort uiPort;

  /// The absolute path of the app's support directory.
  final String supportDirectory;

  /// Whether the engine opens SSH links (03 §5.1, §10.1). Without them it
  /// has no link supervisor, sampling scheduler, log streams or Docker
  /// sessions: [Connect], [OpenLogStream], [DockerQuery], [DockerWatch],
  /// [SetDockerEndpoint] and [SetDockerProgram] get [RequestRejected]
  /// and nothing dials, samples or reads, and [OpenPortForward] gets one
  /// too; [CloseStream], [DockerUnwatch], [Disconnect],
  /// [RefreshSubscription], [ClosePortForward] and [SetAppActivity]
  /// change nothing,
  /// subscriptions are only recorded, and no [Prompt] is ever open. The app's composition root leaves
  /// them off; tests turn them on.
  final bool linksEnabled;

  /// Whether the engine probes the reachability of the fleet's confirmed
  /// endpoints (FL-04, 03 §5.12), apart from [linksEnabled]: a probe is a
  /// TCP connect, not a link. Without it nothing probes and no
  /// [Reachability] is sent; with it, [SetAppActivity] pauses probing
  /// even while links are off. The app's composition root turns it on;
  /// tests that do not probe leave it off, so they open no sockets.
  final bool probesEnabled;

  /// Whether this process alone uses [supportDirectory]: the engine writes
  /// and purges its capability cache and writes its host-key pins there
  /// only then (03 §4.10, D59, D61).
  final SupportDirectoryAccess supportDirectoryAccess;

  /// This install's sync authorship id from `settings.json`
  /// (`klabautermann.sync.deviceId`, 03 §4.10), which the app read after
  /// taking the instance lock; null when that file gave none, and sync is
  /// then refused.
  final String? deviceId;

  /// The release a pin publication assertion names (D15, M5 plan M07):
  /// [kPinPublicationRelease], which tests replace; null offers none.
  final String? pinPublicationRelease;
}

/// The engine isolate's entry point (03 D18): one isolate owns the SSH links,
/// samplers, parsers, Docker calls, sync and rule evaluation so the UI isolate
/// never blocks on a host.
///
/// [start] names the client isolate's port and the support directory, and
/// whether links are on. The engine first returns its command port, then
/// answers requests on the client's port: [Hello] gets [EngineReady] and
/// the fleet it started with in a [CatalogReplaced], [Subscribe],
/// [Unsubscribe], [SetCadenceProfile] and [SetServerCadenceCap] update the
/// sampling subscriptions, which the sampling scheduler runs over each
/// server's ready link as
/// [Sample], [Gap], [SamplingState] and [HostProfileChanged] events
/// (03 §6.4; links off, nothing samples), [RefreshSubscription] has it
/// read one subscription's streams at once, a server's cached profile goes
/// out as a [HostProfileChanged] when a [Connect] or [Subscribe] first
/// names it (03 §6.1, D59), [ImportSshConfig] gets
/// [CatalogReplaced] and [SshConfigImported], [Connect], [Disconnect] and
/// [SetAppActivity] go to the link supervisor and [AnswerPrompt] to the
/// prompt broker (03 §5.1), a [Connect] to a fleet server without a
/// config gets [ConnectRejected] (D61), [OpenLogStream] and
/// [CloseStream] go to the log streams, which read each window over its
/// server's link (03 §5.2, §7.6), or for a [ContainerLogSource] over its
/// server's Docker session (03 §7.12), a [DockerQuery] goes to its server's
/// Docker session, which finds and negotiates the endpoint over the link
/// once the probe has answered and reports it as [DockerEndpointState]
/// (03 §5.8, §5.9), [DockerWatch] and [DockerUnwatch] go to that session,
/// which follows the engine's events into [DockerListChanged] lists
/// (03 §7.12), [SetDockerEndpoint] sets the socket it tries first
/// (CN-09) and [SetDockerProgram] the `docker` it runs (CN-16),
/// [EnrollSync], [RunSyncRound] and [SignOutSync] run sync one at a time
/// beside the request queue (03 §4.3, D63), answered by
/// [SyncStatus] and, when they succeed, the fleet, after an
/// [EndpointChanged] for each confirmed endpoint a round changed (03
/// §4.7), [ConfirmEndpoints] pins synced endpoints and answers with the
/// fleet, a [Connect] to an unconfirmed synced server gets
/// [ConnectRejected], [SetMonitorSet] samples its eligible servers'
/// `overview` over links dialed unattended (FL-21, 03 §4.3 step 4),
/// [AnswerKeystore] completes the keystore call it names ahead of the
/// queue, a [PlanAction] gets [ActionRefused] until its planner lands and
/// a [RunAction] because no plan is held yet (03 §8.5), [Shutdown] ends
/// every log stream and exits, and every other 03 §10.1 row gets
/// [RequestRejected] until its milestone lands.
///
/// With probes on, the fleet's confirmed endpoints are probed once the
/// app has the fleet ([Hello]'s answer), and each answer goes out as a
/// [Reachability]; a server behind a jump host is reported unknown, the
/// background pauses the probes, and a server that leaves the fleet or
/// loses its confirmation is no longer probed (03 §4.7, §5.12).
///
/// [dial] replaces `SshLink.connect`, so tests can run the engine's links
/// without a network, [testAuthenticator] the editor's connection test's
/// sign-in, [prober] the probes' TCP connect, and
/// [syncTransport] the sync server's HTTP client.
/// [subscriptions], when given, holds the sampling subscriptions, so
/// tests can read them, and [endpointPinStore] replaces the endpoint pins
/// [openEndpointPins] opens, so tests can fail their reads.
///
/// The whole engine runs inside one error zone, its last-resort boundary:
/// an error no handler caught, which in the isolate's root zone would end
/// the isolate with every link, shell and forward, goes out as an
/// [EngineFault] and the engine goes on. Each piece of work started
/// beside the request queue still answers its own failure; the boundary
/// is for the one nobody foresaw.
void engineMain(
  EngineStart start, {
  @visibleForTesting LinkDialer dial = SshLink.connect,
  @visibleForTesting TestAuthenticatorFactory? testAuthenticator,
  @visibleForTesting Prober prober = const TcpBannerProber(),
  @visibleForTesting SyncTransportFactory syncTransport = httpSyncTransport,
  @visibleForTesting SamplingSubscriptions? subscriptions,
  @visibleForTesting EndpointPinStore? endpointPinStore,
  @visibleForTesting
  void Function(Future<void> Function() drain)? onSupportWrites,
}) {
  runZonedGuarded(
    () => EngineState(
      start,
      dial: dial,
      testAuthenticator: testAuthenticator,
      prober: prober,
      syncTransport: syncTransport,
      subscriptions: subscriptions,
      endpointPinStore: endpointPinStore,
      onSupportWrites: onSupportWrites,
    ).run(),
    (error, stack) => reportEngineFault(start.uiPort, error, stack),
  );
}
