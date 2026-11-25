import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_host/klabautermann_host.dart' show HostProfile;
import 'package:seance_core/catalog.dart'
    show ConflictAwareHostKeyStore, EndpointPinStore, endpointPinsFileName;
import 'package:seance_core/seance_core.dart'
    show CredentialDraft, HostKey, ImportedHost, Prober, SecretRedactor;

import '../admin/admin_mode.dart';
import '../audit/audit_log.dart';
import '../admin/safety_policy.dart';
import '../certificates/tls_check.dart';
import '../alerts/alert_evaluator.dart';
import '../forwards/port_forwards.dart';
import '../history/history_store.dart';
import '../capabilities/capability_cache.dart';
import '../catalog/engine_recovery.dart';
import '../catalog/engine_sync.dart';
import '../catalog/engine_vault.dart';
import '../catalog/server_drafts.dart'
    show serverConfigOfDraft, serverDraftProblem;
import '../catalog/keystore_channel.dart';
import '../docker/docker_router.dart';
import '../docker/exec_sessions.dart';
import '../fleet/endpoint_pins.dart';
import '../fleet/imported_fleet.dart' show localUserName;
import '../fleet/monitor_set.dart';
import '../fleet/reachability_service.dart';
import '../fleet/ssh_config_entries.dart';
import '../fleet/ssh_config_import_store.dart';
import '../links/credential_source.dart';
import '../links/host_key_pins.dart';
import '../links/channel_quota.dart';
import '../links/connection_tester.dart';
import '../links/link_connector.dart';
import '../links/link_supervisor.dart';
import '../links/prompt_broker.dart';
import '../logs/host_queries.dart';
import '../logs/log_stream_router.dart';
import '../operations/operation_tracker.dart';
import '../operations/operations_shown.dart';
import '../operations/plan_registry.dart';
import '../services/packages.dart';
import '../services/disk_usage.dart';
import '../sampling/sampling_scheduler.dart';
import '../sampling/subscriptions.dart';
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import '../runtime/engine_actions.dart';
import '../runtime/engine_fleet.dart';
import '../runtime/engine_reads.dart';
import '../runtime/engine_sync_chain.dart';
import '../engine/protocol.dart';
import '../engine/request_ids.dart';
import '../engine/engine_isolate.dart' show EngineStart, reportEngineFault;

/// Redacts the lines an export carries (LOG-10, 03 §8.9), as the audit
/// log and operation output are.
final _exportRedactor = SecretRedactor();

/// How long a shutdown waits for open shells to end and write their
/// audit records; a link that went silent cannot hold the quit longer.
const Duration _shutdownGrace = Duration(seconds: 2);

/// The streams whose readings history rolls up, and whose gaps it keeps.
const Set<SampleStream> _historyStreams = {
  SampleStream.overview,
  SampleStream.core,
  SampleStream.fs,
};

/// The engine isolate's state (ENG-11 step 1, ARC-05), moved out of the
/// `engineMain` closure: the fields every request reads and the functions
/// that act on them live in one place, and [run] keeps the closure's
/// ordering, comments and awaits.
///
/// Construction takes the start message and the test seams; [run] returns
/// the command port, builds the services, runs the startup chain and
/// listens for requests.
final class EngineState {
  EngineState(
    this.start, {
    required this.dial,
    required this.testAuthenticator,
    required this.prober,
    required this.syncTransport,
    required this.subscriptions,
    required this.endpointPinStore,
    required this.onSupportWrites,
  });

  final EngineStart start;
  final LinkDialer dial;
  final TestAuthenticatorFactory? testAuthenticator;
  final Prober prober;
  final SyncTransportFactory syncTransport;
  final SamplingSubscriptions? subscriptions;
  final EndpointPinStore? endpointPinStore;
  final void Function(Future<void> Function() drain)? onSupportWrites;

  final ReceivePort commands = ReceivePort('klabautermann engine commands');

  /// The client isolate's port, which every event and answer goes to.
  late final SendPort uiPort;

  // Which streams each server's surfaces subscribed, and the cadence
  // profile (D45), which the scheduler below samples.
  late final SamplingSubscriptions sampling;

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
  // One-shot host reads over each server's ready link (03 §7.6); none
  // while links are off.
  HostQueries? hostQueries;
  // Container shells over the Docker endpoints (03 §7.13); none while
  // links are off.
  ExecSessions? terminals;
  // NET-11 and DKE-09's port forwards (03 §5.11): none while links are off.
  PortForwards? forwards;
  // Admin mode per server (03 §8.2), over the links; none while links are
  // off. The safety policy the app last sent; until then every server is
  // observe-only (SAF-01).
  AdminModeController? admin;
  // Each server's detached operations (03 §7.17), over the links; none
  // while links are off. It opens with the support directory's files.
  OperationTracker? operations;
  var safetyPolicy = const SafetyPolicy();
  var deviceName = '';
  // Previewed plans and the runner of confirmed ones (03 §8.5). A plan
  // runs only on the link generation it was planned on: each server's
  // generation counts the times its link became ready.
  final plans = PlanRegistry();
  late final AuditLog audit;
  final linkGenerations = <String, int>{};
  final readyLinks = <String>{};
  // Each server's latest probe answer, which the planners read for the
  // login uid, the session's path and its SSH port.
  final profiles = <String, HostProfile>{};
  final packageReports = PackageReports(now: () => DateTime.now().toUtc());
  final diskTrees = DiskUsageTrees();
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
  // On-device history (HIS-01): every reading rolled into buckets, opened
  // beside the capability cache with the same purge rule.
  HistoryStore? history;

