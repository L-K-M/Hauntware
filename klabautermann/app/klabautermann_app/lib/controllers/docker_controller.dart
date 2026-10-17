import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

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
/// An Images view that shows a server ([watchImages]) has its images
/// watched with its containers (03 §7.14 IMG-01): a [DockerWatch] of its
/// own, one per server while any such view shows, which the engine
/// serves from the server's one `/events` stream. The containers come
/// along because they tell which images are in use: below API 1.51 the
/// image list carries no count, and at any version a container event
/// re-lists the containers but not the images, so only the container
/// list follows a container created or removed.
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
/// A details view that shows a container ([openContainer]) has it
/// inspected (03 §7.12 CTR-03, CTR-04): one [DockerContainerQuery] as the
/// first view opens, and another whenever the container's row in a
/// delivered list changes, or a read that waited on the endpoint can run
/// once it is ready again. A list without the container, or an inspect
/// the engine answers with [DockerQueryFailure.notFound], says it was
/// removed. The details live here only while a view shows them: inspect
/// output is never kept, synced or stored (03 §8.9).
///
/// Every query and watch id is minted here and never reused this run; at
/// most one engine query per server is in flight, and at most one inspect
/// per container a view shows. A server that leaves the fleet takes its
/// state with it and comes back without it (SYN-08), as in
/// `MonitoringController`; the engine ends its session, and with it the
/// server's watches, too.
final class DockerController {
  DockerController(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  int _count = 0;
  bool _stopped = false;

  final Map<String, _DockerServer> _servers = {};

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

  /// What [serverId]'s container watch last delivered: the containers
  /// and their list stats, or why they could not be read.
  ValueListenable<DockerContainerList> containersFor(String serverId) =>
      _server(serverId).containers;

  /// What [serverId]'s watches last delivered of its images, or why they
  /// could not be read.
  ValueListenable<DockerImageList> imagesFor(String serverId) =>
      _server(serverId).images;

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

  /// A details view shows the container [containerId] (its full id) on
  /// [serverId]; [closeContainer] says it no longer does. The first view
  /// has the container inspected; every view of it shares what the
  /// returned listenable holds, which stays valid until the last closes.
  ValueListenable<DockerContainerDetails> openContainer(
    String serverId,
    String containerId,
  ) {
    final server = _server(serverId);
    final inspected = server.inspected.putIfAbsent(
      containerId,
      () => _InspectedContainer(_summaryIn(server, containerId)),
    );
    inspected.views++;
    if (inspected.views > 1) return inspected.details;

    if (!_listed(serverId)) {
      inspected.details.value = const DockerContainerDetails(
        failure: DockerQueryFailed(DockerQueryFailure.notInFleet),
      );
    } else {
      _inspect(serverId, containerId, inspected);
    }
    return inspected.details;
  }

  /// The last view to close lets the container's details go.
  void closeContainer(String serverId, String containerId) {
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
        statsFor: server.statsFor,
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
        if (rose) _read(serverId, server);
      case DockerEndpointState(:final serverId):
        if (!_listed(serverId)) return;
        final server = _server(serverId);
        final before = server.endpoint.value;
        server.endpoint.value = event;
        // The details describe the endpoint they were read over.
        if (!_sameEndpoint(before, event)) {
          server.engine.value = null;
          if (event.phase == DockerEndpointPhase.ready) {
            _inspectAfterFailure(serverId, server);
          }
        }
        _readIfShown(serverId, server);
      case DockerResult(:final serverId, :final queryId, :final payload):
        final server = _servers[serverId];
        if (server == null) return;
        if (server.engineQuery != queryId) {
          _takeInspect(serverId, server, queryId, payload);
          return;
        }
        server.engineQuery = null;
        switch (payload) {
          // Nothing was read because no endpoint was ready: its state
          // says why, and once one is, a shown tab reads again.
          case DockerQueryFailed(
            failure: DockerQueryFailure.linkUnavailable ||
                DockerQueryFailure.profileUnknown ||
                DockerQueryFailure.endpointUnavailable ||
                DockerQueryFailure.cancelled,
          ):
            break;
          case _:
            server.engine.value = payload;
        }
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
        if ((list, payload) case (
          DockerWatchList.containers,
          DockerContainersPayload(:final containers),
        )) {
          _followInspected(serverId, server, containers);
        }
        if (list == DockerWatchList.images) {
          server.images.value = server.images.value.took(payload, at);
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

  void dispose() {
    unawaited(_events.cancel());
    _stopped = true;
    for (final server in _servers.values) {
      server.dispose();
    }
    _servers.clear();
  }
}

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
  final ValueNotifier<DockerContainerList> containers = ValueNotifier(
    const DockerContainerList(),
  );
  final ValueNotifier<DockerImageList> images = ValueNotifier(
    const DockerImageList(),
  );
  final ValueNotifier<DockerStackList> stacks = ValueNotifier(
    const DockerStackList(),
  );

  /// The engine query in flight, whose answer [engine] takes.
  String? engineQuery;

  /// How many Docker tabs show the server.
  int views = 0;

  /// Whether the server's last [LinkState] was a usable link.
  bool linked = false;

  /// How many Containers views show the server.
  int containerViews = 0;

  /// The container watch the engine holds, while any view shows.
  String? watchId;

  /// The containers whose stats the watch reads: the rows on screen.
  Set<String> statsFor = const {};

  /// How many Images views show the server.
  int imageViews = 0;

  /// The image watch the engine holds, while any Images view shows.
  String? imagesWatchId;

  /// How many Stacks views show the server.
  int stackViews = 0;

  /// The stack watch the engine holds, while any Stacks view shows.
  String? stacksWatchId;

  /// The containers details views show, by full id.
  final Map<String, _InspectedContainer> inspected = {};

  void dispose() {
    endpoint.dispose();
    engine.dispose();
    containers.dispose();
    images.dispose();
    stacks.dispose();
    for (final container in inspected.values) {
      container.dispose();
    }
  }
}
