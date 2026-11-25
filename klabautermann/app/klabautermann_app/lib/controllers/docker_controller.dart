import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'container_usage.dart';
import 'docker/docker_lists.dart';
import 'docker_endpoint_choices.dart';
import 'fleet_controller.dart';

export 'docker/docker_lists.dart';

part 'docker/container_inspects.dart';
part 'docker/view_watch.dart';

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
/// one is sent again only after a socket was. The server's `docker`
/// program (CN-16) goes out the same way, as a [SetDockerProgram].
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

  late final _ContainerInspects _inspected = _ContainerInspects(
    this,
    mintQueryId: () => 'container-${_count++}',
  );

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

  /// Makes [program] [serverId]'s `docker` (CN-16), or the one on the exec
  /// `PATH` when null, and sends it as [chooseEndpoint] sends a choice.
  Future<void> chooseProgram(String serverId, String? program) =>
      endpointChoices.chooseProgram(serverId, program);

  /// Sends each linked server's choice and program that the engine was
  /// not given yet.
  void _onChoices() {
    for (final MapEntry(key: serverId, value: server) in _servers.entries) {
      if (!server.linked) continue;
      _sendChoice(serverId, server);
      _sendProgram(serverId, server);
    }
  }

  /// Sends [serverId]'s `docker` program as [_sendChoice] sends its
  /// choice: unless the engine holds it already, the `docker` on the
  /// exec `PATH` before any was sent, and a set path again as a link
  /// comes up when [always].
  void _sendProgram(
    String serverId,
    _DockerServer server, {
    bool always = false,
  }) {
    final program = endpointChoices.programFor(serverId);
    if (program == server.sentProgram && !(always && program != null)) return;
    if (_stopped) return;

    _send(SetDockerProgram(serverId: serverId, program: program));
    server.sentProgram = program;
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
    server.summaryWatch.add(this, serverId, server);
  }

  void unwatchSummary(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.summaryWatch.remove(this, serverId, server);
  }

  /// Watches the summary's lists anew after a failure, under a new id, as
  /// [retryContainers] does.
  void retrySummary(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.summaryWatch.retry(this, serverId, server);
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
    server.stackWatch.add(this, serverId, server);
  }

  /// The last view to hide ends the server's stack watch.
  void unwatchStacks(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.stackWatch.remove(this, serverId, server);
  }

  /// Watches [serverId]'s stacks anew after a failure, under a new id, as
  /// [retryContainers] does; the engine checks the sources again.
  void retryStacks(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.stackWatch.retry(this, serverId, server);
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

  /// The update check of every tagged image on [serverId] (IMG-05): a
  /// [DockerImageUpdatesPayload] or a [DockerQueryFailed]. The engine
  /// keeps each tag's row for six hours, so asking again inside them
  /// reads no registry unless [refresh]; [runner] picks where the reads
  /// run (D68). Nothing of the answer stays here.
  Future<DockerPayload> checkImageUpdates(
    String serverId, {
    bool refresh = false,
    ImageCheckRunner runner = ImageCheckRunner.host,
  }) =>
      _ask(serverId, DockerImageUpdatesQuery(refresh: refresh, runner: runner));

  /// The processes of [containerId] on [serverId] (CTR-10): a
  /// [DockerContainerTopPayload] whose command lines the engine masked,
  /// or a [DockerQueryFailed]. Nothing of the answer stays here.
  Future<DockerPayload> readContainerTop(String serverId, String containerId) =>
      _ask(serverId, DockerContainerTopQuery(containerId));

  /// DKE-06's security review and DKE-07's log rotation lint of every
  /// container on [serverId], up to [kDockerReviewMax]: a
  /// [DockerReviewPayload] or a [DockerQueryFailed]. Nothing of the
  /// answer stays here.
  Future<DockerPayload> reviewContainers(String serverId) =>
      _ask(serverId, const DockerReviewQuery());

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

    final queryId = 'one-shot-${_count++}';
    _send(DockerQuery(serverId: serverId, queryId: queryId, query: spec));
    if (_stopped) {
      return Future.value(
        const DockerQueryFailed(DockerQueryFailure.cancelled),
      );
    }
    final read = Completer<DockerPayload>();
    _server(serverId).oneShots[queryId] = read;
    return read.future;
  }

  /// An Images view shows [serverId]; [unwatchImages] says it no longer
  /// does. The first view starts the server's image watch.
  void watchImages(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.imageWatch.add(this, serverId, server);
  }

  /// The last view to hide ends the server's image watch.
  void unwatchImages(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.imageWatch.remove(this, serverId, server);
  }

  /// Watches [serverId]'s images anew after a failure, under a new id, as
  /// [retryContainers] does.
  void retryImages(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.imageWatch.retry(this, serverId, server);
  }

  /// A Volumes view shows [serverId]; [unwatchVolumes] says it no longer
  /// does. The first view starts the server's volume watch.
  void watchVolumes(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.volumeWatch.add(this, serverId, server);
  }

  /// The last view to hide ends the server's volume watch.
  void unwatchVolumes(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.volumeWatch.remove(this, serverId, server);
  }

  /// Watches [serverId]'s volumes anew after a failure, under a new id, as
  /// [retryContainers] does.
  void retryVolumes(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.volumeWatch.retry(this, serverId, server);
  }

  /// A Networks view shows [serverId]; [unwatchNetworks] says it no
  /// longer does. The first view starts the server's network watch.
  void watchNetworks(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.networkWatch.add(this, serverId, server);
  }

  /// The last view to hide ends the server's network watch.
  void unwatchNetworks(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.networkWatch.remove(this, serverId, server);
  }

  /// Watches [serverId]'s networks anew after a failure, under a new id,
  /// as [retryContainers] does.
  void retryNetworks(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.networkWatch.retry(this, serverId, server);
  }

  /// An Events view shows [serverId]; [unwatchEvents] says it no longer
  /// does. The first view starts the server's events watch (DKE-03).
  void watchEvents(String serverId) {
    if (!_listed(serverId)) return;
    final server = _server(serverId);
    server.eventWatch.add(this, serverId, server);
  }

  /// The last view to hide ends the server's events watch.
  void unwatchEvents(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.eventWatch.remove(this, serverId, server);
  }

  /// Watches [serverId]'s events anew after a failure, under a new id,
  /// as [retryContainers] does.
  void retryEvents(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.eventWatch.retry(this, serverId, server);
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
    if (!server.containerWatch.gainView()) return;

    server.statsFor = statsFor.take(kDockerStatsForMax).toSet();
    server.containerWatch.send(this, serverId, server);
  }

  /// The last view to hide ends the server's container watch.
  void unwatchContainers(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    if (!server.containerWatch.loseView()) return;

    server.statsFor = const {};
    server.containerWatch.end(this, serverId);
  }

  /// The containers, by id, whose rows [serverId]'s Containers view shows,
  /// whose list stats the watch reads from now on (CST-01): at most
  /// [kDockerStatsForMax] of them, in order. Sends the watch again under
  /// its id, which replaces it, when they changed.
  void showStatsFor(String serverId, Iterable<String> containerIds) {
    final server = _servers[serverId];
    if (server == null || server.containerWatch.watchId == null) return;

    final ids = containerIds.take(kDockerStatsForMax).toSet();
    if (setEquals(ids, server.statsFor)) return;
    server.statsFor = ids;
    server.containerWatch.send(this, serverId, server);
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
    // A container the list already reads changes nothing to watch.
    if (pins == 0 &&
        server.containerWatch.watchId != null &&
        !server.statsFor.contains(containerId)) {
      server.containerWatch.send(this, serverId, server);
    }
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
    if (server.containerWatch.watchId != null &&
        !server.statsFor.contains(containerId)) {
      server.containerWatch.send(this, serverId, server);
    }
  }

  /// A details view shows the container [containerId] (its full id) on
  /// [serverId]; [closeContainer] says it no longer does. The first view
  /// has the container inspected; every view of it shares what the
  /// returned listenable holds, which stays valid until the last closes.
  ValueListenable<DockerContainerDetails> openContainer(
    String serverId,
    String containerId,
  ) => _inspected.open(serverId, _server(serverId), containerId);

  /// The last view to close lets the container's details go.
  void closeContainer(String serverId, String containerId) =>
      _inspected.close(serverId, _servers[serverId], containerId);

  /// Inspects [containerId] on [serverId] again after a failure.
  void retryContainer(String serverId, String containerId) {
    final server = _servers[serverId];
    if (server == null) return;
    _inspected.retry(serverId, server, containerId);
  }

  /// Watches [serverId]'s containers anew after a failure: a watch under
  /// a new id, which the engine reads from nothing, where the same one
  /// again would change nothing it reads.
  void retryContainers(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;
    server.containerWatch.retry(this, serverId, server);
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
        _sendProgram(serverId, server, always: true);
        _read(serverId, server);
        // An endpoint change dropped the watches with the old session;
        // the views still counted watch the new machine now.
        if (server.watchesDropped) {
          server.watchesDropped = false;
          _resendWatches(serverId, server);
        }
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
            _inspected.afterFailure(serverId, server);
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
        server.summaryWatch.start(this, serverId, server);
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
        if (server.oneShots.remove(queryId) case final read?) {
          read.complete(payload);
          return;
        }
        if (server.engineQuery != queryId) {
          _inspected.take(serverId, server, queryId, payload);
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
        server.containers.value = server.containers.value.took(
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
          _inspected.follow(serverId, server, containers);
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
            _inspected.follow(serverId, server, [
              for (final project in grouping.projects) ...project.containers,
              ...grouping.unmanaged,
            ]);
          }
        }
      case CatalogReplaced(:final entries):
        // SYN-08: a server leaving the fleet takes its endpoint with it.
        final ids = _fleetIds = {for (final entry in entries) entry.serverId};
        final keys = {
          for (final entry in entries)
            entry.serverId: FleetServer.endpointKey(entry),
        };
        _servers.removeWhere((serverId, server) {
          if (ids.contains(serverId)) return false;
          server.endOneShots(DockerQueryFailure.notInFleet);
          _inspected.keepShown(serverId, server);
          server.dispose();
          return true;
        });
        // An id that stays under another endpoint, an import re-pointed
        // or a synced server a sync moved, now names another machine, so
        // what the old one told it goes in place, as an EndpointChanged
        // does, and its views' watches go out again on the next link.
        for (final MapEntry(key: serverId, value: server) in _servers.entries) {
          final key = keys[serverId];
          if (key != null &&
              server.endpointKey != null &&
              server.endpointKey != key) {
            _resetForEndpointChange(server);
          }
          server.endpointKey = key;
        }
      case EndpointChanged(:final serverId):
        // A synced server's endpoint changed (SYN-08): the engine ends
        // its session and watches, so its state goes in place as its
        // views stay counted.
        final server = _servers[serverId];
        if (server == null || !_listed(serverId)) return;
        _resetForEndpointChange(server);
        // The fleet that follows carries the new key. Forgetting the old
        // one here keeps it from reading as a second move, which would
        // drop what the new machine has already answered since the link
        // rose.
        server.endpointKey = null;
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
      server.endOneShots(DockerQueryFailure.cancelled);
      _inspected.onEngineDone(server);
    }
  }

  bool _listed(String serverId) => _fleetIds?.contains(serverId) ?? true;

  _DockerServer _server(String serverId) => _servers.putIfAbsent(
    serverId,
    () => _DockerServer(
      containerWatch: _ViewWatch(
        mintId: () => 'containers-${_count++}',
        lists: const {DockerWatchList.containers, DockerWatchList.stats},
        readsStats: true,
      ),
      summaryWatch: _ViewWatch(
        mintId: () => 'summary-${_count++}',
        lists: const {DockerWatchList.containers, DockerWatchList.images},
        waitsForEndpoint: true,
      ),
      imageWatch: _ViewWatch(
        mintId: () => 'images-${_count++}',
        lists: const {DockerWatchList.images, DockerWatchList.containers},
      ),
      volumeWatch: _ViewWatch(
        mintId: () => 'volumes-${_count++}',
        lists: const {DockerWatchList.volumes, DockerWatchList.containers},
      ),
      networkWatch: _ViewWatch(
        mintId: () => 'networks-${_count++}',
        lists: const {DockerWatchList.networks, DockerWatchList.containers},
      ),
      eventWatch: _ViewWatch(
        mintId: () => 'events-${_count++}',
        lists: const {DockerWatchList.events},
      ),
      stackWatch: _ViewWatch(
        mintId: () => 'stacks-${_count++}',
        lists: const {DockerWatchList.stacks},
      ),
    ),
  );

  /// Drops what the old endpoint told [server], whose id now names
  /// another machine (SYN-08), keeping its notifiers and view counts:
  /// the lists, usage, disk use, engine and compose details, the pending
  /// query ids and one-shot reads go, the details views say why they
  /// cannot read, and the views' watches go out again once the link to
  /// the new machine rises. The engine ended the session and its watches,
  /// so nothing of them is unwatched here.
  void _resetForEndpointChange(_DockerServer server) {
    server
      ..linked = false
      ..engineQuery = null
      ..composeQuery = null
      ..diskUseQuery = null
      ..watchesDropped = true;
    server.containerWatch.reset();
    server.summaryWatch.reset();
    server.imageWatch.reset();
    server.volumeWatch.reset();
    server.networkWatch.reset();
    server.eventWatch.reset();
    server.stackWatch.reset();
    server.endpoint.value = null;
    server.engine.value = null;
    server.compose.value = null;
    server.containers.value = const DockerContainerList();
    server.images.value = const DockerImageList();
    server.volumes.value = const DockerVolumeList();
    server.networks.value = const DockerNetworkList();
    server.events.value = const DockerEventList();
    server.stacks.value = const DockerStackList();
    server.diskUse.value = const DockerDiskUse();
    for (final history in server.usage.values) {
      history.dispose();
    }
    server.usage.clear();
    server.endOneShots(DockerQueryFailure.cancelled);
    _inspected.reset(server);
  }

  /// Sends the watches an endpoint change dropped for the views still
  /// counted; the endpoint-gated one waits for the endpoint, as its sync
  /// says, and the endpoint state asks for it and the details again.
  void _resendWatches(String serverId, _DockerServer server) {
    for (final watch in [
      server.containerWatch,
      server.summaryWatch,
      server.imageWatch,
      server.volumeWatch,
      server.networkWatch,
      server.eventWatch,
      server.stackWatch,
    ]) {
      if (watch.views == 0) continue;
      if (watch.waitsForEndpoint) {
        watch.start(this, serverId, server);
      } else {
        watch.send(this, serverId, server);
      }
    }
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
    for (final inspected in _inspected.leftFleet.values) {
      inspected.dispose();
    }
    _inspected.leftFleet.clear();
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
  _DockerServer({
    required this.containerWatch,
    required this.summaryWatch,
    required this.imageWatch,
    required this.volumeWatch,
    required this.networkWatch,
    required this.eventWatch,
    required this.stackWatch,
  });

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

  /// The Containers view's watch, the one that reads list stats too
  /// (CST-01).
  final _ViewWatch containerWatch;

  /// The Overview's watch, sent only once its endpoint is ready (OV-05).
  final _ViewWatch summaryWatch;

  /// The Images view's watch.
  final _ViewWatch imageWatch;

  /// The Volumes view's watch.
  final _ViewWatch volumeWatch;

  /// The Networks view's watch.
  final _ViewWatch networkWatch;

  /// The Events view's watch.
  final _ViewWatch eventWatch;

  /// The Stacks view's watch.
  final _ViewWatch stackWatch;

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

  /// The `docker` program last sent to the engine; null before any was,
  /// or after the one on the exec `PATH` was.
  String? sentProgram;

  /// Whether the server's last [LinkState] was a usable link.
  bool linked = false;

  /// The machine the fleet's entry reached last time this controller saw
  /// it, [FleetServer.endpointKey] of its [FleetEntry]; null until then.
  String? endpointKey;

  /// Its watches were dropped with the old endpoint's session and wait
  /// for the link to the new one, which [_resendWatches] sends again.
  bool watchesDropped = false;

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

  /// The disk use query in flight, whose answer [diskUse] takes.
  String? diskUseQuery;

  /// The containers details views show, by full id.
  final Map<String, _InspectedContainer> inspected = {};

  /// The one-shot reads in flight ([DockerController._ask]'s: stack
  /// files, profiles and scans, image history and updates, container
  /// processes, the review), by query id, each completed with the
  /// engine's answer.
  final Map<String, Completer<DockerPayload>> oneShots = {};

  /// Answers every one-shot read in flight with [failure]: the engine
  /// will not.
  void endOneShots(DockerQueryFailure failure) {
    for (final read in oneShots.values) {
      read.complete(DockerQueryFailed(failure));
    }
    oneShots.clear();
  }

  void dispose() {
    endOneShots(DockerQueryFailure.cancelled);
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
