import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// Saves one server's endpoints, or removes them when empty:
/// `DeviceSettingsStore.setTlsEndpoints`.
typedef SaveTlsEndpoints =
    Future<void> Function(String serverId, List<TlsEndpoint> endpoints);

/// The endpoints CRT-01 checks for each server, chosen on this device
/// (03 §7.10): none until the user lists some in the System tab's
/// Certificates section. The composition root restores them from
/// `settings.json` and saves each change there; without [save], as in
/// tests, they are held in memory only. Like the stack folders, they
/// outlive an engine run.
final class TlsEndpoints extends ChangeNotifier {
  TlsEndpoints({Map<String, List<TlsEndpoint>> stored = const {}, this._save})
    : _endpoints = {
        for (final MapEntry(:key, :value) in stored.entries)
          key: List.unmodifiable(value),
      };

  final Map<String, List<TlsEndpoint>> _endpoints;
  final SaveTlsEndpoints? _save;

  /// [serverId]'s endpoints, in the order the user gave them.
  List<TlsEndpoint> endpointsFor(String serverId) =>
      _endpoints[serverId] ?? const [];

  /// Makes [endpoints] [serverId]'s, at once, and saves them. A save that
  /// fails rethrows, and the endpoints hold until the app quits, so the
  /// caller can say they were not kept.
  Future<void> setEndpoints(
    String serverId,
    List<TlsEndpoint> endpoints,
  ) async {
    if (endpoints.isEmpty) {
      _endpoints.remove(serverId);
    } else {
      _endpoints[serverId] = List.unmodifiable(endpoints);
    }
    notifyListeners();
    await _save?.call(serverId, endpoints);
  }
}

/// Why [parseTlsEndpoints] took no endpoints.
enum TlsEndpointsProblem { notEndpoint, tooMany }

/// [text]'s endpoints, one per line, blank lines dropped and repeats kept
/// once; or why they cannot be checked: a line that is not `host`,
/// `host:port` or an IP address, or more than [kTlsEndpointsMax].
({List<TlsEndpoint> endpoints, TlsEndpointsProblem? problem}) parseTlsEndpoints(
  String text,
) {
  final endpoints = <TlsEndpoint>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final endpoint = TlsEndpoint.parse(line);
    if (endpoint == null) {
      return (endpoints: const [], problem: TlsEndpointsProblem.notEndpoint);
    }
    if (!endpoints.contains(endpoint)) endpoints.add(endpoint);
  }
  if (endpoints.length > kTlsEndpointsMax) {
    return (endpoints: const [], problem: TlsEndpointsProblem.tooMany);
  }
  return (endpoints: endpoints, problem: null);
}
