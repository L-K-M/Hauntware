import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerSummary, NetworkSummary;

import 'docker_resource_view.dart';

/// The Networks sub-tab's columns, whose names key them in the table and
/// its sort (03 §7.15 DNW-01).
enum NetworkColumn { name, driver, scope, subnet, gateway, use }

/// Which networks the Networks sub-tab lists (DNW-01): every one, or the
/// user-defined ones no container is on.
enum NetworkFilter { all, unused }

/// How many containers hold an endpoint on each network, by name, as
/// [containers] (the full list) name them: a running container's
/// networks carry its address there, and a stopped one holds none.
Map<String, int> containersByNetwork(List<ContainerSummary> containers) =>
    countContainerUse(containers, (container) => container.networks.keys);

/// One network the tab lists, with how many containers are on it.
final class NetworkEntry extends DockerResourceEntry<NetworkSummary> {
  const NetworkEntry(super.summary, super.containers);

  NetworkSummary get network => summary;

  /// Whether [network] is one of the engine's own (`bridge`, `host`,
  /// `none`), which stay.
  bool get builtin => network.isBuiltin;

  /// Whether no container is on [network], a user-defined one; false
  /// while unknown.
  @override
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
}) => dockerResourceEntries(
  networks,
  countUse: containersByNetwork,
  create: NetworkEntry.new,
  keeps: (entry, filter) => filter == NetworkFilter.all || entry.unused,
  matches: networkMatches,
  nameOf: (network) => network.name,
  containers: containers,
  filter: filter,
  terms: terms,
);

/// Whether every term of [terms] is in [network]'s name, driver or
/// subnet.
bool networkMatches(NetworkSummary network, List<String> terms) =>
    matchesTerms(terms, [network.name, ?network.driver, ?network.subnet]);

/// The gateway of [network]'s first configured subnet, the one the list
/// shows beside it.
String? networkGateway(NetworkSummary network) =>
    network.ipam.isEmpty ? null : network.ipam.first.gateway;
