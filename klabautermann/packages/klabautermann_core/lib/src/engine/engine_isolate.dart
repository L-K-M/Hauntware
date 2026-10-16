import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart'
    show ImportedHost, InMemoryHostKeyStore, SshLink;

import '../capabilities/capability_cache.dart';
import '../fleet/imported_fleet.dart';
import '../fleet/ssh_config_entries.dart';
import '../fleet/ssh_config_import_store.dart';
import '../links/credential_source.dart';
import '../links/link_connector.dart';
import '../links/link_supervisor.dart';
import '../links/prompt_broker.dart';
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
  });

  /// The client isolate's port.
  final SendPort uiPort;

  /// The absolute path of the app's support directory.
  final String supportDirectory;

  /// Whether the engine opens SSH links (03 §5.1, §10.1). Without them it
  /// has no link supervisor and no sampling scheduler: [Connect] gets
  /// [RequestRejected] and nothing dials or samples, [Disconnect] and
  /// [SetAppActivity] change nothing, subscriptions are only recorded,
  /// and no [Prompt] is ever open. The app's composition root leaves
  /// them off; tests turn them on.
  final bool linksEnabled;

  /// Whether this process alone uses [supportDirectory]: the engine writes
  /// and purges its capability cache there only then (03 §4.10, D59).
  final SupportDirectoryAccess supportDirectoryAccess;
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
/// (03 §6.4; links off, nothing samples), a server's cached profile goes
/// out as a [HostProfileChanged] when a [Connect] or [Subscribe] first
/// names it (03 §6.1, D59), [ImportSshConfig] gets
/// [CatalogReplaced] and [SshConfigImported], [Connect], [Disconnect] and
/// [SetAppActivity] go to the link supervisor and [AnswerPrompt] to the
/// prompt broker (03 §5.1), [CloseStream] does nothing (no log stream is
/// open), [Shutdown] exits, and every other 03 §10.1 row, [OpenLogStream]
/// included, gets [RequestRejected] until its milestone lands.
///
/// [dial] replaces `SshLink.connect`, so tests can run the engine's links
/// without a network. [subscriptions], when given, holds the sampling
/// subscriptions, so tests can read them.
void engineMain(
  EngineStart start, {
  @visibleForTesting LinkDialer dial = SshLink.connect,
  @visibleForTesting SamplingSubscriptions? subscriptions,
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

  // The fleet the engine serves, with the config of each server and hop it
  // can dial, and its server ids. Synced entries lead it once the catalog
  // library lands (F3).
  late ImportedFleet fleet;
  var fleetIds = <String>{};

  // What the engine asks the user while it connects, keyed by prompt id
  // (03 §10.1).
  final prompts = PromptBroker(emit: uiPort.send);

  // One link per server (03 §5.1, §5.12), dialed through the connector.
  // None while links are off, so nothing in the engine can dial. Host-key
  // pins live in memory until the catalog library's `host_keys.json`
  // lands (03 §4.10), so they last for this engine's lifetime only.
  // Phones close their links in the background (D34); desktops keep them.
  final links = start.linksEnabled
      ? LinkSupervisor(
          connect: LinkConnector(
            credentials: EngineCredentialSource(
              identityAuditLogIn(start.supportDirectory),
            ),
            hostKeys: InMemoryHostKeyStore(),
            prompts: prompts,
            hopConfig: (id) => fleet.serverConfig(id),
            dial: dial,
          ).connect,
          // Fleet entries only: the fleet's hop configs serve their routes.
          configFor: (id) =>
              fleetIds.contains(id) ? fleet.serverConfig(id) : null,
          emit: (event) {
            uiPort.send(event);
            if (event is LinkState) scheduler?.update(event.serverId);
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
      probed: (serverId, profile) =>
          unawaited(capabilities?.probed(serverId, profile)),
    );
  }

  // Rebuilds the fleet from the store. A server that left it is forgotten
  // (03 §5.1): its samplers, link and attempts end and its subscriptions
  // go.
  void refreshFleet() {
    fleet = ImportedFleet(
      imports.hosts,
      hops: imports.hops,
      localUser: localUser,
      detail: imports.detail,
    );
    final before = fleetIds;
    fleetIds = {for (final entry in fleet.entries) entry.serverId};
    sampling.fleet = fleetIds;
    scheduler?.retain(fleetIds);
    links?.forget(before.difference(fleetIds));
    unawaited(capabilities?.forget(before.difference(fleetIds)));
  }

  // A server's cached profile goes out when a request first names it,
  // since the startup events reach only the app's first listener.
  void sendCachedProfile(String serverId) {
    if (capabilities?.takeCached(serverId) case final cached?) {
      uiPort.send(cached);
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
          EngineReady(kEngineProtocolVersion, importStoreIssue: imports.issue),
        );
        // The fleet as the engine starts: the imports an earlier run saved
        // (none when the store was empty or unusable), so the rail shows
        // them before the user does anything.
        uiPort.send(CatalogReplaced(fleet.entries));
      case Connect(:final serverId):
        sendCachedProfile(serverId);
        // The app sends it when the user opens the server (03 §10.1), so
        // the connect may prompt.
        if (links == null) {
          reject(message, 'links are off in this engine');
        } else if (!links.connect(
          serverId,
          purpose: ConnectPurpose.interactive,
        )) {
          reject(message, 'no fleet server $serverId the engine can dial');
        }
      case Disconnect(:final serverId):
        links?.disconnect(serverId);
      case SetAppActivity(:final activity):
        links?.setActivity(activity);
        scheduler?.activity = activity;
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
      case SetCadenceProfile(:final profile):
        sampling.profile = profile;
        scheduler?.profileChanged();
      case CloseStream():
        // Closing a stream that is not open does nothing (03 §10.1), and
        // none is: until the log service lands, OpenLogStream gets
        // RequestRejected, since no answer would leave its view waiting.
        break;
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
        // the answer says it was not kept.
        final saved = await imports.replace(result.hosts, hops: result.hops);
        refreshFleet();
        uiPort.send(CatalogReplaced(fleet.entries));
        uiPort.send(
          SshConfigImported(
            importedCount: result.hosts.length,
            skippedCount: result.skippedCount,
            saved: saved,
          ),
        );
      case Shutdown():
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
      });
  commands.listen((message) {
    queue = queue.then((_) => handle(message));
  });
}
