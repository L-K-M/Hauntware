import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'container_usage.dart';
import 'docker_endpoint_choices.dart';

/// The app's Docker endpoints for one engine run (03 §5.9, §10.1): each
/// server's [DockerEndpointState], which the server header names in
/// every mode (E4) and the Docker tab's gate follows, and the engine's
/// details (DKE-01) for the tab's engine strip.
///
/// The engine reports a server's endpoint only once a [DockerQuery] has
/// named it, and from then follows the server's link and probe itself
/// until the app lets the link go (03 §5.9). So each time a server's
/// link comes up, this sends one [DockerEngineQuery]: it starts the
/// endpoint, and answers with the engine's details once the endpoint is
/// ready, or with why not, which the endpoint's own state then says. A
/// Docker tab that shows the server ([openView]) has the details read
/// again whenever a ready endpoint has none: after a new route or API
/// version, or a read that failed.
///
/// A Containers view that shows a server ([watchContainers]) has its
/// containers and their list stats watched (03 §7.12 CTR-01, CST-01): one
/// [DockerWatch] per server while any such view shows, replaced under its
/// id as the rows on screen change ([showStatsFor]), and a
/// [DockerUnwatch] once the last view hides. The engine keeps a watch
/// across a dropped endpoint and resumes it over the next one, so only
/// the views start and end it. The lists it delivers stay here
/// ([containersFor]) after the views hide.
///
/// An Overview that shows a server ([watchSummary]) has its containers
/// and images watched for 02 OV-05's summary and OV-02's unhealthy
/// containers: a [DockerWatch] of its own, apart from the Containers
/// view's, which the engine serves from one `/events` stream per server
/// and answers at once from the lists it holds. It is sent only once the
/// endpoint is ready, so a server without Docker is never watched, and
/// ends when the last Overview hides. [measureDiskUse] reads
/// `/system/df` on demand ([diskUseFor]), since it is slow on large
/// hosts.
///
/// An Images view that shows a server ([watchImages]) has its images
/// watched with its containers (03 §7.14 IMG-01): a [DockerWatch] of its
/// own, one per server while any such view shows, which the engine
/// serves from the server's one `/events` stream. The containers come
/// along because they tell which images are in use: below API 1.51 the
/// image list carries no count, and at any version a container event
/// re-lists the containers but not the images, so only the container
/// list follows a container created or removed.
///
/// A Volumes view that shows a server ([watchVolumes]) has its volumes
/// watched with its containers (03 §7.15 VOL-01), as an Images view has
/// its images: the containers' mounts tell which volumes are in use, and
/// a container event re-lists the containers but not the volumes.
///
/// A Networks view that shows a server ([watchNetworks]) has its
/// networks watched with its containers (03 §7.15 DNW-01), as a Volumes
/// view has its volumes: the containers tell which networks are in use.
///
/// A Stacks view that shows a server ([watchStacks]) has its compose
/// stacks watched (03 §7.16 STK-01, STK-02, STK-05): a [DockerWatch] of
/// the stacks alone, one per server while any such view shows. Asking
/// for the stacks starts the engine's source checks, which run compose
/// commands on the host (`test -f`, `compose config --hash`), and a
/// watch that asks again runs them again, so only a shown Stacks view
/// holds it and nothing else asks. The engine sends a project it has not
/// checked as [StackVerifying] and the list again once it has. The
/// stacks carry the full container list, so details views follow it as
/// they follow the container watch's.
///
/// A stack file view reads one file of a verified stack at a time
/// ([readStackFile], 03 §7.16 STK-04, M11): one [DockerStackFileQuery]
/// per read, whose answer goes to the view that asked and is not kept
/// here, since the file is read fresh for each query and masked by the
/// engine.
///
/// A details view that shows a container ([openContainer]) has it
/// inspected (03 §7.12 CTR-03, CTR-04): one [DockerContainerQuery] as the
/// first view opens, and another whenever the container's row in a
/// delivered list changes, or a read that waited on the endpoint can run
/// once it is ready again. A list without the container, or an inspect
/// the engine answers with [DockerQueryFailure.notFound], says it was
/// removed. The details live here only while a view shows them: inspect
/// output is never kept, synced or stored (03 §8.9).
///
/// Each server's engine socket choice (CN-09, D54) comes from
/// [endpointChoices], which outlives the run: it goes to the engine as a
/// [SetDockerEndpoint] ahead of the endpoint query each time the server's
/// link comes up, so the first route found already uses it, and again
/// whenever it changes while the link is up ([chooseEndpoint], or a purge
/// for SYN-08). The engine keeps a choice across links, so an automatic
/// one is sent again only after a socket was.
///
/// An Access tab that shows a server ([openAccess]) has its compose CLIs
/// read (CN-24, 03 §7.16 STK-05): one [DockerComposeQuery] once its
/// endpoint is ready, again for each new route; a stacks list that names
/// them answers too.
///
/// Every query and watch id is minted here and never reused this run; at
/// most one engine query and one disk use query per server are in
/// flight, and at most one inspect per container a view shows. A server
/// that leaves the fleet takes its state with it and comes back without
/// it (SYN-08), as in `MonitoringController`; the engine ends its
/// session, and with it the server's watches, too.
final class DockerController {
  /// [endpointChoices] holds the socket chosen per server on this device;
  /// without it the choices live in memory for this run. [now] stamps disk
  /// use measurements, as the monitoring clock reads.
  DockerController(
    this._engine, {
    DockerEndpointChoices? endpointChoices,
    this._now = DateTime.now,
  }) : endpointChoices = endpointChoices ?? DockerEndpointChoices(),
       _ownsChoices = endpointChoices == null {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
    this.endpointChoices.addListener(_onChoices);
  }

  final EngineClient _engine;

  /// Each server's engine socket choice (CN-09), which the engine strip's
  /// picker shows and changes through [chooseEndpoint].
  final DockerEndpointChoices endpointChoices;
  final bool _ownsChoices;
  final DateTime Function() _now;
  late final StreamSubscription<EngineEvent> _events;
  int _count = 0;
  bool _stopped = false;

  final Map<String, _DockerServer> _servers = {};

  /// Details still shown for servers that left the fleet (SYN-08), by
  /// server and container id. Each says so and keeps what was read until
  /// its last view closes, since a view holds its listenable that long.
  final Map<(String, String), _InspectedContainer> _leftFleet = {};

  /// The fleet's ids from the last [CatalogReplaced] seen, as in
  /// `MonitoringController`: null until then, when every server counts
  /// as listed.
  Set<String>? _fleetIds;

  /// What the engine last said of [serverId]'s Docker endpoint, or null
  /// before it said anything this run.
  ValueListenable<DockerEndpointState?> endpointFor(String serverId) =>
      _server(serverId).endpoint;

