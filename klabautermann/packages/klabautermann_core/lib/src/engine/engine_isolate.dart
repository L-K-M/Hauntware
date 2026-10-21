import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_host/klabautermann_host.dart'
    show HostProfile, OpDirectoryKind;
import 'package:meta/meta.dart';
import 'package:seance_core/catalog.dart'
    show EndpointPin, EndpointPinStore, endpointPinsFileName;
import 'package:seance_core/seance_core.dart'
    show ImportedHost, Prober, ServerConfig, SshLink, TcpBannerProber;

import '../admin/admin_mode.dart';
import '../audit/audit_log.dart';
import '../admin/safety_policy.dart';
import '../admin/user_crontabs.dart';
import '../capabilities/capability_cache.dart';
import '../catalog/engine_sync.dart';
import '../catalog/engine_vault.dart';
import '../catalog/keystore_channel.dart';
import '../docker/docker_router.dart';
import '../fleet/endpoint_pins.dart';
import '../fleet/imported_fleet.dart';
import '../fleet/monitor_set.dart';
import '../fleet/reachability_service.dart';
import '../fleet/ssh_config_entries.dart';
import '../fleet/ssh_config_import_store.dart';
import '../fleet/synced_fleet.dart';
import '../links/credential_source.dart';
import '../links/host_key_pins.dart';
import '../links/channel_quota.dart';
import '../links/link_connector.dart';
import '../links/link_supervisor.dart';
import '../links/prompt_broker.dart';
import '../logs/log_stream_router.dart';
import '../operations/confirmation.dart';
import '../operations/detached_runner.dart';
import '../operations/edit_reader.dart';
import '../operations/footprint.dart';
import '../operations/operation_plan.dart'
    show DockerTargetUnchanged, PlanAttempt, StackConfigUnchanged;
import '../operations/operation_runner.dart';
import '../operations/operation_tracker.dart';
import '../operations/operations_shown.dart';
import '../operations/plan_registry.dart';
import '../operations/plan_types.dart' show RequiredLevel;
import '../operations/plans/backup_plans.dart';
import '../operations/plans/docker_plans.dart';
import '../operations/plans/edit_plan.dart';
import '../operations/stack_edits.dart';
import '../operations/plans/host_plans.dart';
import '../operations/plans/redeploy_plan.dart';
import '../operations/protected_targets.dart';
import '../sampling/sampling_scheduler.dart';
import '../sampling/subscriptions.dart';
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'protocol.dart';

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
  });

  /// The client isolate's port.
  final SendPort uiPort;

  /// The absolute path of the app's support directory.
  final String supportDirectory;

  /// Whether the engine opens SSH links (03 §5.1, §10.1). Without them it
  /// has no link supervisor, sampling scheduler, log streams or Docker
  /// sessions: [Connect], [OpenLogStream], [DockerQuery], [DockerWatch]
  /// and [SetDockerEndpoint] get [RequestRejected] and nothing dials,
  /// samples or reads, [CloseStream], [DockerUnwatch], [Disconnect],
  /// [RefreshSubscription] and [SetAppActivity] change nothing,
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
}