  // The login name for imported hosts and hops that name no user.
  final localUser = localUserName(Platform.environment);
  // The fleet bookkeeping (ENG-11 step 2, ARC-05), assigned once every
  // dependency it reads exists below. Its state and functions live in
  // [EngineFleet], testable without an isolate.
  late final EngineFleet fleet;
  late final EndpointPinStore endpointPins;
  late final ChannelSyncKeystore keystore;
  late final EngineSync sync;
  var syncOpened = false;
  late final EngineVault vault;
  late final EngineRecovery recovery;
  late final PromptBroker prompts;
  final AlertEvaluator alerts = AlertEvaluator();
  late final ConflictAwareHostKeyStore hostKeys;
  // A pin the user confirms on a link (D15, M5 plan M07), published once
  // sync is open, on its operation chain below.
  var pinConfirmed = (HostKey _) {};
  late final EngineCredentialSource credentials;
  LinkSupervisor? links;
  late final EngineActions actions;
  ConnectionTester? tester;
  // The servers a view holds a link to ([Connect] without its
  // [Disconnect] yet), kept apart from the fleet's monitor set: a server
  // that leaves the set keeps the link a view holds, and a view that
  // leaves keeps a monitored server's link.
  final viewed = <String>{};
  ReachabilityService? reachability;
  late final EngineSyncChain syncChain;
  // The read handlers (ENG-11 step 5, ARC-05), built once startup has
  // opened every store they read, so their history is this run's.
  late final EngineReads reads;
  // What stopped the startup below, if anything. The engine then stays
  // up and refuses every request with it, Hello first, so the app names
  // the error instead of seeing the isolate die unhandled.
  Object? startupFailure;
  late Future<void> queue;

  void reject(EngineRequest request, String reason) => uiPort.send(
    RequestRejected(
      request.runtimeType.toString(),
      reason,
      requestId: requestIdOf(request),
    ),
  );

  void fault(Object error, StackTrace stack) =>
      reportEngineFault(uiPort, error, stack);

