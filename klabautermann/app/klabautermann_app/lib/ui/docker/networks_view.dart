import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerSummary, NetworkSummary;

/// The Networks sub-tab's columns, whose names key them in the table and
/// its sort (03 §7.15 DNW-01).
enum NetworkColumn { name, driver, scope, subnet, gateway, use }

/// Which networks the Networks sub-tab lists (DNW-01): every one, or the
/// user-defined ones no container is on.
enum NetworkFilter { all, unused }

/// How many containers hold an endpoint on each network, by name, as
/// [containers] (the full list) name them: a running container's
/// networks carry its address there, and a stopped one holds none.
Map<String, int> containersByNetwork(List<ContainerSummary> containers) {
  final counts = <String, int>{};
  for (final container in containers) {
    for (final name in container.networks.keys) {
      counts.update(name, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  return counts;
}

/// One network the tab lists, with how many containers are on it.
final class NetworkEntry {
  const NetworkEntry(this.network, this.containers);

  final NetworkSummary network;

  /// How many containers hold an endpoint on [network], or null while no
  /// container list was read: the network list itself names none.
  final int? containers;

  /// Whether [network] is one of the engine's own (`bridge`, `host`,
  /// `none`), which stay.
  bool get builtin => network.isBuiltin;

  /// Whether no container is on [network], a user-defined one; false
  /// while unknown.
  bool get unused => containers == 0 && !builtin;
}

/// [networks] as the tab lists them: those [filter] and [terms] keep, in
/// the engine's order, each with its use counted from [containers] when
/// one was read.
List<NetworkEntry> networkEntries(
  List<NetworkSummary> networks, {
  required List<ContainerSummary>? containers,
  required NetworkFilter filter,
  required List<String> terms,
}) {
  final byNetwork = containers == null ? null : containersByNetwork(containers);
  return [
    for (final network in networks)
      if (NetworkEntry(
            network,
            byNetwork == null ? null : byNetwork[network.name] ?? 0,
          )
          case final entry
          when (filter == NetworkFilter.all || entry.unused) &&
              networkMatches(network, terms))
        entry,
  ];
}

/// Whether every term of [terms] is in [network]'s name, driver or
/// subnet.
bool networkMatches(NetworkSummary network, List<String> terms) {
  if (terms.isEmpty) return true;

  final haystack = [
    network.name,
    ?network.driver,
    ?network.subnet,
  ].join('\n').toLowerCase();
  return terms.every(haystack.contains);
}

/// The gateway of [network]'s first configured subnet, the one the list
/// shows beside it.
String? networkGateway(NetworkSummary network) =>
    network.ipam.isEmpty ? null : network.ipam.first.gateway;
