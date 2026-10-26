/// Parser for NET-02's interfaces and NET-03's connection counts (03
/// §7.4), as [HostCommands.interfaces] prints them.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show
        HostCommands,
        kNetAddrMarker,
        kNetLinksMarker,
        kNetPhysicalMarker,
        kNetSockstatMarker,
        kNetTcpMarker;

/// A link's `operstate` (RFC 2863), as sysfs names it.
enum NetLinkState {
  up('up'),
  down('down'),
  dormant('dormant'),
  lowerLayerDown('lowerlayerdown'),
  notPresent('notpresent'),
  testing('testing'),

  /// The driver does not say, as for the loopback interface.
  unknown('unknown');

  const NetLinkState(this.sysfs);

  final String sysfs;

  static NetLinkState of(String? value) =>
      values.firstWhere((state) => state.sysfs == value, orElse: () => unknown);
}

enum NetAddressFamily { ipv4, ipv6 }

/// One address on an interface.
@immutable
final class NetAddress {
  const NetAddress({
    required this.family,
    required this.address,
    required this.prefixLength,
    this.scope,
  });

  final NetAddressFamily family;
  final String address;
  final int prefixLength;

  /// `ip`'s scope: `global`, `link` for link-local addresses, `host` for
  /// the loopback's; null where it printed none.
  final String? scope;

  /// Whether the address reaches beyond the link or the host.
  bool get routable => scope != 'link' && scope != 'host';
}

/// One network interface (NET-02). A figure sysfs does not give is null:
/// a down link, and most virtual ones, have no speed.
@immutable
final class NetInterface {
  NetInterface({
    required this.name,
    required this.state,
    required this.physical,
    required List<NetAddress> addresses,
    this.mtu,
    this.mac,
    this.speedMbps,
    this.rxBytes,
    this.txBytes,
    this.rxErrors,
    this.txErrors,
    this.rxDropped,
    this.txDropped,
  }) : addresses = List.unmodifiable(addresses);

  final String name;
  final NetLinkState state;

  /// Whether a device backs it, rather than software: a bridge, a bond,
  /// a VLAN, a tunnel, a veth pair or the loopback.
  final bool physical;

  final List<NetAddress> addresses;
  final int? mtu;

  /// The hardware address; null for one that has none (all zeros).
  final String? mac;

  /// The negotiated speed in megabits per second.
  final int? speedMbps;

  /// Counted since the interface came up.
  final int? rxBytes, txBytes, rxErrors, txErrors, rxDropped, txDropped;
}

/// A TCP socket's state, with the code `/proc/net/tcp` gives it.
enum TcpState {
  established(0x01),
  synSent(0x02),
  synReceived(0x03),
  finWait1(0x04),
  finWait2(0x05),
  timeWait(0x06),
  close(0x07),
  closeWait(0x08),
  lastAck(0x09),
  listen(0x0A),
  closing(0x0B),
  newSynReceived(0x0C);

  const TcpState(this.code);

  final int code;
}

/// NET-03's socket counts in the reader's network namespace.
@immutable
final class SocketCounts {
  SocketCounts({required Map<TcpState, int> tcp, this.used, this.udp})
    : tcp = Map.unmodifiable(tcp);

  /// TCP sockets over IPv4 and IPv6 by state; a state with none is
  /// absent.
  final Map<TcpState, int> tcp;

  /// `sockets: used`: every socket of every kind.
  final int? used;

  /// UDP sockets in use, over IPv4 and IPv6.
  final int? udp;
}

/// [HostCommands.interfaces]' answer.
@immutable
final class InterfacesRead {
  InterfacesRead({
    required List<NetInterface> interfaces,
    required this.addressesRead,
    required this.sockets,
  }) : interfaces = List.unmodifiable(interfaces);

  /// In sysfs order, which is by name.
  final List<NetInterface> interfaces;

  /// Whether `ip` listed the addresses; without it every interface has
  /// none.
  final bool addressesRead;

  final SocketCounts sockets;
}

final _linkLine = RegExp(r'^([^/]+)/(.+?):(.*)$');
final _oneLineAddr = RegExp(
  r'^\d+:\s+(\S+)\s+(inet6?)\s+([^\s/]+)/(\d+)(?:.*?\sscope\s+(\S+))?',
);
final _tcpLine = RegExp(r'^([0-9A-F]{2}) (\d+)$');
const _noMac = '00:00:00:00:00:00';

