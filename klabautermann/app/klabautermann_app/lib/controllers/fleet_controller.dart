import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// One fleet entry as the rail renders it. The sync catalog (F3) replaces
/// this seed model with record-driven rows; keeping it tiny is the point.
final class FleetServer {
  const FleetServer({
    required this.id,
    required this.displayName,
    this.address,
  });

  /// The catalog/server id every engine request uses.
  final String id;

  final String displayName;

  /// Host or `user@host` for the row's subtitle (03 §10.3).
  final String? address;
}

/// The fleet concern (03 §10.1): the server list, per-server link phases
/// from [LinkState] events, and the workspace's selection. Pull-only by
/// construction (D14): it never sends a mutating request.
final class FleetController extends ChangeNotifier {
  FleetController(this._engine, {List<FleetServer> servers = const []})
    : _servers = List.unmodifiable(servers) {
    _events = _engine.events.listen(_onEngineEvent);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  final List<FleetServer> _servers;
  final Map<String, LinkPhase> _linkPhases = {};
  String? _selectedServerId;

  List<FleetServer> get servers => _servers;

  /// The workspace's server, or null for its empty state.
  String? get selectedServerId => _selectedServerId;

  FleetServer? get selectedServer {
    for (final server in _servers) {
      if (server.id == _selectedServerId) return server;
    }
    return null;
  }

  /// The last link phase the engine reported for [serverId]; unknown and
  /// never-connected servers read as [LinkPhase.disconnected] (03 §10.3's
  /// "unknown stays unknown" falls out of having no dot at all).
  LinkPhase linkPhaseFor(String serverId) =>
      _linkPhases[serverId] ?? LinkPhase.disconnected;

  void select(String? serverId) {
    if (serverId == _selectedServerId) return;
    _selectedServerId = serverId;
    notifyListeners();
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case LinkState(:final serverId, :final phase):
        if (_linkPhases[serverId] == phase) return;
        _linkPhases[serverId] = phase;
        notifyListeners();
      // CatalogReplaced/EndpointChanged populate the fleet once F3's
      // catalog lands; everything else belongs to other concerns.
      case CatalogReplaced():
      case EndpointChanged():
      case EngineEvent():
        break;
    }
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }
}