  /// The engine's details for [serverId]'s ready endpoint: a
  /// [DockerEnginePayload], or a [DockerQueryFailed] saying why they
  /// could not be read; null while none were read for this endpoint.
  ValueListenable<DockerPayload?> engineFor(String serverId) =>
      _server(serverId).engine;

  /// The compose CLIs on [serverId]'s ready endpoint: a
  /// [DockerComposePayload], or a [DockerQueryFailed] saying why they
  /// could not be read; null while none were read for this endpoint.
  ValueListenable<DockerPayload?> composeFor(String serverId) =>
      _server(serverId).compose;

  /// Makes [choice] [serverId]'s engine socket (CN-09) and sends it to the
  /// engine while the link is up, which resolves the endpoint again with
  /// it. Rethrows a save that failed; the choice holds for this run.
  Future<void> chooseEndpoint(String serverId, DockerEndpointChoice choice) =>
      endpointChoices.choose(serverId, choice);

  /// Sends each linked server's choice that the engine was not given yet.
  void _onChoices() {
    for (final MapEntry(key: serverId, value: server) in _servers.entries) {
      if (server.linked) _sendChoice(serverId, server);
    }
  }

  /// Sends [serverId]'s choice unless the engine holds it already: the
  /// last one sent, or automatic before any was. [always] sends a socket
  /// choice even so, as a link comes up: the engine forgets choices with
  /// the server (SYN-08), which this controller may not have seen yet.
  void _sendChoice(
    String serverId,
    _DockerServer server, {
    bool always = false,
  }) {
    final choice = endpointChoices.choiceFor(serverId);
    final held = server.sentChoice ?? const DockerEndpointAuto();
    if (choice == held && !(always && choice is DockerEndpointSocket)) return;
    if (_stopped) return;

    _send(SetDockerEndpoint(serverId: serverId, choice: choice));
    server.sentChoice = choice;
  }

  /// An Access tab shows [serverId]; [closeAccess] says it no longer does.
  void openAccess(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.accessViews++;
    _readComposeIfShown(serverId, server);
  }