/// The read in [raw], or null when it is not the read's output.
InterfacesRead? parseInterfaces(String raw) {
  final lines = raw.split('\n');
  final at = [
    for (final marker in [
      kNetLinksMarker,
      kNetPhysicalMarker,
      kNetAddrMarker,
      kNetTcpMarker,
      kNetSockstatMarker,
    ])
      lines.indexOf(marker),
  ];
  if (at.first != 0) return null;
  for (var i = 1; i < at.length; i++) {
    if (at[i] <= at[i - 1]) return null;
  }
  List<String> part(int i) =>
      lines.sublist(at[i] + 1, i + 1 < at.length ? at[i + 1] : lines.length);

  final files = <String, Map<String, String>>{};
  for (final line in part(0)) {
    final match = _linkLine.firstMatch(line);
    if (match == null) continue;
    (files[match[1]!] ??= {})[match[2]!] = match[3]!.trim();
  }
  final physical = {
    for (final line in part(1))
      if (line.trim() case final name when name.isNotEmpty) name,
  };
  final addresses = _addresses(part(2).join('\n'));

  return InterfacesRead(
    interfaces: [
      for (final MapEntry(key: name, value: file) in files.entries)
        NetInterface(
          name: name,
          state: NetLinkState.of(file['operstate']),
          physical: physical.contains(name),
          addresses: addresses?[name] ?? const [],
          mtu: _count(file['mtu']),
          mac: switch (file['address']) {
            null || '' || _noMac => null,
            final mac => mac,
          },
          speedMbps: switch (_count(file['speed'])) {
            final speed? when speed > 0 => speed,
            _ => null,
          },
          rxBytes: _count(file['statistics/rx_bytes']),
          txBytes: _count(file['statistics/tx_bytes']),
          rxErrors: _count(file['statistics/rx_errors']),
          txErrors: _count(file['statistics/tx_errors']),
          rxDropped: _count(file['statistics/rx_dropped']),
          txDropped: _count(file['statistics/tx_dropped']),
        ),
    ],
    addressesRead: addresses != null,
    sockets: _sockets(part(3), part(4)),
  );
}

int? _count(String? value) => switch (int.tryParse(value ?? '')) {
  final n? when n >= 0 => n,
  _ => null,
};

/// The addresses per interface from `ip -j addr` or `ip -o addr`, or null
/// when neither printed any.
Map<String, List<NetAddress>>? _addresses(String text) {
  if (text.trim().isEmpty) return null;
  final out = <String, List<NetAddress>>{};

  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    for (final line in text.split('\n')) {
      final match = _oneLineAddr.firstMatch(line);
      if (match == null) continue;
      final name = match[1]!.split('@').first;
      (out[name] ??= []).add(
        NetAddress(
          family: match[2] == 'inet6'
              ? NetAddressFamily.ipv6
              : NetAddressFamily.ipv4,
          address: match[3]!,
          prefixLength: int.parse(match[4]!),
          scope: match[5],
        ),
      );
    }
    return out;
  }

  if (json is! List) return null;
  for (final link in json) {
    if (link case {'ifname': final String name, 'addr_info': final List info}) {
      out[name] = [
        for (final address in info)
          if (address case {
            'family': final String family,
            'local': final String local,
            'prefixlen': final int prefix,
          } when family == 'inet' || family == 'inet6')
            NetAddress(
              family: family == 'inet6'
                  ? NetAddressFamily.ipv6
                  : NetAddressFamily.ipv4,
              address: local,
              prefixLength: prefix,
              scope: switch (address['scope']) {
                final String scope => scope,
                _ => null,
              },
            ),
      ];
    }
  }
  return out;
}

SocketCounts _sockets(List<String> tcpLines, List<String> sockstat) {
  final tcp = <TcpState, int>{};
  for (final line in tcpLines) {
    final match = _tcpLine.firstMatch(line.trim());
    if (match == null) continue;
    final code = int.parse(match[1]!, radix: 16);
    final state = TcpState.values.where((s) => s.code == code).firstOrNull;
    if (state != null) tcp[state] = (tcp[state] ?? 0) + int.parse(match[2]!);
  }

  // `UDP: inuse 4 mem 2` and, from sockstat6, `UDP6: inuse 2`.
  int? used;
  int? udp;
  for (final line in sockstat) {
    final words = line.trim().split(RegExp(r'\s+'));
    int? after(String key) {
      final i = words.indexOf(key);
      return i < 0 || i + 1 >= words.length ? null : _count(words[i + 1]);
    }

    switch (words.first) {
      case 'sockets:':
        used = after('used');
      case 'UDP:' || 'UDP6:':
        if (after('inuse') case final n?) udp = (udp ?? 0) + n;
    }
  }
  return SocketCounts(tcp: tcp, used: used, udp: udp);
}
