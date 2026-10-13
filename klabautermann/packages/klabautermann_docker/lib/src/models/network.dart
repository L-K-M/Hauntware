import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../masking.dart';
import '../time.dart';

/// 03 §7.15 DNW-01: the built-in networks are protected from removal.
const Set<String> builtinNetworkNames = {'bridge', 'host', 'none'};

/// One IPAM configuration (`IPAM.Config[]`).
@immutable
final class NetworkIpamConfig {
  const NetworkIpamConfig({this.subnet, this.gateway, this.ipRange});

  final String? subnet;
  final String? gateway;
  final String? ipRange;

  static NetworkIpamConfig parse(JsonReader r) => NetworkIpamConfig(
    subnet: r.string('Subnet'),
    gateway: r.string('Gateway'),
    ipRange: r.string('IPRange'),
  );
}

/// One attached container (`Containers` map value).
@immutable
final class NetworkContainer {
  const NetworkContainer({
    this.name,
    this.endpointId,
    this.macAddress,
    this.ipv4Address,
    this.ipv6Address,
  });

  final String? name;
  final String? endpointId;
  final String? macAddress;
  final String? ipv4Address;
  final String? ipv6Address;

  static NetworkContainer parse(JsonReader r) => NetworkContainer(
    name: r.string('Name'),
    endpointId: r.string('EndpointID'),
    macAddress: r.string('MacAddress'),
    ipv4Address: r.string('IPv4Address'),
    ipv6Address: r.string('IPv6Address'),
  );
}

/// One network as `GET /networks` reports it (03 §7.15 DNW-01).
@immutable
final class NetworkSummary {
  const NetworkSummary({
    required this.id,
    required this.name,
    this.driver,
    this.scope,
    this.created,
    this.enableIpv6 = false,
    this.internal = false,
    this.attachable = false,
    this.ingress = false,
    this.configOnly = false,
    this.ipam = const [],
    this.containers = const {},
    this.labels = const {},
    this.options = const {},
  });

  final String id;
  final String name;
  final String? driver;
  final String? scope;
  final DateTime? created;
  final bool enableIpv6;
  final bool internal;
  final bool attachable;
  final bool ingress;
  final bool configOnly;
  final List<NetworkIpamConfig> ipam;
  final Map<String, NetworkContainer> containers;
  final Map<String, MaskedValue> labels;
  final Map<String, String> options;

  /// Built-in networks are protected (03 §7.15 DNW-01).
  bool get isBuiltin => builtinNetworkNames.contains(name);

  /// The first configured subnet, for list display.
  String? get subnet => ipam.isEmpty ? null : ipam.first.subnet;

  static NetworkSummary parse(JsonReader r) {
    final ipamMap = r.map('IPAM');
    final ipam = <NetworkIpamConfig>[];
    if (ipamMap != null) {
      final ir = JsonReader(ipamMap, r.warnings);
      for (final e in ir.list('Config') ?? const <Object?>[]) {
        if (e is Map) {
          ipam.add(
            NetworkIpamConfig.parse(JsonReader(asStringMap(e), r.warnings)),
          );
        }
      }
    }
    final containers = <String, NetworkContainer>{};
    final containerMap = r.map('Containers');
    if (containerMap != null) {
      for (final e in containerMap.entries) {
        final v = e.value;
        if (v is Map) {
          containers[e.key] = NetworkContainer.parse(
            JsonReader(asStringMap(v), r.warnings),
          );
        }
      }
    }
    return NetworkSummary(
      id: r.string('Id') ?? '',
      name: r.string('Name') ?? '',
      driver: r.string('Driver'),
      scope: r.string('Scope'),
      created: dateTimeFromString(r.string('Created')),
      enableIpv6: r.boolean('EnableIPv6') ?? false,
      internal: r.boolean('Internal') ?? false,
      attachable: r.boolean('Attachable') ?? false,
      ingress: r.boolean('Ingress') ?? false,
      configOnly: r.boolean('ConfigOnly') ?? false,
      ipam: ipam,
      containers: containers,
      labels: maskedLabels(r.stringMap('Labels')),
      options: r.stringMap('Options'),
    );
  }
}

/// Parses the `GET /networks` array (03 §7.15 DNW-01); never throws.
DockerParseResult<List<NetworkSummary>> parseNetworkSummaries(Object? decoded) {
  final warnings = <String>[];
  if (decoded is! List) {
    warnings.add('network list is not a JSON array');
    return DockerParseResult(const <NetworkSummary>[], warnings);
  }
  final out = <NetworkSummary>[];
  for (final e in decoded) {
    if (e is Map) {
      out.add(NetworkSummary.parse(JsonReader(asStringMap(e), warnings)));
    } else {
      warnings.add('network list entry is not an object');
    }
  }
  return DockerParseResult(out, warnings);
}