  void closeAccess(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.accessViews == 0) return;
    server.accessViews--;
  }

  /// Reads the compose CLIs of a ready endpoint an Access tab shows,
  /// unless they were read or are being read.
  void _readComposeIfShown(String serverId, _DockerServer server) {
    if (server.accessViews == 0 || server.composeQuery != null) return;
    if (server.endpoint.value?.phase != DockerEndpointPhase.ready) return;
    if (server.compose.value is DockerComposePayload) return;
    if (_stopped) return;

    final queryId = 'compose-${_count++}';
    _send(
      DockerQuery(
        serverId: serverId,
        queryId: queryId,
        query: const DockerComposeQuery(),
      ),
    );
    if (!_stopped) server.composeQuery = queryId;
  }

  /// What [serverId]'s watches last delivered of its containers, the
  /// Containers view's or the Overview's: the containers and their list
  /// stats, or why they could not be read.
  ValueListenable<DockerContainerList> containersFor(String serverId) =>
      _server(serverId).containers;

  /// What [serverId]'s watches last delivered of its images, or why they
  /// could not be read.
  ValueListenable<DockerImageList> imagesFor(String serverId) =>
      _server(serverId).images;

  /// What [serverId]'s watches last delivered of its volumes, or why they
  /// could not be read.
  ValueListenable<DockerVolumeList> volumesFor(String serverId) =>
      _server(serverId).volumes;

  /// What [serverId]'s watches last delivered of its networks, or why they
  /// could not be read.
  ValueListenable<DockerNetworkList> networksFor(String serverId) =>
      _server(serverId).networks;

  /// What [serverId]'s events watch last delivered of the events
  /// timeline (DKE-03), or why it could not be read.
  ValueListenable<DockerEventList> eventsFor(String serverId) =>
      _server(serverId).events;

  /// [serverId]'s last disk use measurement ([measureDiskUse]).
  ValueListenable<DockerDiskUse> diskUseFor(String serverId) =>
      _server(serverId).diskUse;

  /// An Overview shows [serverId]; [unwatchSummary] says it no longer
  /// does. The containers and images are watched while any does and the
  /// endpoint has been ready since.
  void watchSummary(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.summaryViews++;
    _syncSummary(serverId, server);
  }

  void unwatchSummary(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.summaryViews == 0) return;
    server.summaryViews--;
    _syncSummary(serverId, server);
  }

  /// Watches the summary's lists anew after a failure, under a new id, as
  /// [retryContainers] does.
  void retrySummary(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.summaryWatchId == null) return;

    _unwatchSummary(serverId, server);
    _syncSummary(serverId, server);
  }

  /// Sends the summary watch while an Overview shows the server and its
  /// endpoint is ready, and ends it once none shows. The engine keeps it
  /// across a dropped endpoint.
  void _syncSummary(String serverId, _DockerServer server) {
    if (server.summaryViews == 0) {
      _unwatchSummary(serverId, server);
      return;
    }
    if (server.summaryWatchId != null || _stopped) return;
    if (server.endpoint.value?.phase != DockerEndpointPhase.ready) return;

    final watchId = server.summaryWatchId = 'summary-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.containers, DockerWatchList.images},
      ),
    );
  }

  void _unwatchSummary(String serverId, _DockerServer server) {
    final watchId = server.summaryWatchId;
    server.summaryWatchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  /// What [serverId]'s stack watch last delivered: the compose projects
  /// with their source verdicts and the compose CLI found, or why they
  /// could not be read.
  ValueListenable<DockerStackList> stacksFor(String serverId) =>
      _server(serverId).stacks;

  /// A Stacks view shows [serverId]; [unwatchStacks] says it no longer
  /// does. The first view starts the server's stack watch, and with it
  /// the engine's source checks.
  void watchStacks(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.stackViews++;
    if (server.stackViews > 1) return;

    _watchStacks(serverId, server);
  }

  /// The last view to hide ends the server's stack watch.
  void unwatchStacks(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.stackViews == 0) return;
    server.stackViews--;
    if (server.stackViews > 0) return;

    _unwatchStacks(serverId, server);
  }

  /// Watches [serverId]'s stacks anew after a failure, under a new id, as
  /// [retryContainers] does; the engine checks the sources again.
  void retryStacks(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.stacksWatchId == null) return;

    _unwatchStacks(serverId, server);
    _watchStacks(serverId, server);
  }

  void _watchStacks(String serverId, _DockerServer server) {
    if (_stopped) return;

    final watchId = server.stacksWatchId ??= 'stacks-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.stacks},
      ),
    );
  }

  void _unwatchStacks(String serverId, _DockerServer server) {
    final watchId = server.stacksWatchId;
    server.stacksWatchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  /// Reads [path], one of the compose project [project]'s files, on
  /// [serverId] (STK-04): a [DockerStackFilePayload] whose spans are
  /// masked by the engine, a [DockerStackFileFailed] saying why the
  /// engine read no file, or a [DockerQueryFailed] when the query could
  /// not run, as when the engine stops or the server leaves the fleet
  /// first. Nothing of the answer stays here.
  Future<DockerPayload> readStackFile(
    String serverId, {
    required String project,
    required String path,
  }) => _ask(serverId, DockerStackFileQuery(project: project, path: path));

  /// The profiles a verified [project]'s files name on [serverId]
  /// (STK-09): a [DockerStackProfilesPayload], a [DockerStackFileFailed]
  /// when the project is unknown or unverified, or a [DockerQueryFailed].
  Future<DockerPayload> readStackProfiles(
    String serverId, {
    required String project,
  }) => _ask(serverId, DockerStackProfilesQuery(project));

  /// The compose files in [folders] on [serverId] and the folders below
  /// them (STK-08): a [DockerStackScanPayload] or a [DockerQueryFailed].
  Future<DockerPayload> scanStacks(String serverId, List<String> folders) =>
      _ask(serverId, DockerStackScanQuery(folders));

  /// The history of [image], a reference or id, on [serverId] (IMG-04):
  /// a [DockerImageHistoryPayload] whose instructions the engine masked,
  /// or a [DockerQueryFailed]. Nothing of the answer stays here.
  Future<DockerPayload> readImageHistory(String serverId, String image) =>
      _ask(serverId, DockerImageHistoryQuery(image));

  /// The processes of [containerId] on [serverId] (CTR-10): a
  /// [DockerContainerTopPayload] whose command lines the engine masked,
  /// or a [DockerQueryFailed]. Nothing of the answer stays here.
  Future<DockerPayload> readContainerTop(String serverId, String containerId) =>
      _ask(serverId, DockerContainerTopQuery(containerId));

  /// Sends [spec] once and completes with the engine's answer, as
  /// [readStackFile] describes.
  Future<DockerPayload> _ask(String serverId, DockerQuerySpec spec) {
    if (!_listed(serverId)) {
      return Future.value(
        const DockerQueryFailed(DockerQueryFailure.notInFleet),
      );
    }
    if (_stopped) {
      return Future.value(
        const DockerQueryFailed(DockerQueryFailure.cancelled),
      );
    }

    final queryId = 'stack-file-${_count++}';
    _send(DockerQuery(serverId: serverId, queryId: queryId, query: spec));
    if (_stopped) {
      return Future.value(
        const DockerQueryFailed(DockerQueryFailure.cancelled),
      );
    }
    final read = Completer<DockerPayload>();
    _server(serverId).fileReads[queryId] = read;
    return read.future;
  }

  /// An Images view shows [serverId]; [unwatchImages] says it no longer
  /// does. The first view starts the server's image watch.
  void watchImages(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.imageViews++;
    if (server.imageViews > 1) return;

    _watchImages(serverId, server);
  }

  /// The last view to hide ends the server's image watch.
  void unwatchImages(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.imageViews == 0) return;
    server.imageViews--;
    if (server.imageViews > 0) return;

    _unwatchImages(serverId, server);
  }

  /// Watches [serverId]'s images anew after a failure, under a new id, as
  /// [retryContainers] does.
  void retryImages(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.imagesWatchId == null) return;

    _unwatchImages(serverId, server);
    _watchImages(serverId, server);
  }

  void _watchImages(String serverId, _DockerServer server) {
    if (_stopped) return;

    final watchId = server.imagesWatchId ??= 'images-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.images, DockerWatchList.containers},
      ),
    );
  }

  void _unwatchImages(String serverId, _DockerServer server) {
    final watchId = server.imagesWatchId;
    server.imagesWatchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  /// A Volumes view shows [serverId]; [unwatchVolumes] says it no longer
  /// does. The first view starts the server's volume watch.
  void watchVolumes(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.volumeViews++;
    if (server.volumeViews > 1) return;

    _watchVolumes(serverId, server);
  }

  /// The last view to hide ends the server's volume watch.
  void unwatchVolumes(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.volumeViews == 0) return;
    server.volumeViews--;
    if (server.volumeViews > 0) return;

    _unwatchVolumes(serverId, server);
  }

  /// Watches [serverId]'s volumes anew after a failure, under a new id, as
  /// [retryContainers] does.
  void retryVolumes(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.volumesWatchId == null) return;

    _unwatchVolumes(serverId, server);
    _watchVolumes(serverId, server);
  }

  void _watchVolumes(String serverId, _DockerServer server) {
    if (_stopped) return;

    final watchId = server.volumesWatchId ??= 'volumes-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.volumes, DockerWatchList.containers},
      ),
    );
  }

  void _unwatchVolumes(String serverId, _DockerServer server) {
    final watchId = server.volumesWatchId;
    server.volumesWatchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  /// A Networks view shows [serverId]; [unwatchNetworks] says it no
  /// longer does. The first view starts the server's network watch.
  void watchNetworks(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.networkViews++;
    if (server.networkViews > 1) return;

    _watchNetworks(serverId, server);
  }

  /// The last view to hide ends the server's network watch.
  void unwatchNetworks(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.networkViews == 0) return;
    server.networkViews--;
    if (server.networkViews > 0) return;

    _unwatchNetworks(serverId, server);
  }

  /// Watches [serverId]'s networks anew after a failure, under a new id,
  /// as [retryContainers] does.
  void retryNetworks(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.networksWatchId == null) return;

    _unwatchNetworks(serverId, server);
    _watchNetworks(serverId, server);
  }

  void _watchNetworks(String serverId, _DockerServer server) {
    if (_stopped) return;

    final watchId = server.networksWatchId ??= 'networks-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.networks, DockerWatchList.containers},
      ),
    );
  }

  void _unwatchNetworks(String serverId, _DockerServer server) {
    final watchId = server.networksWatchId;
    server.networksWatchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  /// An Events view shows [serverId]; [unwatchEvents] says it no longer
  /// does. The first view starts the server's events watch (DKE-03).
  void watchEvents(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.eventViews++;
    if (server.eventViews > 1) return;

    _watchEvents(serverId, server);
  }

  /// The last view to hide ends the server's events watch.
  void unwatchEvents(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.eventViews == 0) return;
    server.eventViews--;
    if (server.eventViews > 0) return;

    _unwatchEvents(serverId, server);
  }

  /// Watches [serverId]'s events anew after a failure, under a new id,
  /// as [retryContainers] does.
  void retryEvents(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.eventsWatchId == null) return;

    _unwatchEvents(serverId, server);
    _watchEvents(serverId, server);
  }

  void _watchEvents(String serverId, _DockerServer server) {
    if (_stopped) return;

    final watchId = server.eventsWatchId ??= 'events-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.events},
      ),
    );
  }

  void _unwatchEvents(String serverId, _DockerServer server) {
    final watchId = server.eventsWatchId;
    server.eventsWatchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  /// Reads [serverId]'s disk use (`/system/df`) unless a read is in
  /// flight or the endpoint is not ready; [diskUseFor] says how it went.
  void measureDiskUse(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    final endpoint = server.endpoint.value;
    if (server.diskUseQuery != null || _stopped) return;
    if (endpoint?.phase != DockerEndpointPhase.ready) return;

    final queryId = 'df-${_count++}';
    _send(
      DockerQuery(
        serverId: serverId,
        queryId: queryId,
        query: const DockerSystemDfQuery(),
      ),
    );
    if (_stopped) return;
    server.diskUseQuery = queryId;
    server.diskUse.value = server.diskUse.value.measuring(
      endpoint?.route?.socketPath,
    );
  }

  /// A Containers view shows [serverId]; [unwatchContainers] says it no
  /// longer does. The first view starts the server's container watch,
  /// reading stats for [statsFor] as [showStatsFor] would.
  void watchContainers(
    String serverId, {
    Iterable<String> statsFor = const [],
  }) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.containerViews++;
    if (server.containerViews > 1) return;

    server.statsFor = statsFor.take(kDockerStatsForMax).toSet();
    _watch(serverId, server);
  }

  /// The last view to hide ends the server's container watch.
  void unwatchContainers(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.containerViews == 0) return;
    server.containerViews--;
    if (server.containerViews > 0) return;

    server.statsFor = const {};
    _unwatch(serverId, server);
  }

  /// The containers, by id, whose rows [serverId]'s Containers view shows,
  /// whose list stats the watch reads from now on (CST-01): at most
  /// [kDockerStatsForMax] of them, in order. Sends the watch again under
  /// its id, which replaces it, when they changed.
  void showStatsFor(String serverId, Iterable<String> containerIds) {
    final server = _servers[serverId];
    if (server == null || server.watchId == null) return;

    final ids = containerIds.take(kDockerStatsForMax).toSet();
    if (setEquals(ids, server.statsFor)) return;
    server.statsFor = ids;
    _watch(serverId, server);
  }

  /// [containerId]'s list stats on [serverId] since this device began
  /// reading them (CST-03), kept while it is listed; a view that charts
  /// it pins its stats with [pinStats].
  ContainerUsageHistory usageFor(String serverId, String containerId) =>
      _server(
        serverId,
      ).usage.putIfAbsent(containerId, ContainerUsageHistory.new);

  /// Has the container watch read [containerId]'s stats whatever rows
  /// show, until [unpinStats]: a details view charts them (CST-03).
  void pinStats(String serverId, String containerId) {
    final server = _server(serverId);
    final pins = server.pinnedStats[containerId] ?? 0;
    server.pinnedStats[containerId] = pins + 1;
    if (pins == 0 && server.watchId != null) _watch(serverId, server);
  }

  /// Ends one [pinStats].
  void unpinStats(String serverId, String containerId) {
    final server = _servers[serverId];
    final pins = server?.pinnedStats[containerId];
    if (server == null || pins == null) return;
    if (pins > 1) {
      server.pinnedStats[containerId] = pins - 1;
      return;
    }
    server.pinnedStats.remove(containerId);
    if (server.watchId != null && !server.statsFor.contains(containerId)) {
      _watch(serverId, server);
    }
  }

  /// A details view shows the container [containerId] (its full id) on
  /// [serverId]; [closeContainer] says it no longer does. The first view
  /// has the container inspected; every view of it shares what the
  /// returned listenable holds, which stays valid until the last closes.
  ValueListenable<DockerContainerDetails> openContainer(
    String serverId,
    String containerId,
  ) {
    final server = _server(serverId);
    // Details a view still shows from before the server left the fleet
    // are taken back, so every view of the container shares one and each
    // close pairs with an open; they are read again.
    final kept = server.inspected.containsKey(containerId)
        ? null
        : _leftFleet.remove((serverId, containerId));
    final inspected = server.inspected.putIfAbsent(
      containerId,
      () => kept ?? _InspectedContainer(_summaryIn(server, containerId)),
    );
    inspected.views++;
    if (inspected.views > 1 && kept == null) return inspected.details;

    if (!_listed(serverId)) {
      inspected.details.value = inspected.details.value.copyWith(
        failure: () => const DockerQueryFailed(DockerQueryFailure.notInFleet),
      );
    } else {
      _inspect(serverId, containerId, inspected);
    }
    return inspected.details;
  }

  /// The last view to close lets the container's details go.
  void closeContainer(String serverId, String containerId) {
    final key = (serverId, containerId);
    if (_leftFleet[key] case final inspected?) {
      inspected.views--;
      if (inspected.views > 0) return;

      _leftFleet.remove(key);
      inspected.dispose();
      return;
    }

    final server = _servers[serverId];
    final inspected = server?.inspected[containerId];
    if (server == null || inspected == null) return;
    inspected.views--;
    if (inspected.views > 0) return;

    server.inspected.remove(containerId);
    inspected.dispose();
  }

  /// Inspects [containerId] on [serverId] again after a failure.
  void retryContainer(String serverId, String containerId) {
    final inspected = _servers[serverId]?.inspected[containerId];
    if (inspected == null || !_listed(serverId)) return;
    _inspect(serverId, containerId, inspected);
  }

  /// Sends one [DockerContainerQuery] for [containerId], or, while one is
  /// in flight, sends another once it is answered: a change it may have
  /// read too early.
  void _inspect(
    String serverId,
    String containerId,
    _InspectedContainer inspected,
  ) {
    if (inspected.queryId != null) {
      inspected.readAgain = true;
      return;
    }
    if (!_stopped) {
      final queryId = 'container-${_count++}';
      _send(
        DockerQuery(
          serverId: serverId,
          queryId: queryId,
          query: DockerContainerQuery(containerId),
        ),
      );
      if (!_stopped) {
        inspected.queryId = queryId;
        return;
      }
    }
    // A stopped engine answers nothing.
    inspected.details.value = inspected.details.value.copyWith(
      failure: () => const DockerQueryFailed(DockerQueryFailure.cancelled),
    );
  }

  /// Takes [payload] into the details whose inspect [queryId] is; false
  /// when no open details view asked for it.
  bool _takeInspect(
    String serverId,
    _DockerServer server,
    String queryId,
    DockerPayload payload,
  ) {
    for (final MapEntry(key: containerId, value: inspected)
        in server.inspected.entries) {
      if (inspected.queryId != queryId) continue;

      inspected.queryId = null;
      final before = inspected.details.value;
      inspected.details.value = switch (payload) {
        DockerContainerPayload(:final container) => DockerContainerDetails(
          container: container,
        ),
        DockerQueryFailed(failure: DockerQueryFailure.notFound) =>
          before.copyWith(removed: true, failure: () => null),
        final DockerQueryFailed failure => before.copyWith(
          failure: () => failure,
        ),
        // No other payload answers an inspect.
        _ => before,
      };
      if (inspected.readAgain) {
        inspected.readAgain = false;
        _inspect(serverId, containerId, inspected);
      }
      return true;
    }
    return false;
  }

  /// Follows each inspected container through a delivered list: one
  /// missing from it was removed, and one whose row changed is inspected
  /// again.
  void _followInspected(
    String serverId,
    _DockerServer server,
    List<ContainerSummary> containers,
  ) {
    if (server.inspected.isEmpty) return;

    final byId = {for (final container in containers) container.id: container};
    for (final MapEntry(key: containerId, value: inspected)
        in server.inspected.entries) {
      final summary = byId[containerId];
      final before = inspected.summary;
      inspected.summary = summary;
      if (summary == null) {
        final details = inspected.details.value;
        if (!details.removed) {
          inspected.details.value = details.copyWith(removed: true);
        }
        continue;
      }
      if (inspected.details.value.removed ||
          (before != null && _rowChanged(before, summary))) {
        _inspect(serverId, containerId, inspected);
      }
    }
  }

  /// Inspects again each container whose last inspect failed, once
  /// [serverId]'s endpoint is ready on a new route: the reads that waited
  /// on it, or failed over the route before.
  void _inspectAfterFailure(String serverId, _DockerServer server) {
    for (final MapEntry(key: containerId, value: inspected)
        in server.inspected.entries) {
      final details = inspected.details.value;
      if (details.failure == null || details.removed) continue;
      _inspect(serverId, containerId, inspected);
    }
  }

  /// Watches [serverId]'s containers anew after a failure: a watch under
  /// a new id, which the engine reads from nothing, where the same one
  /// again would change nothing it reads.
  void retryContainers(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.watchId == null) return;

    _unwatch(serverId, server);
    _watch(serverId, server);
  }

  /// Sends [serverId]'s container watch, minting its id if it has none.
  void _watch(String serverId, _DockerServer server) {
    if (_stopped) return;

    final watchId = server.watchId ??= 'containers-${_count++}';
    _send(
      DockerWatch(
        serverId: serverId,
        watchId: watchId,
        lists: const {DockerWatchList.containers, DockerWatchList.stats},
        statsFor: server.watchedStats,
      ),
    );
  }

  void _unwatch(String serverId, _DockerServer server) {
    final watchId = server.watchId;
    server.watchId = null;
    if (watchId == null || _stopped) return;
    _send(DockerUnwatch(serverId: serverId, watchId: watchId));
  }

  void _send(EngineRequest request) {
    try {
      _engine.send(request);
    } on StateError {
      _stopped = true;
    }
  }

  /// A Docker tab shows [serverId]; [closeView] says it no longer does.
  void openView(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.views++;
    _readIfShown(serverId, server);
  }

  void closeView(String serverId) {
    final server = _servers[serverId];
    if (server == null || server.views == 0) return;
    server.views--;
  }

  /// Asks again: a failed endpoint resolves anew on the next query (03
  /// §5.9), and a ready one reads its details again.
  void retry(String serverId) {
    if (!_listed(serverId)) return;
    _read(serverId, _server(serverId));
  }

  /// Reads the details of a ready endpoint a Docker tab shows, unless
  /// they were read.
  void _readIfShown(String serverId, _DockerServer server) {
    if (server.views == 0) return;
    if (server.endpoint.value?.phase != DockerEndpointPhase.ready) return;
    if (server.engine.value is DockerEnginePayload) return;
    _read(serverId, server);
  }

  /// Sends one [DockerEngineQuery] for [serverId] unless one is in flight
  /// or the engine has stopped.
  void _read(String serverId, _DockerServer server) {
    if (server.engineQuery != null || _stopped) return;

    final queryId = 'docker-${_count++}';
    try {
      _engine.send(
        DockerQuery(
          serverId: serverId,
          queryId: queryId,
          query: const DockerEngineQuery(),
        ),
      );
    } on StateError {
      _stopped = true;
      return;
    }
    server.engineQuery = queryId;
  }

  void _onEvent(EngineEvent event) {
    switch (event) {
      case LinkState(:final serverId, :final status):
        if (!_listed(serverId)) return;
        final server = _server(serverId);
        final linked = status is LinkReady || status is LinkDegraded;
        final rose = linked && !server.linked;
        server.linked = linked;
        if (!rose) return;
        // Ahead of the query that starts the endpoint, so its first
        // route already follows the choice.
        _sendChoice(serverId, server, always: true);
        _read(serverId, server);
      case DockerEndpointState(:final serverId):
        if (!_listed(serverId)) return;
        final server = _server(serverId);
        final before = server.endpoint.value;
        server.endpoint.value = event;
        // The details describe the endpoint they were read over. A read
        // still owed by a replaced ready endpoint would answer with what
        // that endpoint said, so its answer is dropped by id and the new
        // one is read.
        if (!_sameEndpoint(before, event)) {
          server.engine.value = null;
          if (before?.phase == DockerEndpointPhase.ready) {
            server.engineQuery = null;
          }
          // A compose read in flight describes the endpoint before; its
          // answer is let go, and the new one is read.
          server.compose.value = null;
          server.composeQuery = null;
          if (event.phase == DockerEndpointPhase.ready) {
            _inspectAfterFailure(serverId, server);
          }
        }
        // Disk use describes the engine on the socket it was read from,
        // and a read under way there answers for that engine too.
        final measured = server.diskUse.value.socketPath;
        final socket = event.route?.socketPath;
        if (measured != null && socket != null && socket != measured) {
          server.diskUseQuery = null;
          server.diskUse.value = const DockerDiskUse();
        }
        _readIfShown(serverId, server);
        _readComposeIfShown(serverId, server);
        _syncSummary(serverId, server);
      case DockerResult(:final serverId, :final queryId, :final payload):
        final server = _servers[serverId];
        if (server == null) return;
        if (server.composeQuery == queryId) {
          server.composeQuery = null;
          if (!_waitedOnEndpoint(payload)) server.compose.value = payload;
          return;
        }
        if (server.diskUseQuery == queryId) {
          server.diskUseQuery = null;
          server.diskUse.value = server.diskUse.value.took(payload, _now());
          return;
        }
        if (server.fileReads.remove(queryId) case final read?) {
          read.complete(payload);
          return;
        }
        if (server.engineQuery != queryId) {
          _takeInspect(serverId, server, queryId, payload);
          return;
        }
        server.engineQuery = null;
        // Nothing was read because no endpoint was ready: its state says
        // why, and once one is, a shown tab reads again.
        if (!_waitedOnEndpoint(payload)) server.engine.value = payload;
      case DockerListChanged(
        :final serverId,
        :final list,
        :final payload,
        :final at,
      ):
        // Lists arrive for the server, whichever watch asked for them.
        final server = _servers[serverId];
        if (server == null) return;
        server.containers.value = _takeList(
          server.containers.value,
          list,
          payload,
          at,
        );
        // A stacks list names the compose CLIs the Access tab shows.
        if (payload case DockerStacksPayload(:final composeCli?)) {
          server.compose.value = DockerComposePayload(composeCli);
        }
        if ((list, payload) case (
          DockerWatchList.containers,
          DockerContainersPayload(:final containers),
        )) {
          _followInspected(serverId, server, containers);
          final listed = {for (final c in containers) c.id};
          server.usage.removeWhere((id, history) {
            // A pinned one stays: a details view charts it.
            if (listed.contains(id) || server.pinnedStats.containsKey(id)) {
              return false;
            }
            history.dispose();
            return true;
          });
        }
        if (payload case DockerStatsPayload(:final stats)) {
          for (final row in stats) {
            server.usage
                .putIfAbsent(row.containerId, ContainerUsageHistory.new)
                .add(row);
          }
        }
        if (list == DockerWatchList.images) {
          server.images.value = server.images.value.took(payload, at);
        }
        if (list == DockerWatchList.volumes) {
          server.volumes.value = server.volumes.value.took(payload, at);
        }
        if (list == DockerWatchList.networks) {
          server.networks.value = server.networks.value.took(payload, at);
        }
        if (list == DockerWatchList.events) {
          server.events.value = server.events.value.took(payload);
        }
        if (list == DockerWatchList.stacks) {
          server.stacks.value = server.stacks.value.took(payload, at);
          // The grouping holds every container the list read.
          if (payload case DockerStacksPayload(:final grouping)) {
            _followInspected(serverId, server, [
              for (final project in grouping.projects) ...project.containers,
              ...grouping.unmanaged,
            ]);
          }
        }
      case CatalogReplaced(:final entries):
        // SYN-08: a server leaving the fleet takes its endpoint with it.
        final ids = _fleetIds = {for (final entry in entries) entry.serverId};
        _servers.removeWhere((serverId, server) {
          if (ids.contains(serverId)) return false;
          server.endFileReads(DockerQueryFailure.notInFleet);
          _keepShownDetails(serverId, server);
          server.dispose();
          return true;
        });
      case EngineEvent():
        break;
    }
  }

  /// A stopped engine answers nothing more.
  void _onEngineDone() {
    _stopped = true;
    for (final server in _servers.values) {
      server.engineQuery = null;
      server.composeQuery = null;
      if (server.diskUseQuery != null) {
        server.diskUseQuery = null;
        server.diskUse.value = server.diskUse.value.took(
          const DockerQueryFailed(DockerQueryFailure.cancelled),
          _now(),
        );
      }
      server.endFileReads(DockerQueryFailure.cancelled);
      for (final inspected in server.inspected.values) {
        if (inspected.queryId == null) continue;
        inspected.queryId = null;
        inspected.readAgain = false;
        inspected.details.value = inspected.details.value.copyWith(
          failure: () => const DockerQueryFailed(DockerQueryFailure.cancelled),
        );
      }
    }
  }

  bool _listed(String serverId) => _fleetIds?.contains(serverId) ?? true;

  /// [containerId]'s row in [server]'s latest list, if listed.
  ContainerSummary? _summaryIn(_DockerServer server, String containerId) {
    for (final container in server.containers.value.containers ?? const []) {
      if (container.id == containerId) return container;
    }
    return null;
  }

  _DockerServer _server(String serverId) =>
      _servers.putIfAbsent(serverId, _DockerServer.new);

  /// Moves the details [server] still has shown into [_leftFleet], each
  /// saying the server left the fleet, before the server goes; every one
  /// it has is shown, as the last view to close removes it.
  void _keepShownDetails(String serverId, _DockerServer server) {
    for (final MapEntry(key: containerId, value: inspected)
        in server.inspected.entries) {
      inspected
        ..queryId = null
        ..readAgain = false
        ..details.value = inspected.details.value.copyWith(
          failure: () => const DockerQueryFailed(DockerQueryFailure.notInFleet),
        );
      _leftFleet[(serverId, containerId)] = inspected;
    }
    server.inspected.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _stopped = true;
    endpointChoices.removeListener(_onChoices);
    if (_ownsChoices) endpointChoices.dispose();
    for (final server in _servers.values) {
      server.dispose();
    }
    _servers.clear();
    for (final inspected in _leftFleet.values) {
      inspected.dispose();
    }
    _leftFleet.clear();
  }
}

