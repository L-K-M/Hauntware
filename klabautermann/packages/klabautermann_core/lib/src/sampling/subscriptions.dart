import '../engine/protocol.dart';

/// The sampling subscriptions the engine holds (03 §6.4, D45): each keyed
/// by its server and subscription id with its own streams, so dropping one
/// surface's subscription never stops another's. The engine samples the
/// union of a server's streams at [profile]'s cadence; the scheduler that
/// does so lands with the sampling wiring.
final class SamplingSubscriptions {
  /// Server id to subscription id to streams; no entry holds an empty set.
  final Map<String, Map<String, Set<SampleStream>>> _byServer = {};

  /// The 03 §6.4 cadence column for every subscription.
  CadenceProfile profile = CadenceProfile.desktop;

  /// Records [request], replacing the streams an earlier subscription with
  /// the same ids named. One that names no stream holds nothing, so it is
  /// dropped instead.
  void subscribe(Subscribe request) {
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

  /// The servers at least one subscription names.
  Set<String> get servers => Set.unmodifiable(_byServer.keys);

  void _drop(String serverId, String subscriptionId) {
    final subscriptions = _byServer[serverId];
    if (subscriptions == null) return;

    subscriptions.remove(subscriptionId);
    if (subscriptions.isEmpty) _byServer.remove(serverId);
  }
}
