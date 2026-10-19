import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart'
    show ProbeService, ProbeStatus, Prober, ServerConfig, TcpBannerProber;

import '../engine/protocol.dart';

/// The configs [ReachabilityService] may probe: each fleet entry whose
/// endpoint counts as confirmed on this device and that has a connect
/// config (FL-04, 03 §4.7, §5.12). A synced server has a config only
/// while confirmed; the endpoint check repeats that gate here, since
/// probing an unconfirmed endpoint would hand the user's address to
/// whoever rewrote it (SAF-09). Imports carry no endpoint and count as
/// confirmed on the device that imported them (O6's default, 03 §4.3).
/// An entry without a config (an import whose login name or route is
/// unknown) is not probed either.
List<ServerConfig> probeTargets(
  Iterable<FleetEntry> entries,
  ServerConfig? Function(String serverId) configOf,
) => [
  for (final entry in entries)
    if (entry.endpoint == null ||
        entry.endpoint == EndpointConfirmation.confirmed)
      ?configOf(entry.serverId),
];

/// Probes the fleet's confirmed endpoints and reports each answer as a
/// [Reachability] (FL-04, 03 §5.12).
///
/// It runs `seance_core`'s [ProbeService]: a TCP connect to the SSH port
/// in sweeps 45 s apart with jitter, at most 6 at once, with a server
/// that holds a link ([hasLink]) answered online without a probe. A
/// server routed through a jump host is never probed: a direct connect
/// says nothing about it, so it is reported [ReachabilityStatus.unknown].
/// The background pauses the sweeps (03 §10.1 `SetAppActivity`), and the
/// foreground sweeps at once.
///
/// Every sweep reports every target, so an answer the app dropped comes
/// back with the next. Answers always go out on a later event-loop turn
/// than [update], so they follow the fleet that lists their servers: the
/// engine sends that fleet in the same turn as the update, and the app
/// keeps answers only for servers it lists. A server that leaves the
/// targets is no longer reported, and an answer to a probe of its old
/// endpoint is dropped.
final class ReachabilityService {
  ReachabilityService({
    required this._emit,
    bool Function(String serverId)? hasLink,
    Prober prober = const TcpBannerProber(),
    @visibleForTesting Random? random,
  }) : _probes = ProbeService(prober: prober, random: random) {
    _probes.connectedServerIds = () => {
      if (hasLink != null)
        for (final id in _direct.keys)
          if (hasLink(id)) id,
    };
    _statuses = _probes.statuses.listen(_onSweep);
  }

  final void Function(Reachability event) _emit;
  final ProbeService _probes;
  late final StreamSubscription<Map<String, ProbeStatus>> _statuses;

  /// The probed servers' endpoints, by server id.
  var _direct = <String, (String, int)>{};

  /// The servers behind a jump host, reported unknown.
  var _routed = <String>{};

  var _disposed = false;

  /// Probes [targets], the fleet's confirmed configs ([probeTargets]),
  /// from now on. A target that is new, or whose endpoint changed, starts
  /// a sweep at once (unless paused); otherwise the sweeps keep their
  /// schedule.
  void update(List<ServerConfig> targets) {
    if (_disposed) return;

    final direct = [
      for (final server in targets)
        if (server.jumpHostId == null) server,
    ];
    final routed = {
      for (final server in targets)
        if (server.jumpHostId != null) server.id,
    };
    final added = direct.any(
      (server) => _direct[server.id] != (server.host, server.port),
    );
    final joined = routed.difference(_routed);
    _direct = {
      for (final server in direct) server.id: (server.host, server.port),
    };
    _routed = routed;

    if (added) {
      _probes.start(direct);
    } else {
      _probes.updateServers(direct);
    }

    if (joined.isEmpty) return;
    Timer.run(() {
      for (final id in joined) {
        if (_disposed || !_routed.contains(id)) continue;
        _emit(Reachability(id, ReachabilityStatus.unknown));
      }
    });
  }

  /// Pauses the sweeps in the [AppActivity.background] and resumes them,
  /// with one at once, in the foreground.
  set activity(AppActivity activity) {
    switch (activity) {
      case AppActivity.background:
        _probes.pause();
      case AppActivity.foreground:
        _probes.resume();
    }
  }

  /// Stops probing; nothing is reported afterwards.
  Future<void> dispose() async {
    _disposed = true;
    await _statuses.cancel();
    await _probes.dispose();
  }

  void _onSweep(Map<String, ProbeStatus> statuses) {
    if (_disposed) return;

    for (final MapEntry(key: id, value: status) in statuses.entries) {
      if (!_direct.containsKey(id)) continue;
      _emit(Reachability(id, _reachabilityOf(status)));
    }
    for (final id in _routed) {
      _emit(Reachability(id, ReachabilityStatus.unknown));
    }
  }
}

ReachabilityStatus _reachabilityOf(ProbeStatus status) => switch (status) {
  ProbeStatus.online => ReachabilityStatus.online,
  ProbeStatus.offline => ReachabilityStatus.offline,
  ProbeStatus.unknown => ReachabilityStatus.unknown,
};