/// Whether [payload] read nothing only because no endpoint was ready, so
/// a view reads again once one is, rather than showing a failure.
bool _waitedOnEndpoint(DockerPayload payload) => switch (payload) {
  DockerQueryFailed(
    failure: DockerQueryFailure.linkUnavailable ||
        DockerQueryFailure.profileUnknown ||
        DockerQueryFailure.endpointUnavailable ||
        DockerQueryFailure.cancelled,
  ) =>
    true,
  _ => false,
};

/// [before] with [payload], a read of [list] at [at], taken in: a new
/// list or stats round, or a failed one, which keeps what was read
/// before. Lists other than the containers and their stats leave it as
/// it was.
DockerContainerList _takeList(
  DockerContainerList before,
  DockerWatchList list,
  DockerPayload payload,
  DateTime at,
) {
  switch ((list, payload)) {
    case (
      DockerWatchList.containers,
      DockerContainersPayload(:final containers),
    ):
      final ids = {for (final container in containers) container.id};
      return DockerContainerList(
        containers: containers,
        at: at,
        // Stats of a container that went go with it.
        stats: {
          for (final MapEntry(:key, :value) in before.stats.entries)
            if (ids.contains(key)) key: value,
        },
        statsFailure: before.statsFailure,
      );
    case (DockerWatchList.containers, final DockerQueryFailed failure):
      return before.copyWith(failure: () => failure);
    case (DockerWatchList.stats, DockerStatsPayload(:final stats)):
      return before.copyWith(
        stats: {...before.stats, for (final row in stats) row.containerId: row},
        statsFailure: () => null,
      );
    case (DockerWatchList.stats, final DockerQueryFailed failure):
      return before.copyWith(statsFailure: () => failure);
    case _:
      return before;
  }
}

