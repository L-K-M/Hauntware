part of '../docker_controller.dart';

/// The container details views show (03 §7.12 CTR-03, CTR-04): each open
/// container's inspect, ref-counted by its views, plus the details still
/// shown for servers that left the fleet (SYN-08), which say so and keep
/// what was read until their last view closes.
final class _ContainerInspects {
  _ContainerInspects(this._controller, {required this.mintQueryId});

  final DockerController _controller;

  /// Mints this run's next container query id, which no other query reuses.
  final String Function() mintQueryId;

  /// Details still shown for servers that left the fleet (SYN-08), by
  /// server and container id. Each says so and keeps what was read until
  /// its last view closes, since a view holds its listenable that long.
  final Map<(String, String), _InspectedContainer> leftFleet = {};

  /// A details view shows the container [containerId] (its full id) on
  /// [serverId]; [close] says it no longer does. The first view has the
  /// container inspected; every view of it shares what the returned
  /// listenable holds, which stays valid until the last closes.
  ValueListenable<DockerContainerDetails> open(
    String serverId,
    _DockerServer server,
    String containerId,
  ) {
    // Details a view still shows from before the server left the fleet
    // are taken back, so every view of the container shares one and each
    // close pairs with an open; they are read again.
    final kept = server.inspected.containsKey(containerId)
        ? null
        : leftFleet.remove((serverId, containerId));
    final inspected = server.inspected.putIfAbsent(
      containerId,
      () => kept ?? _InspectedContainer(_summaryIn(server, containerId)),
    );
    inspected.views++;
    if (inspected.views > 1 && kept == null) return inspected.details;

    if (!_controller._listed(serverId)) {
      inspected.details.value = inspected.details.value.copyWith(
        failure: () => const DockerQueryFailed(DockerQueryFailure.notInFleet),
      );
    } else {
      _inspect(serverId, containerId, inspected);
    }
    return inspected.details;
  }

  /// The last view to close lets the container's details go.
  void close(String serverId, _DockerServer? server, String containerId) {
    final key = (serverId, containerId);
    if (leftFleet[key] case final inspected?) {
      inspected.views--;
      if (inspected.views > 0) return;

      leftFleet.remove(key);
      inspected.dispose();
      return;
    }

    final inspected = server?.inspected[containerId];
    if (server == null || inspected == null) return;
    inspected.views--;
    if (inspected.views > 0) return;

    server.inspected.remove(containerId);
    inspected.dispose();
  }

  /// Inspects [containerId] on [serverId] again after a failure.
  void retry(String serverId, _DockerServer server, String containerId) {
    final inspected = server.inspected[containerId];
    if (inspected == null || !_controller._listed(serverId)) return;
    _inspect(serverId, containerId, inspected);
  }

  /// Takes [payload] into the details whose inspect [queryId] is; false
  /// when no open details view asked for it.
  bool take(
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
  void follow(
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
  void afterFailure(String serverId, _DockerServer server) {
    for (final MapEntry(key: containerId, value: inspected)
        in server.inspected.entries) {
      final details = inspected.details.value;
      if (details.failure == null || details.removed) continue;
      _inspect(serverId, containerId, inspected);
    }
  }

  /// Moves the details [server] still has shown into [leftFleet], each
  /// saying the server left the fleet, before the server goes; every one
  /// it has is shown, as the last view to close removes it.
  void keepShown(String serverId, _DockerServer server) {
    for (final MapEntry(key: containerId, value: inspected)
        in server.inspected.entries) {
      inspected
        ..queryId = null
        ..readAgain = false
        ..details.value = inspected.details.value.copyWith(
          failure: () => const DockerQueryFailed(DockerQueryFailure.notInFleet),
        );
      leftFleet[(serverId, containerId)] = inspected;
    }
    server.inspected.clear();
  }

  /// Settles the pending inspects of a server whose endpoint changed and
  /// whose old machine's session ended.
  void reset(_DockerServer server) {
    for (final inspected in server.inspected.values) {
      inspected
        ..queryId = null
        ..readAgain = false
        ..details.value = inspected.details.value.copyWith(
          failure: () => const DockerQueryFailed(DockerQueryFailure.cancelled),
        );
    }
  }

  /// Settles the pending inspects of a server when the engine stops.
  void onEngineDone(_DockerServer server) {
    for (final inspected in server.inspected.values) {
      if (inspected.queryId == null) continue;
      inspected.queryId = null;
      inspected.readAgain = false;
      inspected.details.value = inspected.details.value.copyWith(
        failure: () => const DockerQueryFailed(DockerQueryFailure.cancelled),
      );
    }
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
    if (!_controller._stopped) {
      final queryId = mintQueryId();
      _controller._send(
        DockerQuery(
          serverId: serverId,
          queryId: queryId,
          query: DockerContainerQuery(containerId),
        ),
      );
      if (!_controller._stopped) {
        inspected.queryId = queryId;
        return;
      }
    }
    // A stopped engine answers nothing.
    inspected.details.value = inspected.details.value.copyWith(
      failure: () => const DockerQueryFailed(DockerQueryFailure.cancelled),
    );
  }

  /// [containerId]'s row in [server]'s latest list, if listed.
  ContainerSummary? _summaryIn(_DockerServer server, String containerId) {
    for (final container
        in server.containers.value.containers ?? const <ContainerSummary>[]) {
      if (container.id == containerId) return container;
    }
    return null;
  }
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

/// Whether a container's row changed in a way its inspect may show: its
/// state, the engine's status text (a restart resets its uptime), its
/// health or its image.
bool _rowChanged(ContainerSummary before, ContainerSummary after) =>
    before.state != after.state ||
    before.status != after.status ||
    before.health != after.health ||
    before.imageId != after.imageId;