  // Starts [work] beside the request queue. Nothing awaits it, so its
  // error has no caller to reach: [onError] answers it, and without one
  // it is reported as a fault. Either way it never reaches the zone as an
  // unhandled error.
  void detach(
    Future<void>? work, {
    void Function(Object error, StackTrace stack)? onError,
  }) {
    if (work == null) return;
    unawaited(
      work.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (onError == null) return fault(error, stack);
          // An answer that throws is a fault too, not an unhandled error.
          try {
            onError(error, stack);
          } on Object catch (error, stack) {
            fault(error, stack);
          }
        },
      ),
    );
  }

  void run() {
    uiPort = start.uiPort;
    uiPort.send(commands.sendPort);

    sampling = subscriptions ?? SamplingSubscriptions();

    // The device audit log (03 §8.10): a record per finished run, in files
    // only while this process has the support directory to itself.
    audit = AuditLog(
      Directory(
        '${start.supportDirectory}${Platform.pathSeparator}$auditDirectoryName',
      ),
      storage: start.supportDirectoryAccess == SupportDirectoryAccess.exclusive
          ? AuditStorage.files
          : AuditStorage.memory,
      deviceId: start.deviceId,
    );

    // The endpoints this device confirmed (D16): `endpoint_pins.json` while
    // the process holds the support directory alone, otherwise memory only.
    // One store for the engine's lifetime, as for the host-key pins.
    endpointPins =
        endpointPinStore ??
        openEndpointPins(
          start.supportDirectory,
          access: start.supportDirectoryAccess,
        );

    // The OS keystore, which the app answers (D62), and sync,
    // opened with the import store.
    keystore = ChannelSyncKeystore(uiPort.send);

    // The one vault over `vault.json` (03 §4.5), which links read and sync
    // re-keys. Until sync has opened, the account is unknown, so the vault
    // mints no master key.
    vault = EngineVault(
      Directory(start.supportDirectory),
      access: start.supportDirectoryAccess,
      keystore: keystore,
      enrolled: () => !syncOpened || sync.account != null,
    );

    // CRED-05's recovery operations over the same vault, with the master
    // key resolved through the vault (so through the same keystore
    // responder) and its exclusive queue (03 §4.5).
    recovery = EngineRecovery(vault);

    // What the engine asks the user while it connects, keyed by prompt id
    // (03 §10.1).
    prompts = PromptBroker(emit: uiPort.send);
    // In-app alerts (ALR-01): every synced rule, on every sample.

    // The host-key pins (03 §4.6, D61): `host_keys.json` while the process
    // holds the support directory alone, otherwise that file's pins read
    // once and kept in memory. One store for the engine's lifetime (P14),
    // shared by its links and the sync coordinator (D63), since two over one
    // file would each write back their own pins. Opening it reads nothing;
    // the first connect or sync operation loads the file.
    hostKeys = openHostKeyPins(
      start.supportDirectory,
      access: start.supportDirectoryAccess,
    );

    // One link per server (03 §5.1, §5.12), dialed through the connector.
    // None while links are off, so nothing in the engine can dial. Pins go
    // to the shared host-key store above. Phones close their links in the
    // background (D34); desktops keep them.
    credentials = EngineCredentialSource(
      identityAuditLogIn(start.supportDirectory),
      vault: vault.read,
    );
    links = start.linksEnabled
        ? LinkSupervisor(
            connect: LinkConnector(
              credentials: credentials,
              saveSecret: vault.save,
              hostKeys: PublishingHostKeyStore(
                hostKeys,
                (pin) => pinConfirmed(pin),
              ),
              prompts: prompts,
              hopConfig: (id) => fleet.configOf(id),
              dial: dial,
            ).connect,
            // Fleet entries only: the fleet's hop configs serve their routes.
            configFor: (id) =>
                fleet.fleetIds.contains(id) ? fleet.configOf(id) : null,
            emit: (event) {
              uiPort.send(event);
              if (event is LinkState) {
                scheduler?.update(event.serverId);
                logs?.update(event.serverId);
                docker?.update(event.serverId);
                forwards?.update(event.serverId);
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
                  terminals?.linkLost(event.serverId);
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

    // The action handlers (ENG-11 step 4, ARC-05), built once the links
    // exist: their runner lends sessions over them, and the read handlers
    // point at their session lender and stack edit lookup. The nullable
    // consumers stay getters because they are assigned in the links block
    // below and the stores and sync arrive in the startup chain.
    actions = EngineActions(
      links: links,
      admin: () => admin,
      audit: audit,
      scheduler: () => scheduler,
      profiles: profiles,
      plans: plans,
      linkGenerations: linkGenerations,
      channelQuotas: channelQuotas,
      docker: () => docker,
      operations: () => operations,
      safetyPolicy: () => safetyPolicy,
      deviceName: () => deviceName,
      fleetIds: () => fleet.fleetIds,
      send: uiPort.send,
      detach: detach,
      reject: reject,
    );

    // The server editor's Test connection (FL-03): the links' credentials,
    // pins and prompts, never their pin publishing, since a test pins
    // nothing. None while links are off, as nothing then dials.
    tester = start.linksEnabled
        ? ConnectionTester(
            credentials: credentials,
            hostKeys: hostKeys,
            prompts: prompts,
            hopConfig: (id) => fleet.configOf(id),
            authenticator: testAuthenticator ?? liveTestAuthenticator,
          )
        : null;

    final supervisor = links;
    if (supervisor != null) {
      admin = AdminModeController(
        linkFor: supervisor.link,
        endpointOf: (id) => switch (fleet.configOf(id)) {
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
          if (event.phase == AdminModePhase.on) {
            actions.verifyFootprint(event.serverId);
          }
          logs?.adminChanged(event.serverId);
          if (event.phase != AdminModePhase.on) {
            terminals?.adminEnded(event.serverId);
          }
          // A root result's cleanup waits for admin mode (03 §7.17).
          if (event.phase == AdminModePhase.on) {
            detach(operations?.adminOn(event.serverId));
          }
        },
      );
      scheduler = SamplingScheduler(
        subscriptions: sampling,
        linkFor: supervisor.link,
        emit: (event) {
          uiPort.send(event);
          if (event is Sample) {
            alerts
                .observe(event.serverId, event.result, event.at)
                .forEach(uiPort.send);
            history?.observe(event.serverId, event.result, event.at);
          }
          if (event is Gap) {
            // Before the reading that resumes the streams, which follows.
            alerts.gap(event.serverId, event.streams);
          }
          if (event is Gap && event.streams.any(_historyStreams.contains)) {
            history?.gap(event.serverId, event.from, event.until, event.cause);
          }
        },
        deadPeerHint: supervisor.deadPeerHint,
        clearDeadPeerHint: supervisor.clearDeadPeerHint,
        probed: (serverId, profile) {
          profiles[serverId] = profile;
          admin?.probed(serverId, profile);
          actions.verifyFootprint(serverId);
          detach(capabilities?.probed(serverId, profile));
          docker?.probed(serverId, profile);
        },
        opsRead: (serverId, section) =>
            detach(operations?.listed(serverId, section)),
        onFault: fault,
      );
      hostQueries = HostQueries(
        linkFor: supervisor.link,
        systemdVersionOf: (serverId) => profiles[serverId]?.systemdVersion,
        emit: uiPort.send,
        readDiagnostics: (serverId) =>
            scheduler?.readDiagnostics(serverId) ?? Future.value(),
      );
      logs = LogStreamRouter(
        linkFor: supervisor.link,
        emit: uiPort.send,
        adminFor: (serverId) => admin?.session(serverId),
        quotas: channelQuotas,
      );
      final router = docker = DockerRouter(
        linkFor: supervisor.link,
        emit: uiPort.send,
        samplerSessions: (serverId) =>
            scheduler?.samplerSessions(serverId) ?? 0,
        adminFor: (serverId) => admin?.session(serverId),
        quotas: channelQuotas,
      );
      forwards = PortForwards(linkFor: supervisor.link, emit: uiPort.send);
      terminals = ExecSessions(
        open: router.openExec,
        control: <T>(serverId, call) =>
            router.useEndpoint(serverId, (client, _) => call(client)),
        emit: uiPort.send,
        fleet: (serverId) => fleet.fleetIds.contains(serverId),
        audit: audit.append,
        deviceId: start.deviceId,
      );
    }

    // Probes the confirmed endpoints (FL-04, 03 §5.12); none while probes
    // are off. A server with a link is answered online without a probe.
    reachability = start.probesEnabled
        ? ReachabilityService(
            emit: uiPort.send,
            hasLink: (id) => links?.link(id) != null,
            prober: prober,
          )
        : null;

    // The fleet object, once every dependency it reads exists. Each
    // nullable consumer is a getter because the links block below assigns
    // it later, and the stores and sync arrive in the startup chain.
    fleet = EngineFleet(
      sampling: sampling,
      alerts: alerts,
      scheduler: () => scheduler,
      logs: () => logs,
      operations: () => operations,
      channelQuotas: channelQuotas,
      links: links,
      viewed: viewed,
      terminals: () => terminals,
      forwards: () => forwards,
      docker: () => docker,
      admin: () => admin,
      plans: plans,
      packageReports: packageReports,
      diskTrees: diskTrees,
      profiles: profiles,
      capabilities: () => capabilities,
      history: () => history,
      reachability: reachability,
      imports: (
        hosts: () => imports.hosts,
        hops: () => imports.hops,
        detail: () => imports.detail,
      ),
      localUser: localUser,
      endpointPins: endpointPins,
      sync: () => sync,
      detach: detach,
      send: uiPort.send,
    );

    // Sync, one operation at a time in request order, beside the
    // request queue rather than in it: an enrollment waits on the network,
    // a key derivation and the app's keystore answers, which arrive as
    // requests, and links, sampling and imports go on meanwhile.
    syncChain = EngineSyncChain(
      sync: () => sync,
      send: uiPort.send,
      alerts: alerts,
      fleetEntries: fleet.fleetEntries,
      syncedFleet: () => fleet.synced,
      refreshSynced: fleet.refreshSynced,
      relistSynced: fleet.relistSynced,
      endpointPins: endpointPins,
      pinPublicationRelease: start.pinPublicationRelease,
      fault: fault,
    );

    pinConfirmed = (pin) {
      if (!syncOpened) return;
      syncChain.chain(
        () => sync.publishPin(pin, release: start.pinPublicationRelease),
      );
    };

    // One request at a time, in arrival order, each to completion: an
    // import's save finishes before the next request runs, so answers keep
    // request order and saves never overlap, and nothing is handled before
    // the store is open.
    queue =
        SshConfigImportStore.open(
              File(
                '${start.supportDirectory}${Platform.pathSeparator}'
                '$sshConfigImportsFileName',
              ),
            )
            .then((store) async {
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
              fleet.syncedServers = await sync.servers();
              fleet.synced = await fleet.listSynced(fleet.syncedServers);
              fleet.trustedIds = {
                ...fleet.synced.confirmedIds,
                ...fleet.synced.unreadableIds,
              };
              final link = links;
              if (link != null) {
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
              fleet.refreshFleet();
              capabilities = await CapabilityCache.open(
                Directory(start.supportDirectory),
                access: start.supportDirectoryAccess,
                fleet: fleet.fleetIds,
                // A store left as it is saves no import this run, so its fleet
                // says nothing about which servers the user removed.
                purge: switch (store.issue?.kind) {
                  ImportStoreIssueKind.leftAsIs ||
                  ImportStoreIssueKind.newerVersion => CachePurge.never,
                  ImportStoreIssueKind.recovered ||
                  null => CachePurge.removedServers,
                },
              );
              history = await HistoryStore.open(
                Directory(start.supportDirectory),
                access: start.supportDirectoryAccess,
                fleet: fleet.fleetIds,
                purge: switch (store.issue?.kind) {
                  ImportStoreIssueKind.leftAsIs ||
                  ImportStoreIssueKind.newerVersion => CachePurge.never,
                  ImportStoreIssueKind.recovered ||
                  null => CachePurge.removedServers,
                },
              );
              // Tests run the engine in their own isolate, where Shutdown cannot
              // exit it, so they drain the stores' queued writes before deleting
              // the support directory.
              onSupportWrites?.call(() async {
                await capabilities?.idle;
                await history?.idle;
              });
              // Only a confirmed endpoint is dialed, so a profile cached for a
              // synced server not confirmed now describes another machine. One
              // whose pins could not be read keeps it until they read.
              final unconfirmed = {
                for (final entry in fleet.synced.entries)
                  if (entry.endpoint != EndpointConfirmation.confirmed &&
                      !fleet.synced.unreadableIds.contains(entry.serverId))
                    entry.serverId,
              };
              if (unconfirmed.isNotEmpty) {
                detach(capabilities!.forget(unconfirmed));
                detach(history!.forget(unconfirmed));
              }
              reads = EngineReads(
                links: links,
                admin: admin,
                audit: audit,
                history: history,
                profiles: profiles,
                packageReports: packageReports,
                diskTrees: diskTrees,
                fleetIds: () => fleet.fleetIds,
                stackEditLookup: actions.stackEditLookup,
                lendSession: actions.lendSession,
                send: uiPort.send,
              );
            })
            .catchError((Object error) {
              startupFailure = error;
            });
    commands.listen((message) {
      // Answered at once rather than queued: the sync operation that asked
      // waits on it, and a slow request ahead in the queue, such as an
      // import's save, would hold it up.
      if (message is AnswerKeystore) {
        keystore.answer(message);
        return;
      }
      // A handler that throws costs its own request, not the engine: left
      // in the chain, the error would skip every later request and, being
      // unhandled, end the isolate with every link and shell.
      queue = queue.then((_) {
        // Shutdown still ends the isolate; its stores are each optional.
        if (startupFailure case final failure? when message is! Shutdown) {
          uiPort.send(
            RequestRejected(
              message is EngineRequest
                  ? message.runtimeType.toString()
                  : '<unknown>',
              'engine failed to start: $failure',
              requestId: message is EngineRequest ? requestIdOf(message) : null,
            ),
          );
          return null;
        }
        return handle(message).catchError((Object error) {
          uiPort.send(
            RequestRejected(
              message is EngineRequest
                  ? message.runtimeType.toString()
                  : '<unknown>',
              'engine error: $error',
              requestId: message is EngineRequest ? requestIdOf(message) : null,
            ),
          );
        });
      });
    });
  }

  // A server's cached profile goes out when a request first names it,
  // since the startup events reach only the app's first listener.
  void sendCachedProfile(String serverId) {
    if (capabilities?.takeCached(serverId) case final cached?) {
      uiPort.send(cached);
    }
  }

  Future<void> replyToRecovery(
    String requestId,
    FutureOr<EngineEvent> Function() action,
  ) async {
    try {
      uiPort.send(await action());
    } on VaultRecoveryException catch (error) {
      uiPort.send(
        VaultRecoveryFailed(requestId: requestId, failure: error.failure),
      );
    } on Object {
      // A malformed stored blob or failed read must neither expose its
      // exception text nor stop the engine's command queue.
      uiPort.send(
        VaultRecoveryFailed(
          requestId: requestId,
          failure: VaultRecoveryFailure.failed,
        ),
      );
    }
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
            pinPublication: syncChain.pinPublicationState(),
          ),
        );
        // The fleet as the engine starts: the servers the last sync left
        // and the imports an earlier run saved (none when the stores were
        // empty or unusable), so the rail shows them before the user does
        // anything.
        uiPort.send(CatalogReplaced(fleet.fleetEntries()));
        fleet.fleetSent = true;
        // The probes start whatever the stored preferences do.
        try {
          await syncChain.sendServerPrefs();
        } on Object catch (error, stack) {
          fault(error, stack);
        }
        fleet.probeFleet();
      case Connect(:final serverId):
        sendCachedProfile(serverId);
        // The app sends it when the user opens the server (03 §10.1), so
        // the connect may prompt, and to a server a changed host key
        // blocked it reviews the key (D61).
        final supervisor = links;
        if (supervisor == null) {
          reject(message, 'links are off in this engine');
        } else if (supervisor.connect(
          serverId,
          purpose: ConnectPurpose.interactive,
        )) {
          viewed.add(serverId);
        } else {
          // A fleet server without a config is the user's to fix, so the
          // app is told why; any other id is not a server it lists.
          switch (fleet.fleetIds.contains(serverId)
              ? fleet.synced.missingConfigReason(serverId) ??
                    fleet.fleet.missingConfigReason(serverId)
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
        final monitoredServer = fleet.monitored.contains(serverId);
        if (monitoredServer && links?.link(serverId) != null) return;
        // Its streams end before its link closes, so none reports
        // waiting for that link first.
        logs?.disconnect(serverId);
        terminals?.linkLost(serverId);
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
      case SetServerCadenceCap(:final serverId, :final cap):
        sampling.capServer(serverId, cap);
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
      case HostQuery(:final serverId):
        switch (hostQueries) {
          case null:
            reject(message, 'links are off in this engine');
          case _ when !fleet.fleetIds.contains(serverId):
            reject(message, 'no fleet server $serverId');
          case final queries:
            // Not awaited: the queue keeps serving while the host answers.
            detach(
              queries.query(message),
              onError: (error, _) => reject(message, 'host query: $error'),
            );
        }
      case RedactLines(:final requestId, :final lines):
        uiPort.send(
          RedactedLines(
            requestId,
            lines.map(_exportRedactor.redact).join('\n'),
          ),
        );
      case CheckTlsEndpoints(:final requestId, :final endpoints):
        // Not awaited: each check may wait out its timeout, and the queue
        // keeps serving meanwhile. checkTlsEndpoint throws no exception;
        // anything else still answers as a failed check, so the request
        // is never left without an answer.
        unawaited(
          Future.wait([
            for (final endpoint in endpoints.take(kTlsEndpointsMax))
              checkTlsEndpoint(endpoint).catchError(
                (Object error) => TlsEndpointCheck(
                  endpoint: endpoint,
                  failure: TlsCheckFailure.connect,
                  detail: '$error',
                ),
              ),
          ]).then(
            (checks) => uiPort.send(TlsEndpointsChecked(requestId, checks)),
          ),
        );
      case OpenTerminal():
        switch (terminals) {
          case null:
            reject(message, 'links are off in this engine');
          case final terminals:
            if (terminals.validate(message) case final problem?) {
              reject(message, problem);
              return;
            }
            terminals.open(message, safetyPolicy);
        }
      case TerminalInput():
        terminals?.input(message);
      case TerminalResize():
        terminals?.resize(message);
      case TerminalEndInput(:final terminalId):
        terminals?.endInput(terminalId);
      case CloseTerminal(:final terminalId):
        terminals?.close(terminalId);
      case OpenPortForward():
        switch (forwards) {
          case null:
            reject(message, 'links are off in this engine');
          case final forwards:
            // Not awaited: the bind and the first channel take a while. A
            // forward that throws rather than reporting its own state is
            // refused by id, so its row does not stay opening.
            detach(
              forwards.open(message),
              onError: (error, _) => reject(message, 'port forward: $error'),
            );
        }
      case ClosePortForward(:final forwardId):
        forwards?.close(forwardId);
      case SetDockerEndpoint():
        switch (docker) {
          case null:
            reject(message, 'links are off in this engine');
          case final docker:
            docker.setEndpoint(message);
        }
      case SetDockerProgram():
        switch (docker) {
          case null:
            reject(message, 'links are off in this engine');
          case final docker:
            docker.setProgram(message);
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
        fleet.refreshFleet();
        uiPort.send(CatalogReplaced(fleet.fleetEntries()));
        uiPort.send(
          SshConfigImported(
            importedCount: result.hosts.length,
            skippedCount: result.skippedCount,
            saved: saved,
          ),
        );
      case ConfirmEndpoints(:final serverIds, :final shown):
        // A server whose endpoint a sync changed since the user looked
        // is left unconfirmed, so nothing pins what nobody saw; the fleet
        // that answers lists it as waiting again. The same shown map
        // gates the route's hops: one the confirmation did not show stays
        // unconfirmed until its own row is confirmed.
        final seen = shown == null
            ? serverIds
            : [
                for (final entry in fleet.synced.entries)
                  if (serverIds.contains(entry.serverId) &&
                      shown[entry.serverId] == ShownEndpoint.of(entry))
                    entry.serverId,
              ];
        // Each pin is saved before it counts. One that cannot be saved
        // leaves its server unconfirmed, and the app is told before the
        // fleet, so the fleet's answer ends the request either way; the
        // others still count.
        Object? failure;
        for (final pin in fleet.synced.pinsFor(
          seen,
          DateTime.now(),
          shown: shown,
        )) {
          try {
            await endpointPins.confirm(pin);
          } on Object catch (error) {
            failure ??= error;
          }
        }
        if (failure != null) {
          reject(message, '$endpointPinsFileName not saved: $failure');
        }
        await fleet.relistSynced();
        uiPort.send(CatalogReplaced(fleet.fleetEntries()));
      case SetMonitorSet(:final serverIds):
        // The app offers only what the engine allows (FL-21), so a
        // rejection means the two saw different fleets; the app's next
        // set follows the fleet that answers it.
        final requested = serverIds.toSet();
        if (requested.length > kMonitorSetLimit) {
          reject(message, 'more than $kMonitorSetLimit servers');
          return;
        }
        final eligible = fleet.monitorEligibleIds();
        fleet.applyMonitorSet(requested.intersection(eligible));
        final skipped = requested.difference(eligible);
        if (skipped.isNotEmpty) {
          reject(message, 'not eligible fleet servers: ${skipped.join(', ')}');
        }
      case EnrollSync(:final requestId):
        syncChain.runSync(
          SyncOperation.enroll,
          () => sync.enroll(message),
          requestId: requestId,
        );
      case RunSyncRound(:final requestId):
        syncChain.runSync(
          SyncOperation.round,
          sync.runRound,
          requestId: requestId,
        );
      case SignOutSync(:final requestId):
        // The fleet refresh after it drops the account's servers, which
        // closes their links and forgets their profiles and history.
        syncChain.runSync(
          SyncOperation.signOut,
          sync.signOut,
          requestId: requestId,
        );
      case ReadPinConflicts():
        // Behind any round already queued, so a read never races the diff
        // that round is about to change.
        syncChain.chain(
          () async =>
              uiPort.send(PinConflictsChanged(await sync.pinConflicts())),
          onError: (error) => reject(message, '$error'),
        );
      case ResolvePinConflict(
        :final locator,
        :final keepLocal,
        :final localFingerprintSha256,
        :final pulledFingerprintSha256,
      ):
        syncChain.chain(() async {
          try {
            final conflicts = await sync.resolvePinConflict(
              locator,
              keepLocal: keepLocal,
              localFingerprintSha256: localFingerprintSha256,
              pulledFingerprintSha256: pulledFingerprintSha256,
            );
            uiPort.send(PinConflictsChanged(conflicts));
          } on Object catch (error) {
            uiPort.send(RequestRejected('ResolvePinConflict', '$error'));
          }
        });
      case ReadServerDraft(:final requestId, :final serverId):
        uiPort.send(
          ServerDraftRead(
            requestId: requestId,
            draft: await sync.serverDraft(serverId),
          ),
        );
      case SaveServer(:final requestId, :final draft):
        syncChain.runWrite(
          requestId,
          () => sync.saveServer(message),
          confirm: draft.id,
        );
      case DuplicateServer(:final requestId, :final serverId):
        // A copy of an endpoint this device confirmed is confirmed too: it
        // is the same endpoint, copied by the user.
        syncChain.runWrite(
          requestId,
          () => sync.duplicateServer(message),
          confirmWritten: fleet.synced.confirmedIds.contains(serverId),
        );
      case DeleteServer(:final requestId):
        syncChain.runWrite(requestId, () => sync.deleteServer(message));
      case TestServerConnection(
        :final requestId,
        :final draft,
        :final credential,
      ):
        final connectionTester = tester;
        if (connectionTester == null) {
          reject(message, 'links are off in this engine');
          return;
        }
        if (serverDraftProblem(draft) != null) {
          reject(message, 'invalid draft');
          return;
        }
        // The stored server, confirmed here or not: the user tests the
        // endpoint the form shows.
        final existing = await sync.storedServer(draft.id);
        final config = serverConfigOfDraft(
          draft,
          existing: existing,
          secretRef: existing?.secretRef,
          now: DateTime.now(),
        );
        // Off the request loop: the test waits on the network and on the
        // user's answers to its prompts.
        detach(
          connectionTester
              .test(
                config,
                CredentialDraft(
                  password: credential.password,
                  privateKeyPem: credential.referenceKeyFile
                      ? null
                      : credential.keyPem,
                  keyPassphrase: credential.keyPassphrase,
                ),
              )
              .then(
                (result) => uiPort.send(
                  ServerConnectionTested(
                    requestId: requestId,
                    ok: result.ok,
                    summary: result.summary,
                    notes: result.notes,
                    log: result.log,
                  ),
                ),
              ),
          onError: (error, _) => reject(message, 'connection test: $error'),
        );
      case SetServerPrefs(:final requestId):
        syncChain.runWrite(requestId, () => sync.setServerPrefs(message));
      case PutRule(:final requestId):
        syncChain.runWrite(requestId, () => sync.putRule(message));
      case RemoveRule(:final requestId):
        syncChain.runWrite(requestId, () => sync.removeRule(message));
      case PlanAction():
        actions.planAction(message);
      case FootprintQuery():
        actions.footprintQuery(message);
      case ReadEditable():
        reads.editable(message);
      case AuditQuery():
        await reads.audit(message);
      case AcknowledgeOperation():
        actions.acknowledgeOperation(message);
      case ReadHistory():
        await reads.history(message);
      case ReadUserCrontabs():
        reads.userCrontabs(message);
      case ReadAccounts():
        reads.accounts(message);
      case ReadDiskUsage():
        reads.diskUsage(message);
      case ReadTimerDetail():
        reads.timerDetail(message);
      case ReadSmart():
        reads.smart(message);
      case ReadRestarts():
        reads.restarts(message);
      case ReadFirewall():
        reads.firewall(message);
      case ReadSshdPosture():
        reads.sshdPosture(message);
      case ReadPackages():
        reads.packages(message);
      case UnitQuery():
        reads.units(message);
      case JobHistoryQuery():
        reads.jobHistory(message);
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
      case SetDeviceName(:final name):
        deviceName = name;
      case SetPinPublication(:final asserted):
        final release = start.pinPublicationRelease;
        if (release == null) {
          reject(message, 'no release is offered for pin publication');
          return;
        }
        syncChain.chain(() async {
          try {
            await sync.setPinPublication(asserted ? release : null);
          } on Object {
            // The enrollment keeps an unsaved change in memory and saves it
            // with the next change (sync_state_file.dart), so the event
            // reports what this session goes by.
          }
          if (syncChain.pinPublicationState() case final state?) {
            uiPort.send(state);
          }
        });
      case SetSyncSecrets(:final enabled):
        // Behind any sync operation already queued, which runs under the
        // switch as it was when it was asked for.
        syncChain.chain(() => sync.setSyncSecrets(enabled: enabled));
      case NewRecoveryCode(:final requestId):
        await replyToRecovery(
          requestId,
          () => RecoveryCodeGenerated(
            requestId: requestId,
            code: recovery.newCode(),
          ),
        );
      // The four below wait for the vault's exclusive queue, which a sync
      // round holds for its whole network phase and an enrollment across
      // its key derivation. They are not awaited, as sync itself is not:
      // the queue keeps serving prompts, shells and Shutdown meanwhile.
      // Each joins the vault's queue before this returns, so they still
      // run in request order, and replyToRecovery answers every failure.
      case SetRecoveryCode(:final requestId, :final code):
        detach(
          replyToRecovery(requestId, () async {
            await recovery.saveCode(code);
            return RecoveryStatus(requestId: requestId, configured: true);
          }),
        );
      case RecoveryStatusRequest(:final requestId):
        detach(
          replyToRecovery(
            requestId,
            () async => RecoveryStatus(
              requestId: requestId,
              configured: await recovery.configured(),
            ),
          ),
        );
      case ExportVault(:final requestId):
        detach(
          replyToRecovery(
            requestId,
            () async => VaultExported(
              requestId: requestId,
              bytes: await recovery.exportSecrets(),
            ),
          ),
        );
      case RestoreVault(
        :final requestId,
        :final export,
        :final code,
        :final policy,
      ):
        detach(
          replyToRecovery(requestId, () async {
            final summary = await recovery.restoreSecrets(
              export,
              code,
              policy: policy,
            );
            return VaultRestored(
              requestId: requestId,
              added: summary.added,
              replaced: summary.replaced,
              kept: summary.kept,
              unreadable: summary.unreadable,
            );
          }),
        );
      case SetAdminMode(:final serverId, :final enabled):
        if (!fleet.fleetIds.contains(serverId)) {
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
        // enable reports its own failures as AdminModeState.
        detach(admin!.enable(serverId));
      case CancelAction():
        actions.cancelAction(message);
      case RunAction():
        actions.runAction(message);
      case Shutdown():
        // The buckets still filling are written and open shells end,
        // side by side within one grace, so their TerminalClosed and audit
        // records are not cut off by Isolate.exit. Each stream's end goes
        // out before the isolate does, and its process goes with the
        // isolate.
        await Future.wait([
          ?history?.flush().timeout(_shutdownGrace, onTimeout: () {}),
          ?capabilities?.idle.timeout(_shutdownGrace, onTimeout: () {}),
          ?terminals?.dispose().timeout(_shutdownGrace, onTimeout: () {}),
        ]);
        unawaited(logs?.close());
        unawaited(docker?.close());
        forwards?.dispose();
        commands.close();
        Isolate.exit();
      // The request kinds with no handler above. [AnswerKeystore] is
      // normally taken ahead of the queue, so this is its fallback too.
      case HandleAlert():
      case AnswerKeystore():
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
}