/// What a server's container watch delivered (03 §7.12 CTR-01, CST-01).
@immutable
final class DockerContainerList {
  const DockerContainerList({
    this.containers,
    this.at,
    this.failure,
    this.stats = const {},
    this.statsFailure,
  });

  /// The latest list read, stopped containers too; null until one was.
  final List<ContainerSummary>? containers;

  /// When the engine read [containers], by this device's clock.
  final DateTime? at;

  /// Why the latest list read failed, or the engine refused the watch,
  /// while [containers] keeps the list before; null once one is read.
  final DockerQueryFailed? failure;

  /// Each listed container's latest list stats, by id. A container whose
  /// row left the screen keeps its last ones, which age by their
  /// [ContainerListStats.at].
  final Map<String, ContainerListStats> stats;

  /// Why the latest stats round failed; null once one succeeds.
  final DockerQueryFailed? statsFailure;

  DockerContainerList copyWith({
    DockerQueryFailed? Function()? failure,
    Map<String, ContainerListStats>? stats,
    DockerQueryFailed? Function()? statsFailure,
  }) => DockerContainerList(
    containers: containers,
    at: at,
    failure: failure == null ? this.failure : failure(),
    stats: stats ?? this.stats,
    statsFailure: statsFailure == null ? this.statsFailure : statsFailure(),
  );
}

