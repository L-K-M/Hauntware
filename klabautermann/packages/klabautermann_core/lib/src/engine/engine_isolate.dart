import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:seance_core/catalog.dart'
    show EndpointPin, EndpointPinStore, endpointPinsFileName;
import 'package:seance_core/seance_core.dart'
    show ImportedHost, ServerConfig, SshLink;

import '../capabilities/capability_cache.dart';
import '../catalog/engine_sync.dart';
import '../catalog/keystore_channel.dart';
import '../docker/docker_router.dart';
import '../fleet/endpoint_pins.dart';
import '../fleet/imported_fleet.dart';
import '../fleet/ssh_config_entries.dart';
import '../fleet/ssh_config_import_store.dart';
import '../fleet/synced_fleet.dart';
import '../links/credential_source.dart';
import '../links/host_key_pins.dart';
import '../links/link_connector.dart';
import '../links/link_supervisor.dart';
import '../links/prompt_broker.dart';
import '../logs/log_stream_router.dart';
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
    this.supportDirectoryAccess = SupportDirectoryAccess.unguarded,
    this.deviceId,
  });

  /// The client isolate's port.
  final SendPort uiPort;

  /// The absolute path of the app's support directory.
  final String supportDirectory;

  /// Whether the engine opens SSH links (03 §5.1, §10.1). Without them it
  /// has no link supervisor, sampling scheduler, log streams or Docker
  /// sessions: [Connect], [OpenLogStream] and [DockerQuery] get
  /// [RequestRejected] and nothing dials, samples or reads,
  /// [CloseStream], [Disconnect], [RefreshSubscription] and
  /// [SetAppActivity] change nothing, subscriptions are only recorded,
  /// and no [Prompt] is ever open. The app's composition root leaves
  /// them off; tests turn them on.
  final bool linksEnabled;

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
/// server's link (03 §5.2, §7.6), a [DockerQuery] goes to its server's
/// Docker session, which finds and negotiates the endpoint over the link
/// once the probe has answered and reports it as [DockerEndpointState]
/// (03 §5.8, §5.9), [EnrollSync] and [RunSyncRound] run pull-only sync
/// one at a time beside the request queue (03 §4.3, D63), answered by
/// [SyncStatus] and, when they succeed, the fleet, after an
/// [EndpointChanged] for each confirmed endpoint a round changed (03
/// §4.7), [ConfirmEndpoints] pins synced endpoints and answers with the
/// fleet, a [Connect] to an unconfirmed synced server gets
/// [ConnectRejected],
/// [AnswerKeystore] completes the keystore call it names ahead of the
/// queue, [Shutdown] ends every log stream and exits, and every other
/// 03 §10.1 row gets [RequestRejected] until its milestone lands.
///
/// [dial] replaces `SshLink.connect`, so tests can run the engine's links
/// without a network, and [syncTransport] the sync server's HTTP client.
/// [subscriptions], when given, holds the sampling subscriptions, so
/// tests can read them, and [endpointPinStore] replaces the endpoint pins
/// [openEndpointPins] opens, so tests can fail their reads.
void engineMain(
  EngineStart start, {
  @visibleForTesting LinkDialer dial = SshLink.connect,
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
            ),
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
            }
          },
          policy: Platform.isAndroid || Platform.isIOS
              ? BackgroundLinkPolicy.closeAfterGrace
              : BackgroundLinkPolicy.keepOpen,
        )
      : null;
  if (links != null) {
    scheduler = SamplingScheduler(
      subscriptions: sampling,
      linkFor: links.link,
      emit: uiPort.send,
      deadPeerHint: links.deadPeerHint,
      clearDeadPeerHint: links.clearDeadPeerHint,
      probed: (serverId, profile) {
        unawaited(capabilities?.probed(serverId, profile));
        docker?.probed(serverId, profile);
      },
    );
    logs = LogStreamRouter(linkFor: links.link, emit: uiPort.send);
    docker = DockerRouter(linkFor: links.link, emit: uiPort.send);
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
    links?.forget(before.difference(fleetIds));
    final forgotten = {
      for (final id in before)
        if (!fleetIds.contains(id) ||
            previous?.endpointOf(id) != fleet.endpointOf(id))
          id,
    };
    docker
      ?..forget(forgotten)
      ..retain(fleetIds);
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
          ),
        );
        // The fleet as the engine starts: the servers the last sync left
        // and the imports an earlier run saved (none when the stores were
        // empty or unusable), so the rail shows them before the user does
        // anything.
        uiPort.send(CatalogReplaced(fleetEntries()));
      case Connect(:final serverId):
        sendCachedProfile(serverId);
        // The app sends it when the user opens the server (03 §10.1), so
        // the connect may prompt, and to a server a changed host key
        // blocked it reviews the key (D61).
        if (links == null) {
          reject(message, 'links are off in this engine');
        } else if (!links.connect(
          serverId,
          purpose: ConnectPurpose.interactive,
        )) {
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
        // Its streams end before its link closes, so none reports
        // waiting for that link first.
        logs?.disconnect(serverId);
        docker?.disconnect(serverId);
        links?.disconnect(serverId);
      case SetAppActivity(:final activity):
        links?.setActivity(activity);
        scheduler?.activity = activity;
        logs?.activity = activity;
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
      case OpenLogStream():
        final reason = switch (logs) {
          null => 'links are off in this engine',
          final logs => logs.open(message),
        };
        if (reason != null) reject(message, reason);
      case CloseStream(:final streamId):
        logs?.closeStream(streamId);
      case DockerQuery():
        switch (docker) {
          case null:
            reject(message, 'links are off in this engine');
          case final docker:
            docker.query(message);
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
      case EnrollSync():
        runSync(SyncOperation.enroll, () => sync.enroll(message));
      case RunSyncRound():
        runSync(SyncOperation.round, sync.runRound);
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
        sync = await EngineSync.open(
          supportDirectory: Directory(start.supportDirectory),
          access: start.supportDirectoryAccess,
          deviceId: start.deviceId,
          hostKeys: hostKeys,
          keystore: keystore,
          transport: syncTransport,
        );
        syncedServers = await sync.servers();
        synced = await listSynced(syncedServers);
        trustedIds = {...synced.confirmedIds, ...synced.unreadableIds};
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
