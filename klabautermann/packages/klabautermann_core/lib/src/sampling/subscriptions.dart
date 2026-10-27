import '../engine/protocol.dart';

/// The sampling subscriptions the engine holds (03 §6.4, D45): each keyed
/// by its server and subscription id with its own streams, so dropping one
/// surface's subscription never stops another's. The engine samples the
/// union of a server's streams at [profile]'s cadence
/// (`SamplingScheduler`).
final class SamplingSubscriptions {
  /// Server id to subscription id to streams; no entry holds an empty set.
  final Map<String, Map<String, Set<SampleStream>>> _byServer = {};

  /// The servers that may hold subscriptions, once [fleet] named them;
  /// until then, any server.
  Set<String>? _fleet;

  /// The 03 §6.4 cadence column for every subscription.
  CadenceProfile profile = CadenceProfile.desktop;

  /// Server id to the slowest column it may sample at (SAF-19's
  /// per-server caps), kept apart from the [fleet] so a server that
  /// leaves and returns keeps its cap.
  final Map<String, CadenceProfile> _caps = {};

  /// Caps [serverId]'s cadence at [cap]'s column; null lifts the cap.
  void capServer(String serverId, CadenceProfile? cap) {
    if (cap == null) {
      _caps.remove(serverId);
    } else {
      _caps[serverId] = cap;
    }
  }

  /// The column [serverId] samples at: [profile], or its cap when that
  /// is slower (the columns run from the fastest to the slowest).
  CadenceProfile profileFor(String serverId) => switch (_caps[serverId]) {
    final cap? when cap.index > profile.index => cap,
    _ => profile,
  };

  /// Names the fleet's servers (03 §5.1): one it no longer lists loses
  /// its subscriptions, and a [Subscribe] for a server outside it is
  /// ignored, so a request that crossed the server's removal cannot bring
  /// them back.
  set fleet(Set<String> serverIds) {
    _fleet = Set.unmodifiable(serverIds);
    _byServer.removeWhere((serverId, _) => !serverIds.contains(serverId));
  }

  /// Records [request], replacing the streams an earlier subscription with
  /// the same ids named. One that names no stream holds nothing, so it is
  /// dropped instead, and one for a server outside the [fleet] is
  /// ignored.
  void subscribe(Subscribe request) {
    if (_fleet case final fleet? when !fleet.contains(request.serverId)) {
      return;
    }
    if (request.streams.isEmpty) {
      _drop(request.serverId, request.subscriptionId);
      return;
    }

    (_byServer[request.serverId] ??= {})[request.subscriptionId] =
        Set.unmodifiable(request.streams);
  }

  /// Drops [request]'s subscription; one the engine does not hold is
  /// ignored.
  void unsubscribe(Unsubscribe request) =>
      _drop(request.serverId, request.subscriptionId);

  /// The streams at least one subscription names for [serverId]; empty
  /// when none does.
  Set<SampleStream> streamsFor(String serverId) => {
    for (final streams
        in _byServer[serverId]?.values ?? const <Set<SampleStream>>[])
      ...streams,
  };

  /// The streams [serverId]'s subscription [subscriptionId] names, or null
  /// when the engine holds no such subscription.
  Set<SampleStream>? streamsOf(String serverId, String subscriptionId) =>
      _byServer[serverId]?[subscriptionId];

  /// The servers at least one subscription names.
  Set<String> get servers => Set.unmodifiable(_byServer.keys);

  void _drop(String serverId, String subscriptionId) {
    final subscriptions = _byServer[serverId];
    if (subscriptions == null) return;

    subscriptions.remove(subscriptionId);
    if (subscriptions.isEmpty) _byServer.remove(serverId);
  }
}