/// What a server's watches delivered of its images (03 §7.14 IMG-01).
@immutable
final class DockerImageList {
  const DockerImageList({this.images, this.at, this.failure});

  /// The latest list read; null until one was.
  final List<ImageSummary>? images;

  /// When the engine read [images], by this device's clock.
  final DateTime? at;

  /// Why the latest read failed while [images] keeps the list before;
  /// null once one is read.
  final DockerQueryFailed? failure;

  /// This list with [payload], read at [at], taken in.
  DockerImageList took(DockerPayload payload, DateTime at) => switch (payload) {
    DockerImagesPayload(:final images) => DockerImageList(
      images: images,
      at: at,
    ),
    final DockerQueryFailed failure => DockerImageList(
      images: images,
      at: this.at,
      failure: failure,
    ),
    _ => this,
  };
}

/// What a server's watches delivered of its volumes (03 §7.15 VOL-01).
@immutable
final class DockerVolumeList {
  const DockerVolumeList({this.volumes, this.at, this.failure});

  /// The latest list read; null until one was.
  final List<VolumeSummary>? volumes;

  /// When the engine read [volumes], by this device's clock.
  final DateTime? at;

  /// Why the latest read failed while [volumes] keeps the list before;
  /// null once one is read.
  final DockerQueryFailed? failure;

