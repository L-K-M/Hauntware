part of '../docker_controller.dart';

/// One ref-counted engine watch of a server's lists (ARC-03, CTL-07): how
/// many views hold it, the watch id the engine holds while any do, and the
/// lists it asks for.
///
/// [readsStats] also reads the containers' list stats, as the Containers
/// view's watch does (CST-01); [waitsForEndpoint] starts only once the
/// endpoint is ready, as the Overview's does (OV-05). Those are the two
/// ways a watch differs from the rest.
final class _ViewWatch {
  _ViewWatch({
    required this.mintId,
    required this.lists,
    this.readsStats = false,
    this.waitsForEndpoint = false,
  });

  /// Mints this run's next watch id, which no other watch or query reuses.
  final String Function() mintId;

  /// The engine lists the watch asks for.
  final Set<DockerWatchList> lists;

  /// Whether the watch reads the containers' list stats too (CST-01).
  final bool readsStats;

  /// Whether the watch waits for a ready endpoint before it starts
  /// (OV-05).
  final bool waitsForEndpoint;

  /// How many views hold the watch.
  int views = 0;

  /// The engine's watch id while one is held; null once none is.
  String? watchId;

  /// Sends the watch, minting its id if it has none; a stopped engine or
  /// the endpoint gate holds it. A sent watch replaces the engine's under
  /// the same id, as the rows on screen change.
  void send(
    DockerController controller,
    String serverId,
    _DockerServer server,
  ) {
    if (views == 0 || controller._stopped) return;
    if (waitsForEndpoint &&
        server.endpoint.value?.phase != DockerEndpointPhase.ready) {
      return;
    }

    final id = watchId ??= mintId();
    controller._send(
      DockerWatch(
        serverId: serverId,
        watchId: id,
        lists: lists,
        statsFor: readsStats ? server.watchedStats : const {},
      ),
    );
  }

  /// Starts the watch only while none is held, so an endpoint gate can
  /// ask again without replacing what runs.
  void start(
    DockerController controller,
    String serverId,
    _DockerServer server,
  ) {
    if (watchId != null) return;
    send(controller, serverId, server);
  }

  /// Ends the watch the engine holds, if any; a stopped engine answers
  /// nothing, so there is nothing to end.
  void end(DockerController controller, String serverId) {
    final id = watchId;
    watchId = null;
    if (id == null || controller._stopped) return;
    controller._send(DockerUnwatch(serverId: serverId, watchId: id));
  }

  /// Counts one more view and sends the watch when the first shows it;
  /// the endpoint-gated watch retries on every later view, since its sync
  /// always asks.
  void add(DockerController controller, String serverId, _DockerServer server) {
    if (gainView()) {
      send(controller, serverId, server);
    } else if (waitsForEndpoint) {
      start(controller, serverId, server);
    }
  }

  /// Counts one fewer view; the last ends the watch, and the endpoint-
  /// gated one retries, since its sync always asks.
  void remove(
    DockerController controller,
    String serverId,
    _DockerServer server,
  ) {
    if (views == 0) return;
    views--;
    if (views == 0) {
      end(controller, serverId);
    } else if (waitsForEndpoint) {
      start(controller, serverId, server);
    }
  }

  /// Ends the watch and sends it again under a new id, as a retry does.
  void retry(
    DockerController controller,
    String serverId,
    _DockerServer server,
  ) {
    if (watchId == null) return;
    end(controller, serverId);
    send(controller, serverId, server);
  }

  /// Drops the engine's watch id, as an endpoint change does; the views
  /// stay counted and the next send starts it again.
  void reset() => watchId = null;

  /// Counts one more view; whether it is the first.
  bool gainView() => ++views == 1;

  /// Counts one fewer view; whether the last hid.
  bool loseView() {
    if (views == 0) return false;
    return --views == 0;
  }
}
