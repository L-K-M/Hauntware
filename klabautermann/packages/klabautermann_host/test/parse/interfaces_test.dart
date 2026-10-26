// NET-02 and NET-03's parser: sysfs link files, the addresses from
// `ip -j addr` and BusyBox's `ip -o addr`, TCP states and sockstat.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String _read({
  List<String> links = const [],
  List<String> physical = const [],
  String addr = '',
  List<String> tcp = const [],
  List<String> sockstat = const [],
}) => [
  kNetLinksMarker,
  ...links,
  kNetPhysicalMarker,
  ...physical,
  kNetAddrMarker,
  if (addr.isNotEmpty) addr,
  kNetTcpMarker,
  ...tcp,
  kNetSockstatMarker,
  ...sockstat,
  '',
].join('\n');

List<String> _link(
  String name, {
  String state = 'up',
  int mtu = 1500,
  String mac = '52:54:00:12:34:56',
  int? speed,
  List<int> counters = const [100, 200, 1, 2, 3, 4],
}) => [
  '$name/operstate:$state',
  '$name/mtu:$mtu',
  '$name/address:$mac',
  if (speed != null) '$name/speed:$speed',
  for (final (i, file) in [
    'rx_bytes',
    'tx_bytes',
    'rx_errors',
    'tx_errors',
    'rx_dropped',
    'tx_dropped',
  ].indexed)
    '$name/statistics/$file:${counters[i]}',
];

void main() {
  test('sysfs gives each interface its state, MTU, speed and counters', () {
    final read = parseInterfaces(
      _read(
        links: [
          ..._link('eth0', speed: 1000),
          ..._link(
            'lo',
            state: 'unknown',
            mtu: 65536,
            mac: '00:00:00:00:00:00',
            speed: -1,
          ),
          ..._link('docker0', state: 'down'),
        ],
        physical: ['eth0'],
      ),
    )!;
    final [eth0, lo, docker0] = read.interfaces;
    expect(eth0.name, 'eth0');
    expect(eth0.state, NetLinkState.up);
    expect(eth0.physical, isTrue);
    expect(eth0.mtu, 1500);
    expect(eth0.mac, '52:54:00:12:34:56');
    expect(eth0.speedMbps, 1000);
    expect(
      [
        eth0.rxBytes,
        eth0.txBytes,
        eth0.rxErrors,
        eth0.txErrors,
        eth0.rxDropped,
        eth0.txDropped,
      ],
      [100, 200, 1, 2, 3, 4],
    );
    expect(lo.state, NetLinkState.unknown);
    expect(lo.physical, isFalse);
    expect(lo.mac, isNull);
    expect(lo.speedMbps, isNull);
    expect(docker0.state, NetLinkState.down);
    expect(docker0.speedMbps, isNull);
    expect(read.addressesRead, isFalse);
    expect(eth0.addresses, isEmpty);
  });

  test('ip -j addr lists each interface\'s addresses with their scope', () {
    final read = parseInterfaces(
      _read(
        links: [..._link('lo'), ..._link('eth0')],
        addr: jsonEncode([
          {
            'ifindex': 1,
            'ifname': 'lo',
            'addr_info': [
              {
                'family': 'inet',
                'local': '127.0.0.1',
                'prefixlen': 8,
                'scope': 'host',
              },
            ],
          },
          {
            'ifindex': 2,
            'ifname': 'eth0',
            'addr_info': [
              {
                'family': 'inet',
                'local': '192.0.2.10',
                'prefixlen': 24,
                'scope': 'global',
              },
              {
                'family': 'inet6',
                'local': 'fe80::5054:ff:fe12:3456',
                'prefixlen': 64,
                'scope': 'link',
              },
              {'family': 'link', 'local': 'x', 'prefixlen': 0},
            ],
          },
        ]),
      ),
    )!;
    expect(read.addressesRead, isTrue);
    final [lo, eth0] = read.interfaces;
    expect(lo.addresses.single.routable, isFalse);
    expect(
      [
        for (final a in eth0.addresses)
          (a.family, a.address, a.prefixLength, a.routable),
      ],
      [
        (NetAddressFamily.ipv4, '192.0.2.10', 24, true),
        (NetAddressFamily.ipv6, 'fe80::5054:ff:fe12:3456', 64, false),
      ],
    );
  });

  test('BusyBox ip -o addr is read line by line', () {
    final read = parseInterfaces(
      _read(
        links: [..._link('eth0'), ..._link('br-lan')],
        addr: [
          '1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever',
          '2: eth0    inet 10.0.0.5/16 brd 10.0.255.255 scope global eth0\\ '
              '      valid_lft forever preferred_lft forever',
          '3: br-lan    inet6 fd00::1/64 scope global \\       valid_lft forever',
          '4: wan@if5    inet 198.51.100.7/32 scope global wan',
        ].join('\n'),
      ),
    )!;
    expect(read.addressesRead, isTrue);
    final [eth0, brLan] = read.interfaces;
    expect(eth0.addresses.single.address, '10.0.0.5');
    expect(eth0.addresses.single.prefixLength, 16);
    expect(eth0.addresses.single.scope, 'global');
    expect(brLan.addresses.single.family, NetAddressFamily.ipv6);
  });

  test('TCP states and sockstat count the namespace\'s sockets', () {
    final read = parseInterfaces(
      _read(
        tcp: ['01 18', '0A 3', '06 1', '0C 2', 'ZZ 9', '0F 1'],
        sockstat: [
          'sockets: used 523',
          'TCP: inuse 10 orphan 0 tw 3 alloc 12 mem 1',
          'UDP: inuse 4 mem 2',
          'UDPLITE: inuse 0',
          'TCP6: inuse 3',
          'UDP6: inuse 2',
        ],
      ),
    )!;
    expect(read.interfaces, isEmpty);
    expect(read.sockets.tcp, {
      TcpState.established: 18,
      TcpState.listen: 3,
      TcpState.timeWait: 1,
      TcpState.newSynReceived: 2,
    });
    expect(read.sockets.used, 523);
    expect(read.sockets.udp, 6);
  });

  test('an unreadable /proc/net leaves the counts empty', () {
    final read = parseInterfaces(_read())!;
    expect(read.sockets.tcp, isEmpty);
    expect(read.sockets.used, isNull);
    expect(read.sockets.udp, isNull);
  });

  test('other output is not the read', () {
    expect(parseInterfaces(''), isNull);
    expect(parseInterfaces('eth0/mtu:1500\n'), isNull);
    expect(
      parseInterfaces(
        '$kNetLinksMarker\n$kNetAddrMarker\n$kNetPhysicalMarker\n'
        '$kNetTcpMarker\n$kNetSockstatMarker\n',
      ),
      isNull,
    );
  });
}