  /// This list with [payload], read at [at], taken in.
  DockerVolumeList took(DockerPayload payload, DateTime at) =>
      switch (payload) {
        DockerVolumesPayload(:final volumes) => DockerVolumeList(
          volumes: volumes,
          at: at,
        ),
        final DockerQueryFailed failure => DockerVolumeList(
          volumes: volumes,
          at: this.at,
          failure: failure,
        ),
        _ => this,
      };
}

/// What a server's watches delivered of its networks (03 §7.15 DNW-01).
@immutable
final class DockerNetworkList {
  const DockerNetworkList({this.networks, this.at, this.failure});

  /// The latest list read; null until one was.
  final List<NetworkSummary>? networks;

  /// When the engine read [networks], by this device's clock.
  final DateTime? at;

  /// Why the latest read failed while [networks] keeps the list before;
  /// null once one is read.
  final DockerQueryFailed? failure;

  /// This list with [payload], read at [at], taken in.
  DockerNetworkList took(DockerPayload payload, DateTime at) =>
      switch (payload) {
        DockerNetworksPayload(:final networks) => DockerNetworkList(
          networks: networks,
          at: at,
        ),
        final DockerQueryFailed failure => DockerNetworkList(
          networks: networks,
          at: this.at,
          failure: failure,
        ),
        _ => this,
      };
}

/// What a server's events watch delivered of the events timeline
/// (03 §7.12 DKE-03).
@immutable
final class DockerEventList {
  const DockerEventList({this.entries, this.failure});

  /// The timeline, oldest first; null until the watch delivered one.
  final List<DockerTimelineEntry>? entries;

  /// Why the watch failed while [entries] keeps the timeline before; null
  /// once one is delivered.
  final DockerQueryFailed? failure;

  /// This timeline with [payload] taken in.
  DockerEventList took(DockerPayload payload) => switch (payload) {
    DockerEventsPayload(:final entries) => DockerEventList(entries: entries),
    final DockerQueryFailed failure => DockerEventList(
      entries: entries,
      failure: failure,
    ),
    _ => this,
  };
}

/// A server's disk use measurement (02 OV-05): the last `/system/df`
/// read, and whether one is under way or why the last one failed.
@immutable
final class DockerDiskUse {
  const DockerDiskUse({
    this.df,
    this.at,
    this.inFlight = false,
    this.failure,
    this.socketPath,
  });

  /// The last measurement; null until one succeeded.
  final SystemDf? df;

  /// When [df] arrived, by this device's clock.
  final DateTime? at;

  /// Whether a measurement is under way.
  final bool inFlight;

  /// Why the latest measurement failed, while [df] keeps the one before;
  /// null once one succeeds.
  final DockerQueryFailed? failure;

  /// The engine socket [df] was read from: another engine's reading is
  /// dropped.
  final String? socketPath;

  /// This measurement with another under way over [socketPath]; the
  /// last failure is moot.
  DockerDiskUse measuring(String? socketPath) => DockerDiskUse(
    df: df,
    at: at,
    inFlight: true,
    socketPath: socketPath ?? this.socketPath,
  );

  /// This measurement with [payload], the answer that arrived at [now],
  /// taken in.
  DockerDiskUse took(DockerPayload payload, DateTime now) => switch (payload) {
    DockerSystemDfPayload(:final df) => DockerDiskUse(
      df: df,
      at: now,
      socketPath: socketPath,
    ),
    final DockerQueryFailed failure => DockerDiskUse(
      df: df,
      at: at,
      failure: failure,
      socketPath: socketPath,
    ),
    _ => DockerDiskUse(df: df, at: at, socketPath: socketPath),
  };
}

/// What a server's stack watch delivered (03 §7.16 STK-01, STK-05).
@immutable
final class DockerStackList {
  const DockerStackList({this.stacks, this.at, this.failure});

  /// The latest stacks read: the compose projects, each one's verdict
  /// and the compose CLI found; null until one was.
  final DockerStacksPayload? stacks;

  /// When the engine read [stacks], by this device's clock.
  final DateTime? at;

  /// Why the latest read failed, or the engine refused the watch, while
  /// [stacks] keeps the list before; null once one is read.
  final DockerQueryFailed? failure;

  /// This list with [payload], read at [at], taken in.
  DockerStackList took(DockerPayload payload, DateTime at) => switch (payload) {
    final DockerStacksPayload stacks => DockerStackList(stacks: stacks, at: at),
    final DockerQueryFailed failure => DockerStackList(
      stacks: stacks,
      at: this.at,
      failure: failure,
    ),
    _ => this,
  };
}

