// NET-04's parser: `ss -Htulpn` and BusyBox's `netstat -tulpn`, each
// socket's processes, and the cgroups that name their units and
// containers.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String _read(
  String tool,
  List<String> lines, {
  Map<int, List<String>>? cgroups,
}) => [
  '$kPortsToolMarker $tool',
  ...lines,
  for (final MapEntry(key: pid, value: cgroup) in (cgroups ?? {}).entries) ...[
    '$kPortsCgroupMarker $pid',
    ...cgroup,
  ],
  '',
].join('\n');

const _docker =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  test('ss lists each socket with its processes, sorted by port', () {
    final read = parseListeningPorts(
      _read(
        'ss',
        [
          'udp   UNCONN 0      0      127.0.0.53%lo:53      0.0.0.0:*    '
              'users:(("systemd-resolve",pid=600,fd=13))',
          'tcp   LISTEN 0      511    [::]:80     [::]:*    '
              'users:(("nginx",pid=1201,fd=7),("nginx",pid=1200,fd=7),'
              '("nginx",pid=1201,fd=8))',
          'tcp   LISTEN 0      4096   0.0.0.0:22  0.0.0.0:*    '
              'users:(("sshd",pid=812,fd=3))',
          'tcp   LISTEN 0      4096   127.0.0.1:5432  0.0.0.0:*',
          'tcp   LISTEN 0      4096   127.0.0.53%lo:53  0.0.0.0:*    '
              'users:(("systemd-resolve",pid=600,fd=14))',
        ],
        cgroups: {
          812: ['0::/system.slice/ssh.service'],
          1200: ['0::/system.slice/docker-$_docker.scope'],
          600: [],
        },
      ),
    )!;
    expect(read.tool, PortsTool.ss);
    expect(
      [
        for (final s in read.sockets)
          '${s.protocol.name} ${s.address} ${s.port}',
      ],
      [
        'tcp 0.0.0.0 22',
        'tcp 127.0.0.53%lo 53',
        'udp 127.0.0.53%lo 53',
        'tcp :: 80',
        'tcp 127.0.0.1 5432',
      ],
    );
    final [ssh, _, _, nginx, postgres] = read.sockets;
    expect(ssh.everyAddress, isTrue);
    expect(ssh.processes.single.name, 'sshd');
    expect(nginx.everyAddress, isTrue);
    expect([for (final p in nginx.processes) p.pid], [1201, 1200]);
    expect(postgres.processes, isEmpty);
    expect(postgres.everyAddress, isFalse);
    expect(read.owners[812]!.unit, 'ssh.service');
    expect(read.owners[1200]!.containerId, _docker);
    expect(read.owners.containsKey(600), isFalse);
  });

  test('netstat gives TCP listeners and UDP sockets with their process', () {
    final read = parseListeningPorts(
      _read('netstat', [
        'Active Internet connections (only servers)',
        'Proto Recv-Q Send-Q Local Address  Foreign Address  State   '
            'PID/Program name',
        'tcp        0      0 0.0.0.0:22     0.0.0.0:*        LISTEN  812/sshd',
        'tcp        0      0 :::8080        :::*             LISTEN  -',
        'tcp        0      0 10.0.0.5:22    10.0.0.9:51000   ESTABLISHED 900/sshd',
        'udp        0      0 0.0.0.0:68     0.0.0.0:*                600/udhcpc',
        'tcp        0      0 0.0.0.0:2222   0.0.0.0:*        LISTEN  '
            '813/sshd: /usr/sbi',
      ]),
    )!;
    expect(read.tool, PortsTool.netstat);
    expect(
      [
        for (final s in read.sockets)
          '${s.protocol.name} ${s.address} ${s.port} '
              '${s.processes.map((p) => '${p.name}/${p.pid}').join(',')}',
      ],
      [
        'tcp 0.0.0.0 22 sshd/812',
        'udp 0.0.0.0 68 udhcpc/600',
        'tcp 0.0.0.0 2222 sshd: /usr/sbi/813',
        'tcp :: 8080 ',
      ],
    );
  });

  test('without ss or netstat the read says so', () {
    final read = parseListeningPorts(_read('none', []))!;
    expect(read.tool, PortsTool.none);
    expect(read.sockets, isEmpty);
  });

  test('other output is not the read', () {
    expect(parseListeningPorts(''), isNull);
    expect(
      parseListeningPorts('tcp LISTEN 0 1 0.0.0.0:22 0.0.0.0:*\n'),
      isNull,
    );
  });
}