/// The engine isolate's entry point (03 D18): one isolate owns the SSH links,
/// samplers, parsers, Docker calls, sync and rule evaluation so the UI isolate
/// never blocks on a host.
///
/// [start] names the client isolate's port and the support directory, and
/// whether links are on. The engine first returns its command port, then
/// answers requests on the client's port: [Hello] gets [EngineReady] and
/// the fleet it started with in a [CatalogReplaced], [Subscribe],
/// [Unsubscribe] and [SetCadenceProfile] update the sampling subscriptions,
/// which the sampling scheduler runs over each server's ready link as
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
/// (CN-09), [EnrollSync] and [RunSyncRound] run pull-only sync
/// one at a time beside the request queue (03 §4.3, D63), answered by
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
/// without a network, [prober] the probes' TCP connect, and
/// [syncTransport] the sync server's HTTP client.
/// [subscriptions], when given, holds the sampling subscriptions, so
/// tests can read them, and [endpointPinStore] replaces the endpoint pins
/// [openEndpointPins] opens, so tests can fail their reads.
void engineMain(
  EngineStart start, {
  @visibleForTesting LinkDialer dial = SshLink.connect,
  @visibleForTesting Prober prober = const TcpBannerProber(),
  @visibleForTesting SyncTransportFactory syncTransport = httpSyncTransport,
  @visibleForTesting SamplingSubscriptions? subscriptions,
  @visibleForTesting EndpointPinStore? endpointPinStore,
}) {
  final uiPort = start.uiPort;
  final commands = ReceivePort('klabautermann engine commands');
  uiPort.send(commands.sendPort);

  void reject(EngineRequest request, String reason) =>
      uiPort.send(RequestRejected(request.runtimeType.toString(), reason));

  // Which streams each server's surfaces subscribed, and the cadence
  // profile (D45), which the scheduler below samples.
  final sampling = subscriptions ?? SamplingSubscriptions();

  // Samples each subscribed server over its ready link (03 §6.4). None
  // while links are off, since no link would ever be ready. It follows
  // every LinkState the supervisor reports.
  SamplingScheduler? scheduler;

  // The log streams over each server's ready link (03 §7.6); none while
  // links are off. They follow every LinkState as the scheduler does.
  LogStreamRouter? logs;

  // Each queried server's Docker endpoint over its ready link (03 §5.9);
  // none while links are off. It follows every LinkState and probe
  // answer.
  DockerRouter? docker;
  // Admin mode per server (03 §8.2), over the links; none while links are
  // off. The safety policy the app last sent; until then every server is
  // observe-only (SAF-01).
  AdminModeController? admin;
  // Each server's detached operations (03 §7.17), over the links; none
  // while links are off. It opens with the support directory's files.
  OperationTracker? operations;
  var safetyPolicy = const SafetyPolicy();
  // Previewed plans and the runner of confirmed ones (03 §8.5). A plan
  // runs only on the link generation it was planned on: each server's
  // generation counts the times its link became ready.
  final plans = PlanRegistry();
  // The device audit log (03 §8.10): a record per finished run, in files
  // only while this process has the support directory to itself.
  final audit = AuditLog(
    Directory(
      '${start.supportDirectory}${Platform.pathSeparator}$auditDirectoryName',
    ),
    storage: start.supportDirectoryAccess == SupportDirectoryAccess.exclusive
        ? AuditStorage.files
        : AuditStorage.memory,
    deviceId: start.deviceId,
  );
  final linkGenerations = <String, int>{};
  final readyLinks = <String>{};
  // Each server's latest probe answer, which the planners read for the
  // login uid, the session's path and its SSH port.
  final profiles = <String, HostProfile>{};
  OperationRunner? runner;

  // Each server's channel slots, one quota for both routers, so the host
  // log reads and the Docker session's channels count against the same
  // shares (M9).
  final channelQuotas = ChannelQuotas();

  // FL-02's imported hosts, in D13's device-local store (03 §4.10),
  // opened before the first request is handled. Each import replaces the
  // last; the engine keeps them so its later fleet snapshots (sync rounds,
  // F3) carry them after the synced entries. The store hands them out
  // unmodifiable, so building a snapshot cannot edit them in place.
  late final SshConfigImportStore imports;

  // Each fleet server's last probed profile (03 §6.1, D59), opened with
  // the import store.
  CapabilityCache? capabilities;

  // The login name for imported hosts and hops that name no user.
  final localUser = localUserName(Platform.environment);

  // The fleet the engine serves: the sync account's servers, then the
  // imports, with the config of each import and hop it can dial, and its
  // server ids. A synced server has a config only while its endpoint is
  // confirmed on this device (03 §4.7, SAF-09), so neither the user nor
  // a background connect dials it otherwise. Imports count as confirmed
  // on the device that imported them (03 §4.3, owner question O6's
  // default).
  var syncedServers = const <ServerConfig>[];
  var synced = SyncedFleet.empty;
  late ImportedFleet fleet;
  var fleetIds = <String>{};
  List<FleetEntry> fleetEntries() => [...synced.entries, ...fleet.entries];
  ServerConfig? configOf(String id) =>
      synced.serverConfig(id) ?? fleet.serverConfig(id);

  // The endpoints this device confirmed (D16): `endpoint_pins.json` while
  // the process holds the support directory alone, otherwise memory only.
  // One store for the engine's lifetime, as for the host-key pins.
  final endpointPins =
      endpointPinStore ??
      openEndpointPins(
        start.supportDirectory,
        access: start.supportDirectoryAccess,
      );

  // The OS keystore, which the app answers (D62), and pull-only sync,
  // opened with the import store.
  final keystore = ChannelSyncKeystore(uiPort.send);
  late final EngineSync sync;
  var syncOpened = false;

  // The one vault over `vault.json` (03 §4.5), which links read and sync
  // re-keys. Until sync has opened, the account is unknown, so the vault
  // mints no master key.
  final vault = EngineVault(
    Directory(start.supportDirectory),
    access: start.supportDirectoryAccess,
    keystore: keystore,
    enrolled: () => !syncOpened || sync.account != null,
  );

  // What the engine asks the user while it connects, keyed by prompt id
  // (03 §10.1).
  final prompts = PromptBroker(emit: uiPort.send);

  // The host-key pins (03 §4.6, D61): `host_keys.json` while the process
  // holds the support directory alone, otherwise that file's pins read
  // once and kept in memory. One store for the engine's lifetime (P14),
  // shared by its links and the sync coordinator (D63), since two over one
  // file would each write back their own pins. Opening it reads nothing;
  // the first connect or sync operation loads the file.
  final hostKeys = openHostKeyPins(
    start.supportDirectory,
    access: start.supportDirectoryAccess,
  );

  // One link per server (03 §5.1, §5.12), dialed through the connector.
  // None while links are off, so nothing in the engine can dial. Pins go
  // to the shared host-key store above. Phones close their links in the
  // background (D34); desktops keep them.
  final links = start.linksEnabled
      ? LinkSupervisor(
          connect: LinkConnector(
            credentials: EngineCredentialSource(
              identityAuditLogIn(start.supportDirectory),
              vault: vault.read,
            ),
            saveSecret: vault.save,
            hostKeys: hostKeys,
            prompts: prompts,
            hopConfig: configOf,
            dial: dial,
          ).connect,
          // Fleet entries only: the fleet's hop configs serve their routes.
          configFor: (id) => fleetIds.contains(id) ? configOf(id) : null,
          emit: (event) {
            uiPort.send(event);
            if (event is LinkState) {
              scheduler?.update(event.serverId);
              logs?.update(event.serverId);
              docker?.update(event.serverId);
              if (event.status is LinkReady || event.status is LinkDegraded) {
                if (readyLinks.add(event.serverId)) {
                  linkGenerations.update(
                    event.serverId,
                    (n) => n + 1,
                    ifAbsent: () => 1,
                  );
                }
              } else {
                readyLinks.remove(event.serverId);
                admin?.linkLost(event.serverId);
                operations?.linkLost(event.serverId);
              }
            }
          },
          policy: Platform.isAndroid || Platform.isIOS
              ? BackgroundLinkPolicy.closeAfterGrace
              : BackgroundLinkPolicy.keepOpen,
        )
      : null;

  // A stack file's edit (STK-07) looks its project up on the server's
  // Docker endpoint, for its read and again for its plan: null while
  // links are off.
  StackEditLookup? stackEditLookup(String serverId) {
    final router = docker;
    if (router == null) return null;
    return (project, path) async {
      try {
        return await router.useStacks(serverId, (client, route, stacks) async {
          final found = await stacks.editable(client, project, path);
          return (
            project: found.project,
            socketPath: route.socketPath,
            failure: found.failure,
          );
        });
      } on Object {
        // No endpoint, or the list failed: nothing to edit against.
        return (
          project: null,
          socketPath: null,
          failure: StackFileFailure.readFailed,
        );
      }
    };
  }

  // A user-initiated step on a link at its learned session limit borrows
  // the slow sampler's session for the while; the fast sampler samples on
  // (M4 plan M6). Elsewhere the step runs as it is.
  Future<T> lendSession<T>(String serverId, Future<T> Function() body) async {
    final link = links?.link(serverId);
    final inUse =
        (scheduler?.samplerSessions(serverId) ?? 0) +
        channelQuotas.of(serverId).sessionsHeld;
    if (link == null ||
        !leavesNoSession(
          learnedSessionLimit: link.seen.learnedSessionLimit,
          inUse: inUse,
        )) {
      return body();
    }
    final giveBack = await scheduler?.yieldSlowSampler(serverId);
    try {
      return await body();
    } finally {
      giveBack?.call();
    }
  }

  // FL-21's monitor set (03 §4.3 step 4, §6.4): the servers whose
  // `overview` the fleet rows read while the app is in the foreground,
  // whether or not a view shows them, over links dialed unattended so
  // nothing prompts. It holds eligible fleet servers only. The servers
  // a view holds a link to ([Connect] without its [Disconnect] yet) are
  // kept beside it: a server that leaves the set keeps the link a view
  // holds, and a view that leaves keeps a monitored server's link.
  var monitored = const <String>{};
  final viewed = <String>{};

  // Verifies a server's footprint (SAF-14, P13) and sends what it found:
  // on every connect, when admin mode turns on (root's part), after an
  // edit or a backup removal, and on request. readFootprint answers
  // rather than throws.
  void verifyFootprint(String serverId) {
    final link = links?.link(serverId);
    final profile = profiles[serverId];
    if (link == null || profile == null) return;
    unawaited(
      lendSession(
        serverId,
        () => readFootprint(serverId, (
          link: link,
          profile: profile,
          admin: admin?.session(serverId),
        )),
      ).then(uiPort.send),
    );
  }

  if (links != null) {
    admin = AdminModeController(
      linkFor: links.link,
      endpointOf: (id) => switch (configOf(id)) {
        final config? => (
          host: config.host,
          port: config.port,
          user: config.username,
        ),
        null => null,
      },
      prompts: prompts,
      emit: (event) {
        uiPort.send(event);
        if (event is! AdminModeState) return;
        // A sudo relay and an elevated follow live only while admin mode
        // does (plan M7, LOG-22).
        docker?.adminChanged(event.serverId);
        if (event.phase == AdminModePhase.on) verifyFootprint(event.serverId);
        logs?.adminChanged(event.serverId);
        // A root result's cleanup waits for admin mode (03 §7.17).
        if (event.phase == AdminModePhase.on) {
          unawaited(operations?.adminOn(event.serverId));
        }
      },
    );
    runner = OperationRunner(
      linkFor: links.link,
      emit: uiPort.send,
      lend: lendSession,
      api: (serverId, step) async {
        final router = docker;
        if (router == null) {
          throw const DockerEndpointUnavailable(DockerQueryFailure.cancelled);
        }
        final status = await router.useEndpoint(
          serverId,
          (client, _) => runApiStep(client, step),
        );
        if (status >= 200 && status < 300) {
          final (:container, :images) = apiStepChanges(step);
          router.actionRan(serverId, containers: {?container}, images: images);
        }
        return status;
      },
      docker: (serverId, check) async {
        final router = docker;
        if (router == null) return RevalidationFailure.unreadable;
        try {
          return await router.useStacks(
            serverId,
            (client, _, stacks) => switch (check) {
              final StackConfigUnchanged stack => revalidateStackConfig(
                stacks,
                stack,
              ),
              final DockerTargetUnchanged target => revalidateDockerTarget(
                client,
                target,
              ),
              _ => Future.value(RevalidationFailure.unreadable),
            },
          );
        } on Object {
          return RevalidationFailure.unreadable;
        }
      },
      launch: (serverId, plan, session) async {
        final link = links.link(serverId);
        final uid = profiles[serverId]?.uid;
        final runner = plan.detachedRunner!;
        final id = newOpId();
        if (link == null || uid == null) {
          return (
            id: id,
            dir: null,
            pid: null,
            failure: LaunchFailure.transport,
            exitCode: null,
          );
        }
        final launched = await launchDetached(
          link: link,
          runner: runner,
          uid: uid,
          argv: detachedArgv(plan),
          id: id,
          session: session,
        );
        if (launched.failure == null) {
          await operations?.launched(
            serverId,
            id,
            directory: runner.runsAsRoot
                ? OpDirectoryKind.root
                : OpDirectoryKind.user,
            launch: OperationLaunch.ofPlan(
              plan,
              startedAt: DateTime.now().toUtc(),
            ),
          );
        }
        return launched;
      },
      // A record that cannot be written is lost; the run itself stands. A
      // started detached operation is audited with its result, once the
      // app has shown it (03 §7.17).
      finished: (result) {
        if (result.plan.intent
            case EditFile() || KeepLastBackups() || RemoveBackups()) {
          verifyFootprint(result.plan.intent.serverId);
        }
        if (result.plan.detached &&
            result.finished.outcome == ActionOutcome.succeeded) {
          return;
        }
        unawaited(audit.recordRun(result).catchError((Object _) {}));
      },
    );
    scheduler = SamplingScheduler(
      subscriptions: sampling,
      linkFor: links.link,
      emit: uiPort.send,
      deadPeerHint: links.deadPeerHint,
      clearDeadPeerHint: links.clearDeadPeerHint,
      probed: (serverId, profile) {
        profiles[serverId] = profile;
        admin?.probed(serverId, profile);
        verifyFootprint(serverId);
        unawaited(capabilities?.probed(serverId, profile));
        docker?.probed(serverId, profile);
      },
      opsRead: (serverId, section) =>
          unawaited(operations?.listed(serverId, section)),
    );
    logs = LogStreamRouter(
      linkFor: links.link,
      emit: uiPort.send,
      adminFor: (serverId) => admin?.session(serverId),
      quotas: channelQuotas,
    );
    docker = DockerRouter(
      linkFor: links.link,
      emit: uiPort.send,
      samplerSessions: (serverId) => scheduler?.samplerSessions(serverId) ?? 0,
      adminFor: (serverId) => admin?.session(serverId),
      quotas: channelQuotas,
    );
  }

  // Probes the confirmed endpoints (FL-04, 03 §5.12); none while probes
  // are off. A server with a link is answered online without a probe.
  final reachability = start.probesEnabled
      ? ReachabilityService(
          emit: uiPort.send,
          hasLink: (id) => links?.link(id) != null,
          prober: prober,
        )
      : null;

  // Whether the app has had a fleet. Probing waits for it, since the app
  // keeps answers only for servers its fleet lists.
  var fleetSent = false;
  void probeFleet() {
    if (!fleetSent) return;
    reachability?.update(probeTargets(fleetEntries(), configOf));
  }

  // The fleet servers the monitor set may hold now: those the shared rule
  // allows and the engine can dial, which an import naming no user lacks
  // on a system that names no local account.
  Set<String> monitorEligibleIds() => {
    for (final entry in fleetEntries())
      if (monitorEligibilityOf(entry) == MonitorEligibility.eligible &&
          configOf(entry.serverId) != null)
        entry.serverId,
  };

  // Makes [next], eligible fleet servers only, the monitor set: a server
  // that joins gets its subscription and an unattended connect, and one
  // that leaves loses both, its link only when no view holds it.
  void applyMonitorSet(Set<String> next) {
    final before = monitored;
    monitored = Set.unmodifiable(next);
    for (final serverId in before.difference(next)) {
      sampling.unsubscribe(
        Unsubscribe(serverId: serverId, subscriptionId: monitorSubscriptionId),
      );
      scheduler?.update(serverId);
      if (viewed.contains(serverId)) continue;
      logs?.disconnect(serverId);
      links?.disconnect(serverId);
    }
    for (final serverId in next.difference(before)) {
      final subscription = Subscribe(
        serverId: serverId,
        subscriptionId: monitorSubscriptionId,
        streams: const {SampleStream.overview},
      );
      sampling.subscribe(subscription);
      scheduler?.subscribed(subscription);
      links?.connect(serverId, purpose: ConnectPurpose.background);
    }
  }

  // Rebuilds the fleet from the store. A server that left it is forgotten
  // (03 §5.1): its samplers, link and attempts end and its subscriptions
  // go. One that keeps its id under another endpoint loses its cached
  // profile and its Docker session, which describe another machine
  // (SYN-08).
  void refreshFleet() {
    final previous = fleetIds.isEmpty ? null : fleet;
    fleet = ImportedFleet(
      imports.hosts,
      hops: imports.hops,
      localUser: localUser,
      detail: imports.detail,
    );
    final before = fleetIds;
    fleetIds = {for (final entry in fleetEntries()) entry.serverId};
    sampling.fleet = fleetIds;
    scheduler?.retain(fleetIds);
    logs?.retain(fleetIds);
    operations?.retain(fleetIds);
    channelQuotas.retain(fleetIds);
    links?.forget(before.difference(fleetIds));
    viewed.retainAll(fleetIds);
    // A monitored server that left the fleet or is no longer eligible (a
    // sync changed its endpoint, an import its credentials) leaves the
    // set; the app hears the fleet and sends its own set again.
    if (monitored.isNotEmpty) {
      applyMonitorSet(monitored.intersection(monitorEligibleIds()));
    }
    final forgotten = {
      for (final id in before)
        if (!fleetIds.contains(id) ||
            previous?.endpointOf(id) != fleet.endpointOf(id))
          id,
    };
    docker
      ?..forget(forgotten)
      ..retain(fleetIds);
    admin?.forget(forgotten);
    plans.forget(forgotten);
    profiles.removeWhere((id, _) => forgotten.contains(id));
    // Before the caller sends the fleet or an EndpointChanged, so no
    // probe of a server starts, and no answer for it goes out, once the
    // app hears it left or lost its pin.
    probeFleet();
    unawaited(capabilities?.forget(forgotten));
  }

  // Lists [servers] against this device's pins. A pin the store cannot
  // read fails closed: its server waits to be confirmed and nothing dials
  // it, but it is listed as unreadable rather than changed. The file
  // store throws only FileSystemException, for a file it cannot read
  // (corrupt files are quarantined and read as empty); anything else is
  // a bug and propagates.
  Future<SyncedFleet> listSynced(List<ServerConfig> servers) async {
    final pins = <String, EndpointPin>{};
    final unreadable = <String>{};
    for (final server in servers) {
      try {
        if (await endpointPins.pinFor(server.id) case final pin?) {
          pins[server.id] = pin;
        }
      } on FileSystemException {
        unreadable.add(server.id);
      }
    }
    return SyncedFleet(servers, pins: pins, unreadable: unreadable);
  }

  // The synced servers whose endpoints count as confirmed when the next
  // fleet is compared: those confirmed in the last one, and those whose
  // pin, or a hop's, could not be read since they were, so a change made
  // while the store failed is caught once it reads again. A server whose
  // pin could not be read at startup is here too, as its cached profile
  // was kept.
  var trustedIds = const <String>{};

  // Takes [next] as the synced fleet. A trusted server that the account
  // still holds and that is no longer confirmed, with its pins read, had
  // its endpoint changed by a sync (03 §4.7, SYN-08): the app hears it,
  // its link and log streams close, and its cached profile goes, which
  // describes another machine. Nothing redials it until the user
  // confirms it again. One whose pins could not be read is only not
  // dialed for now: a store failure is no endpoint change. A server the
  // account no longer holds needs nothing here: refreshFleet drops it
  // from fleetIds, so its link, streams, samplers and cached profile go
  // with the retain and forget there (03 §5.1).
  void applySynced(SyncedFleet next) {
    final changed = {
      for (final id in trustedIds)
        if (next.lists(id) &&
            !next.confirmedIds.contains(id) &&
            !next.unreadableIds.contains(id))
          id,
    };
    trustedIds = {
      ...next.confirmedIds,
      for (final id in trustedIds)
        if (next.unreadableIds.contains(id)) id,
    };
    synced = next;
    refreshFleet();
    for (final id in changed) {
      uiPort.send(EndpointChanged(id));
      logs?.disconnect(id);
      links?.disconnect(id);
    }
    if (changed.isNotEmpty) unawaited(capabilities?.forget(changed));
  }

  // Lists the synced servers again with the pins as they stand. A
  // confirmation in the request queue and a sync round beside it both
  // relist; one whose servers a round replaced while it read the pins
  // leaves the fleet to that round's own relist, which reads them later.
  Future<void> relistSynced() async {
    final servers = syncedServers;
    final next = await listSynced(servers);
    if (identical(servers, syncedServers)) applySynced(next);
  }

  // A server's cached profile goes out when a request first names it,
  // since the startup events reach only the app's first listener.
  void sendCachedProfile(String serverId) {
    if (capabilities?.takeCached(serverId) case final cached?) {
      uiPort.send(cached);
    }
  }

  // Pull-only sync, one operation at a time in request order, beside the
  // request queue rather than in it: an enrollment waits on the network,
  // a key derivation and the app's keystore answers, which arrive as
  // requests, and links, sampling and imports go on meanwhile.
  var syncTail = Future<void>.value();
  void runSync(SyncOperation operation, Future<SyncStatus> Function() body) {
    syncTail = syncTail.then((_) async {
      uiPort.send(
        SyncStatus(
          SyncPhase.running,
          operation: operation,
          account: sync.account,
        ),
      );
      final SyncStatus status;
      try {
        status = await body();
        // The fleet first, so it shows the servers when the answer arrives.
        if (status.phase == SyncPhase.succeeded) {
          syncedServers = await sync.servers();
          await relistSynced();
        }
      } on Object catch (error) {
        // EngineSync answers every failure itself; this keeps the chain
        // alive should that, or the fleet refresh, ever slip: a chained
        // operation runs only after the one before it completes normally.
        uiPort.send(
          SyncStatus(
            SyncPhase.failed,
            operation: operation,
            account: sync.account,
            failure: SyncFailure.other,
            detail: '$error',
          ),
        );
        return;
      }
      if (status.phase == SyncPhase.succeeded) {
        uiPort.send(CatalogReplaced(fleetEntries()));
      }
      uiPort.send(status);
    });
  }

  Future<void> handle(Object? message) async {
    switch (message) {
      case Hello(:final protocolVersion):
        if (protocolVersion != kEngineProtocolVersion) {
          uiPort.send(
            RequestRejected(
              'Hello',
              'protocol $protocolVersion; engine speaks '
                  '$kEngineProtocolVersion',
            ),
          );
          return;
        }
        uiPort.send(
          EngineReady(
            kEngineProtocolVersion,
            importStoreIssue: imports.issue,
            syncAccount: sync.account,
            syncStoreIssues: sync.issues,
            auditInMemory: audit.storage == AuditStorage.memory,
          ),
        );
        // The fleet as the engine starts: the servers the last sync left
        // and the imports an earlier run saved (none when the stores were
        // empty or unusable), so the rail shows them before the user does
        // anything.
        uiPort.send(CatalogReplaced(fleetEntries()));
        fleetSent = true;
        probeFleet();
      case Connect(:final serverId):
        sendCachedProfile(serverId);
        // The app sends it when the user opens the server (03 §10.1), so
        // the connect may prompt, and to a server a changed host key
        // blocked it reviews the key (D61).
        if (links == null) {
          reject(message, 'links are off in this engine');
        } else if (links.connect(
          serverId,
          purpose: ConnectPurpose.interactive,
        )) {
          viewed.add(serverId);
        } else {
          // A fleet server without a config is the user's to fix, so the
          // app is told why; any other id is not a server it lists.
          switch (fleetIds.contains(serverId)
              ? synced.missingConfigReason(serverId) ??
                    fleet.missingConfigReason(serverId)
              : null) {
            case final reason?:
              uiPort.send(ConnectRejected(serverId, reason));
            case null:
              reject(message, 'no fleet server $serverId the engine can dial');
          }
        }
      case Disconnect(:final serverId):
        viewed.remove(serverId);
        // A monitored server keeps its link for the monitor set. One
        // without a link yet gives up the view's attempt, and with it any
        // prompt the view raised, and goes on dialing unattended.
        final monitoredServer = monitored.contains(serverId);
        if (monitoredServer && links?.link(serverId) != null) return;
        // Its streams end before its link closes, so none reports
        // waiting for that link first.
        logs?.disconnect(serverId);
        docker?.disconnect(serverId);
        links?.disconnect(serverId);
        if (monitoredServer) {
          links?.connect(serverId, purpose: ConnectPurpose.background);
        }
      case SetAppActivity(:final activity):
        links?.setActivity(activity);
        admin?.setActivity(activity);
        scheduler?.activity = activity;
        logs?.activity = activity;
        reachability?.activity = activity;
      case AnswerPrompt(:final promptId, :final answer):
        switch (prompts.answer(promptId, answer)) {
          case PromptAnswerResult.answered:
            break;
          case PromptAnswerResult.notOpen:
            reject(message, 'prompt $promptId is not open');
          case PromptAnswerResult.doesNotFit:
            reject(message, 'the answer does not fit prompt $promptId');
        }
      case Subscribe():
        sendCachedProfile(message.serverId);
        sampling.subscribe(message);
        scheduler?.subscribed(message);
      case Unsubscribe(:final serverId):
        sampling.unsubscribe(message);
        scheduler?.update(serverId);
      case RefreshSubscription(:final serverId, :final subscriptionId):
        if (sampling.streamsOf(serverId, subscriptionId) case final streams?) {
          scheduler?.refresh(serverId, streams);
        }
      case SetCadenceProfile(:final profile):
        sampling.profile = profile;
        scheduler?.profileChanged();
      case OpenLogStream(spec: LogStreamSpec(source: ContainerLogSource())):
        // The log router keeps every stream id; the Docker session reads.
        final reason = switch ((logs, docker)) {
          (final logs?, final docker?) =>
            logs.claim(message.streamId)
                ? docker.openLogs(message)
                : 'stream id ${message.streamId} was used before',
          _ => 'links are off in this engine',
        };
        if (reason != null) reject(message, reason);
      case OpenLogStream(:final streamId, :final spec):
        final router = logs;
        if (router == null) {
          reject(message, 'links are off in this engine');
          return;
        }
        // An operation's output is its log file, read redacted (03
        // §7.17); one the engine does not list reads no file.
        final open = switch (spec.source) {
          OperationLogSource(:final operationId) => OpenLogStream(
            streamId: streamId,
            spec: LogStreamSpec(
              serverId: spec.serverId,
              source: FileLogSource(
                operations?.logPath(spec.serverId, operationId) ?? '',
                redacted: true,
              ),
              window: spec.window,
              follow: spec.follow,
            ),
          ),
          _ => message,
        };
        if (router.open(open) case final reason?) reject(message, reason);
      case CloseStream(:final streamId):
        logs?.closeStream(streamId);
        docker?.closeLogs(streamId);
      case DockerQuery():
        switch (docker) {
          case null:
            reject(message, 'links are off in this engine');
          case final docker:
            docker.query(message);
        }
      case DockerWatch():
        switch (docker) {
          case null:
            reject(message, 'links are off in this engine');
          case final docker:
            docker.watch(message);
        }
      case DockerUnwatch():
        docker?.unwatch(message);
      case SetDockerEndpoint():
        switch (docker) {
          case null:
            reject(message, 'links are off in this engine');
          case final docker:
            docker.setEndpoint(message);
        }
      case ImportSshConfig(:final text):
        final ({
          List<ImportedHost> hosts,
          List<ImportedHost> hops,
          int skippedCount,
        })
        result;
        try {
          result = importedHostsFromSshConfig(text);
        } on Object catch (error) {
          // The importer is tolerant and is not expected to throw. If it
          // does, the engine answers rather than dying with every link.
          uiPort.send(
            RequestRejected('$ImportSshConfig', 'ssh_config import: $error'),
          );
          return;
        }
        // Saved before the fleet changes, so a restart after the answer
        // finds the import. A failed save still shows it for this run, and
        // the answer says it was not kept; the capability cache then
        // writes nothing until an import saves (D59).
        final saved = await imports.replace(result.hosts, hops: result.hops);
        capabilities?.fleetSave = saved ? FleetSave.saved : FleetSave.unsaved;
        refreshFleet();
        uiPort.send(CatalogReplaced(fleetEntries()));
        uiPort.send(
          SshConfigImported(
            importedCount: result.hosts.length,
            skippedCount: result.skippedCount,
            saved: saved,
          ),
        );
      case ConfirmEndpoints(:final serverIds):
        // Each pin is saved before it counts. One that cannot be saved
        // leaves its server unconfirmed, and the app is told before the
        // fleet, so the fleet's answer ends the request either way; the
        // others still count.
        Object? failure;
        for (final pin in synced.pinsFor(serverIds, DateTime.now())) {
          try {
            await endpointPins.confirm(pin);
          } on Object catch (error) {
            failure ??= error;
          }
        }
        if (failure != null) {
          reject(message, '$endpointPinsFileName not saved: $failure');
        }
        await relistSynced();
        uiPort.send(CatalogReplaced(fleetEntries()));
      case SetMonitorSet(:final serverIds):
        // The app offers only what the engine allows (FL-21), so a
        // rejection means the two saw different fleets; the app's next
        // set follows the fleet that answers it.
        final requested = serverIds.toSet();
        if (requested.length > kMonitorSetLimit) {
          reject(message, 'more than $kMonitorSetLimit servers');
          return;
        }
        final eligible = monitorEligibleIds();
        applyMonitorSet(requested.intersection(eligible));
        final skipped = requested.difference(eligible);
        if (skipped.isNotEmpty) {
          reject(message, 'not eligible fleet servers: ${skipped.join(', ')}');
        }
      case EnrollSync():
        runSync(SyncOperation.enroll, () => sync.enroll(message));
      case RunSyncRound():
        runSync(SyncOperation.round, sync.runRound);
      case PlanAction(:final intent):
        void refuse(ActionRefusalReason reason) =>
            uiPort.send(ActionRefused(reason, intent: intent));
        // The policy first (M4 plan M4).
        if (safetyRefusal(safetyPolicy, intent.serverId) case final reason?) {
          refuse(reason);
          return;
        }
        final serverId = intent.serverId;
        final link = links?.link(serverId);
        final profile = profiles[serverId];
        if (link == null || profile == null) {
          refuse(ActionRefusalReason.noLink);
          return;
        }
        // The plan holds the generation it was made on, so a reconnect
        // while it waits for the user makes it stale.
        final generation = linkGenerations[serverId] ?? 0;
        final protection = protectionContextOf(
          samplerPids: scheduler?.samplerPids(serverId) ?? const {},
          profile: profile,
          safety: safetyPolicy.servers[serverId],
        );
        final Future<PlanAttempt> attempt;
        switch (intent) {
          case KillProcess() || UnitAction() || StartTimer():
            // Planning reads the target over the link, as the run will.
            attempt = lendSession(
              serverId,
              () => planHostAction(intent, (
                link: link,
                profile: profile,
                protection: protection,
                adminMode: admin?.session(serverId) != null,
              )),
            );
          case ContainerAction() ||
              RemoveContainer() ||
              RemoveImage() ||
              StackAction():
            final router = docker;
            if (router == null) {
              refuse(ActionRefusalReason.engineUnavailable);
              return;
            }
            attempt = router
                .useEndpoint(
                  serverId,
                  (client, route) => planDockerAction(intent, (
                    client: client,
                    route: route,
                    protection: protection,
                    loginUser: profile.user ?? 'login user',
                  )),
                )
                .catchError(
                  (Object _) => (
                    plan: null,
                    refusal: ActionRefusalReason.engineUnavailable,
                  ),
                );
          case RedeployStack() || StackComposeAction():
            final router = docker;
            if (router == null) {
              refuse(ActionRefusalReason.engineUnavailable);
              return;
            }
            // Planning verifies the stack and lists its services over the
            // link, so it borrows a session as a run does.
            attempt =
                lendSession(
                  serverId,
                  () => router.useStacks(serverId, (client, route, stacks) {
                    final RedeployPlanContext context = (
                      client: client,
                      route: route,
                      stacks: stacks,
                      profile: profile,
                      adminMode: admin?.session(serverId) != null,
                      sudoAllows: (program) async {
                        final session = admin?.session(serverId);
                        if (session == null) return true;
                        return sudoAllowsProgram(
                          link: link,
                          session: session,
                          profile: profile,
                          program: program,
                        );
                      },
                      protection: protection,
                      loginUser: profile.user ?? 'login user',
                    );
                    return switch (intent) {
                      final RedeployStack redeploy => planRedeploy(
                        redeploy,
                        context,
                      ),
                      final StackComposeAction compose => planStackCompose(
                        compose,
                        context,
                      ),
                      _ => throw StateError(
                        'not a compose intent: ${intent.runtimeType}',
                      ),
                    };
                  }),
                ).catchError(
                  (Object _) => (
                    plan: null,
                    refusal: ActionRefusalReason.engineUnavailable,
                  ),
                );
          case KeepLastBackups() || RemoveBackups():
            attempt = lendSession(
              serverId,
              () => planBackupRemoval(intent, (
                link: link,
                profile: profile,
                admin: admin?.session(serverId),
              )),
            );
          case EditFile():
            // Planning reads the target again over the link, through admin
            // mode where it needs root, as the run will.
            attempt = lendSession(
              serverId,
              () => planEdit(intent, (
                link: link,
                profile: profile,
                admin: admin?.session(serverId),
              ), stacks: stackEditLookup(serverId)),
            );
        }
        // Not awaited: planning reads over the link, and the queue keeps
        // serving the app meanwhile.
        unawaited(
          attempt.then((attempt) {
            final plan = attempt.plan;
            if (plan == null) {
              refuse(attempt.refusal!);
              return;
            }
            final planId = plans.hold(plan, linkGeneration: generation);
            uiPort.send(ActionPlanned(planId, plan.preview));
          }),
        );
      case FootprintQuery(:final serverId):
        if (!fleetIds.contains(serverId)) {
          reject(message, 'no fleet server $serverId');
        } else if (links?.link(serverId) == null ||
            profiles[serverId] == null) {
          reject(message, 'no connection to $serverId');
        } else {
          verifyFootprint(serverId);
        }
      case ReadEditable(:final serverId, :final requestId, :final target):
        void answer(EditReadResult result) => uiPort.send(
          EditRead(serverId: serverId, requestId: requestId, result: result),
        );
        final link = links?.link(serverId);
        final profile = profiles[serverId];
        if (!fleetIds.contains(serverId) || link == null || profile == null) {
          answer(const EditReadFailed(EditReadFailure.noLink));
          return;
        }
        // Not awaited: the read waits on the host while the queue serves
        // the app. readEditable answers rather than throws; a lend that
        // fails still answers, so the editor never waits on nothing.
        unawaited(
          lendSession(
            serverId,
            () => readEditable(target, (
              link: link,
              profile: profile,
              admin: admin?.session(serverId),
            ), stacks: stackEditLookup(serverId)),
          ).then(
            answer,
            onError: (Object error) => answer(
              EditReadFailed(EditReadFailure.failed, detail: '$error'),
            ),
          ),
        );
      case AuditQuery(:final serverId, :final before, :final limit):
        final (:records, :more) = await audit.query(
          serverId,
          before: before,
          limit: limit,
        );
        uiPort.send(AuditRecords(serverId, records, more: more));
      case AcknowledgeOperation(:final serverId, :final id):
        final tracker = operations;
        if (tracker == null) {
          reject(message, 'links are off');
          return;
        }
        // Not awaited: the answer waits for the server's listing in
        // flight, which reads over the link, and the queue keeps serving
        // the app meanwhile. The tracker is not expected to throw; if it
        // does, the engine answers rather than dying with every link.
        unawaited(
          tracker.acknowledge(serverId, id).then(
            (reason) {
              if (reason != null) reject(message, reason);
            },
            onError: (Object error) =>
                reject(message, 'acknowledgement: $error'),
          ),
        );
      case ReadUserCrontabs(:final serverId, :final requestId):
        void fail(UserCrontabsFailure failure) => uiPort.send(
          UserCrontabs(
            serverId: serverId,
            requestId: requestId,
            failure: failure,
          ),
        );
        if (links?.link(serverId) == null) {
          fail(UserCrontabsFailure.noLink);
          return;
        }
        final session = admin?.session(serverId);
        if (session == null) {
          fail(UserCrontabsFailure.adminRequired);
          return;
        }
        admin?.touch(serverId);
        // Not awaited: one elevated command per user, and the queue keeps
        // serving the app meanwhile.
        unawaited(
          lendSession(
            serverId,
            () => readUserCrontabs(
              serverId,
              requestId: requestId,
              session: session,
              profile: profiles[serverId],
              now: DateTime.now().toUtc(),
            ),
          ).then(uiPort.send),
        );
      case SetSafetyPolicy(:final policy):
        if (validateSafetyPolicy(policy) case final problem?) {
          reject(message, problem);
          return;
        }
        safetyPolicy = policy;
        admin?.expiry = policy.adminExpiry;
        // A server the new policy forbids changing leaves admin mode.
        for (final serverId in [...?admin?.servers]) {
          if (adminRefusal(policy, serverId) != null) admin?.disable(serverId);
        }
      case SetSyncSecrets(:final enabled):
        // Behind any sync operation already queued, which runs under the
        // switch as it was when it was asked for.
        syncTail = syncTail.then((_) => sync.setSyncSecrets(enabled: enabled));
      case SetAdminMode(:final serverId, :final enabled):
        if (!fleetIds.contains(serverId)) {
          reject(message, 'no fleet server $serverId');
          return;
        }
        if (!enabled) {
          admin?.disable(serverId);
          return;
        }
        final failure =
            adminRefusal(safetyPolicy, serverId) ??
            (admin == null ? AdminFailure.noLink : null);
        if (failure != null) {
          uiPort.send(
            AdminModeState(serverId, AdminModePhase.failed, failure: failure),
          );
          return;
        }
        // Not awaited: the password prompt's answer comes through this
        // queue.
        unawaited(admin!.enable(serverId));
      case RunAction(:final planId, :final confirmation):
        // A plan is taken once: a refused run needs a new preview.
        final (:plan, :missing) = plans.take(
          planId,
          linkGeneration: (id) => linkGenerations[id] ?? 0,
        );
        void refuse(ActionRefusalReason reason) =>
            uiPort.send(ActionRefused(reason, planId: planId));
        if (plan == null) {
          refuse(switch (missing!) {
            PlanMissing.unknown => ActionRefusalReason.unknownPlan,
            PlanMissing.expired => ActionRefusalReason.expiredPlan,
            PlanMissing.stale => ActionRefusalReason.stalePlan,
          });
          return;
        }
        final serverId = plan.intent.serverId;
        if (safetyRefusal(safetyPolicy, serverId) case final reason?) {
          refuse(reason);
          return;
        }
        if (!confirmationSatisfies(
          required: plan.tier,
          given: confirmation.tier,
          targetName: plan.targetName,
          phrase: confirmation.phrase,
        )) {
          refuse(ActionRefusalReason.confirmationMismatch);
          return;
        }
        final planRunner = runner;
        if (planRunner == null) {
          refuse(ActionRefusalReason.notImplemented);
          return;
        }
        final session = admin?.session(serverId);
        if (plan.requiredLevel == RequiredLevel.admin && session == null) {
          refuse(ActionRefusalReason.adminRequired);
          return;
        }
        if (session != null) admin?.touch(serverId);
        // Not awaited, like the reads: a plan's steps take as long as
        // they take, and the queue keeps serving the app meanwhile.
        unawaited(
          planRunner.run(planId, plan, session: session).then((finished) {
            if (session != null) admin?.touch(serverId);
          }),
        );
      case Shutdown():
        // Each stream's end goes out before the isolate does, and its
        // process goes with the isolate.
        unawaited(logs?.close());
        unawaited(docker?.close());
        commands.close();
        Isolate.exit();
      case EngineRequest():
        uiPort.send(
          RequestRejected(
            message.runtimeType.toString(),
            'not implemented yet (M1a scaffold)',
          ),
        );
      default:
        uiPort.send(
          const RequestRejected(
            '<unknown>',
            'isolate message was not an EngineRequest',
          ),
        );
    }
  }

  // One request at a time, in arrival order, each to completion: an
  // import's save finishes before the next request runs, so answers keep
  // request order and saves never overlap, and nothing is handled before
  // the store is open.
  Future<void> queue =
      SshConfigImportStore.open(
        File(
          '${start.supportDirectory}${Platform.pathSeparator}'
          '$sshConfigImportsFileName',
        ),
      ).then((store) async {
        imports = store;
        // 90 days [E] (03 §8.10); a prune that fails leaves the old
        // records for the next start.
        await audit.prune().catchError((Object _) {});
        sync = await EngineSync.open(
          supportDirectory: Directory(start.supportDirectory),
          access: start.supportDirectoryAccess,
          deviceId: start.deviceId,
          hostKeys: hostKeys,
          keystore: keystore,
          vault: vault,
          transport: syncTransport,
        );
        syncOpened = true;
        syncedServers = await sync.servers();
        synced = await listSynced(syncedServers);
        trustedIds = {...synced.confirmedIds, ...synced.unreadableIds};
        if (links != null) {
          final link = links;
          operations = OperationTracker(
            linkFor: link.link,
            sessionFor: (id) => admin?.session(id),
            readOps: (id) => scheduler?.readOps(id),
            store: await OperationsShownStore.open(
              Directory(start.supportDirectory),
              access: start.supportDirectoryAccess,
            ),
            audit: audit,
            emit: uiPort.send,
            deviceId: start.deviceId,
          );
        }
        refreshFleet();
        capabilities = await CapabilityCache.open(
          Directory(start.supportDirectory),
          access: start.supportDirectoryAccess,
          fleet: fleetIds,
          // A store left as it is saves no import this run, so its fleet
          // says nothing about which servers the user removed.
          purge: switch (store.issue?.kind) {
            ImportStoreIssueKind.leftAsIs ||
            ImportStoreIssueKind.newerVersion => CachePurge.never,
            ImportStoreIssueKind.recovered || null => CachePurge.removedServers,
          },
        );
        // Only a confirmed endpoint is dialed, so a profile cached for a
        // synced server not confirmed now describes another machine. One
        // whose pins could not be read keeps it until they read.
        final unconfirmed = {
          for (final entry in synced.entries)
            if (entry.endpoint != EndpointConfirmation.confirmed &&
                !synced.unreadableIds.contains(entry.serverId))
              entry.serverId,
        };
        if (unconfirmed.isNotEmpty) {
          unawaited(capabilities!.forget(unconfirmed));
        }
      });
  commands.listen((message) {
    // Answered at once rather than queued: the sync operation that asked
    // waits on it, and a slow request ahead in the queue, such as an
    // import's save, would hold it up.
    if (message is AnswerKeystore) {
      keystore.answer(message);
      return;
    }
    queue = queue.then((_) => handle(message));
  });
}