/// Whether a container's row changed in a way its inspect may show: its
/// state, the engine's status text (a restart resets its uptime), its
/// health or its image.
bool _rowChanged(ContainerSummary before, ContainerSummary after) =>
    before.state != after.state ||
    before.status != after.status ||
    before.health != after.health ||
    before.imageId != after.imageId;

/// What a container's details view shows (03 §7.12 CTR-03, CTR-04).
@immutable
final class DockerContainerDetails {
  const DockerContainerDetails({
    this.container,
    this.failure,
    this.removed = false,
  });

  /// The latest inspect read, masked by the engine (03 §8.9); null until
  /// one was.
  final ContainerDetails? container;

  /// Why the latest inspect failed, while [container] keeps the one
  /// before; null once one is read.
  final DockerQueryFailed? failure;

  /// Whether the container is gone: a list no longer had it, or its
  /// inspect found nothing. [container] keeps what was read before.
  final bool removed;

  DockerContainerDetails copyWith({
    DockerQueryFailed? Function()? failure,
    bool? removed,
  }) => DockerContainerDetails(
    container: container,
    failure: failure == null ? this.failure : failure(),
    removed: removed ?? this.removed,
  );
}

/// One container a details view shows.
final class _InspectedContainer {
  _InspectedContainer(this.summary);

  final ValueNotifier<DockerContainerDetails> details = ValueNotifier(
    const DockerContainerDetails(),
  );

  /// The container's row in the latest list, which a change in the next
  /// one is measured against; null while unlisted.
  ContainerSummary? summary;

  /// How many details views show the container.
  int views = 0;

  /// The inspect in flight, whose answer [details] takes.
  String? queryId;

  /// Whether to inspect again once [queryId] is answered.
  bool readAgain = false;

  void dispose() => details.dispose();
}

/// Whether [after] is the ready endpoint [before] was: the same route
/// and API version.
bool _sameEndpoint(DockerEndpointState? before, DockerEndpointState after) {
  if (before == null ||
      before.phase != DockerEndpointPhase.ready ||
      after.phase != DockerEndpointPhase.ready) {
    return false;
  }
  final (a, b) = (before.route, after.route);
  if (a == null || b == null) return false;
  return before.negotiatedApi == after.negotiatedApi &&
      a.rank == b.rank &&
      a.socketPath == b.socketPath &&
      a.runtime == b.runtime &&
      a.mode == b.mode &&
      a.rootEquivalence == b.rootEquivalence;
}

/// One server's Docker state.
final class _DockerServer {
  final ValueNotifier<DockerEndpointState?> endpoint = ValueNotifier(null);
  final ValueNotifier<DockerPayload?> engine = ValueNotifier(null);
  final ValueNotifier<DockerPayload?> compose = ValueNotifier(null);
  final ValueNotifier<DockerContainerList> containers = ValueNotifier(
    const DockerContainerList(),
  );
  final ValueNotifier<DockerImageList> images = ValueNotifier(
    const DockerImageList(),
  );
  final ValueNotifier<DockerVolumeList> volumes = ValueNotifier(
    const DockerVolumeList(),
  );
  final ValueNotifier<DockerNetworkList> networks = ValueNotifier(
    const DockerNetworkList(),
  );
  final ValueNotifier<DockerEventList> events = ValueNotifier(
    const DockerEventList(),
  );
  final ValueNotifier<DockerDiskUse> diskUse = ValueNotifier(
    const DockerDiskUse(),
  );
  final ValueNotifier<DockerStackList> stacks = ValueNotifier(
    const DockerStackList(),
  );

  /// The engine query in flight, whose answer [engine] takes.
  String? engineQuery;

  /// How many Docker tabs show the server.
  int views = 0;

  /// How many Access tabs show the server, and the compose query in
  /// flight, whose answer [compose] takes.
  int accessViews = 0;
  String? composeQuery;

  /// The endpoint choice last sent to the engine; null before any was.
  DockerEndpointChoice? sentChoice;

  /// Whether the server's last [LinkState] was a usable link.
  bool linked = false;

  /// How many Containers views show the server.
  int containerViews = 0;

  /// The container watch the engine holds, while any view shows.
  String? watchId;

  /// The containers whose stats the watch reads: the rows on screen.
  Set<String> statsFor = const {};

  /// The containers whose stats are read whatever rows show, as an open
  /// details view's (CST-03), with how many views pin each.
  final Map<String, int> pinnedStats = {};

  /// Each listed container's list stats since this device began reading
  /// them (CST-03), by id; a container that leaves the list takes its
  /// history with it.
  final Map<String, ContainerUsageHistory> usage = {};

  /// What the container watch reads stats for: the pinned containers,
  /// then the rows on screen, at most [kDockerStatsForMax].
  Set<String> get watchedStats =>
      {...pinnedStats.keys, ...statsFor}.take(kDockerStatsForMax).toSet();

  /// How many Overviews show the server.
  int summaryViews = 0;

  /// The summary watch the engine holds, while any Overview shows.
  String? summaryWatchId;

  /// The disk use query in flight, whose answer [diskUse] takes.
  String? diskUseQuery;

  /// How many Images views show the server.
  int imageViews = 0;

  /// The image watch the engine holds, while any Images view shows.
  String? imagesWatchId;

  /// How many Volumes views show the server.
  int volumeViews = 0;

  /// The volume watch the engine holds, while any Volumes view shows.
  String? volumesWatchId;

  /// How many Networks views show the server.
  int networkViews = 0;

  /// The network watch the engine holds, while any Networks view shows.
  String? networksWatchId;

  /// How many Events views show the server.
  int eventViews = 0;

  /// The events watch the engine holds, while any Events view shows.
  String? eventsWatchId;

  /// How many Stacks views show the server.
  int stackViews = 0;

  /// The stack watch the engine holds, while any Stacks view shows.
  String? stacksWatchId;

  /// The containers details views show, by full id.
  final Map<String, _InspectedContainer> inspected = {};

  /// The one-shot stack reads in flight (files, profiles), by query id,
  /// each completed with the engine's answer.
  final Map<String, Completer<DockerPayload>> fileReads = {};

  /// Answers every one-shot stack read in flight with [failure]: the engine
  /// will not.
  void endFileReads(DockerQueryFailure failure) {
    for (final read in fileReads.values) {
      read.complete(DockerQueryFailed(failure));
    }
    fileReads.clear();
  }

  void dispose() {
    endFileReads(DockerQueryFailure.cancelled);
    for (final history in usage.values) {
      history.dispose();
    }
    usage.clear();
    endpoint.dispose();
    engine.dispose();
    compose.dispose();
    containers.dispose();
    images.dispose();
    volumes.dispose();
    networks.dispose();
    events.dispose();
    diskUse.dispose();
    stacks.dispose();
    for (final container in inspected.values) {
      container.dispose();
    }
  }
}
