/// Parser for NET-04's listening ports (03 §7.4), as
/// [HostCommands.listeningPorts] prints them.
library;

import 'dart:math';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show HostCommands, kPortsCgroupMarker, kPortsToolMarker;
import 'process_detail.dart' show ProcessAttribution, attributionFromCgroup;

/// Which tool listed the sockets.
enum PortsTool {
  ss,

  /// BusyBox's or net-tools' `netstat -tulpn`.
  netstat,

  /// Neither is installed.
  none,
}

enum PortProtocol { tcp, udp }

/// A process holding a listening socket.
@immutable
final class PortProcess {
  const PortProcess({required this.name, required this.pid});

  /// Its command name, as the kernel cuts it.
  final String name;
  final int pid;
}

/// One listening TCP socket or bound UDP socket (NET-04).
@immutable
final class ListeningSocket {
  ListeningSocket({
    required this.protocol,
    required this.address,
    required this.port,
    required List<PortProcess> processes,
  }) : processes = List.unmodifiable(processes);

  final PortProtocol protocol;

  /// The local address without brackets, with any `%interface` suffix:
  /// `0.0.0.0`, `::`, `127.0.0.53%lo`; `*` where the tool names none.
  final String address;
  final int port;

  /// The processes holding it; empty where they belong to another user,
  /// whose sockets' owners only root may see.
  final List<PortProcess> processes;

  /// Whether it accepts connections on every address of its family.
  bool get everyAddress => const {'0.0.0.0', '::', '*'}.contains(address);
}

/// [HostCommands.listeningPorts]' answer.
@immutable
final class ListeningPortsRead {
  ListeningPortsRead({
    required this.tool,
    required List<ListeningSocket> sockets,
    required Map<int, ProcessAttribution> owners,
  }) : sockets = List.unmodifiable(sockets),
       owners = Map.unmodifiable(owners);

  final PortsTool tool;

  /// By port, TCP before UDP at the same port.
  final List<ListeningSocket> sockets;

  /// What owns each listed process, by PID: its systemd unit and its
  /// container, from its cgroups. A process that ended before its
  /// cgroups were read is absent.
  final Map<int, ProcessAttribution> owners;
}

/// One holder's fields after its name in ss's `users:` column.
final _ssHolderTail = RegExp(r'",pid=(\d{1,10}),fd=\d{1,10}\)');

/// The longest process name ss prints: it reads `/proc/<pid>/comm` into
/// 16 bytes with the NUL.
const _ssNameMax = 15;
final _netstatProcess = RegExp(r'^(\d+)/(.*)$');

/// The read in [raw], or null when it is not the read's output.
ListeningPortsRead? parseListeningPorts(String raw) {
  final lines = raw.split('\n');
  final tool = switch (lines.first.trim()) {
    '$kPortsToolMarker ss' => PortsTool.ss,
    '$kPortsToolMarker netstat' => PortsTool.netstat,
    '$kPortsToolMarker none' => PortsTool.none,
    _ => null,
  };
  if (tool == null) return null;

  final sockets = <ListeningSocket>[];
  final cgroups = <int, List<String>>{};
  List<String>? cgroup;
  for (final line in lines.skip(1)) {
    if (line.startsWith('$kPortsCgroupMarker ')) {
      final pid = int.tryParse(line.substring(kPortsCgroupMarker.length + 1));
      cgroup = pid == null ? null : (cgroups[pid] = []);
      continue;
    }
    if (cgroup != null) {
      if (line.isNotEmpty) cgroup.add(line);
      continue;
    }
    final socket = switch (tool) {
      PortsTool.ss => _ssLine(line),
      PortsTool.netstat => _netstatLine(line),
      PortsTool.none => null,
    };
    if (socket != null) sockets.add(socket);
  }

  sockets.sort((a, b) {
    final byPort = a.port.compareTo(b.port);
    if (byPort != 0) return byPort;
    final byProtocol = a.protocol.index.compareTo(b.protocol.index);
    return byProtocol != 0 ? byProtocol : a.address.compareTo(b.address);
  });
  return ListeningPortsRead(
    tool: tool,
    sockets: sockets,
    owners: {
      for (final MapEntry(key: pid, value: lines) in cgroups.entries)
        if (lines.isNotEmpty) pid: attributionFromCgroup(lines),
    },
  );
}

/// `tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))`
ListeningSocket? _ssLine(String line) {
  final words = line.trim().split(RegExp(r'\s+'));
  if (words.length < 5) return null;
  final protocol = _protocol(words[0]);
  final local = _hostPort(words[4]);
  if (protocol == null || local == null) return null;
  final users = line.indexOf('users:(');
  final seen = <int>{};
  return ListeningSocket(
    protocol: protocol,
    address: local.$1,
    port: local.$2,
    processes: [
      if (users >= 0)
        for (final p in _ssHolders(line.substring(users + 7).trimRight()))
          if (seen.add(p.pid)) p,
    ],
  );
}

/// The holders in ss's `users:(...)` column after its `users:(`:
/// `("sshd",pid=812,fd=3),("sshd",pid=813,fd=3))`.
///
/// ss prints each name as `/proc/<pid>/comm` holds it, with only
/// unprintable bytes replaced, and any user names their own processes, so
/// a name may itself hold `",pid=1,fd=3)` to claim another pid. The
/// column is read as a whole, with names of at most [_ssNameMax]
/// characters, and the holders are kept only when exactly one reading
/// fits; an ambiguous or malformed column lists none.
List<PortProcess> _ssHolders(String column) {
  // ways[i]: how many readings (0, 1 or 2 for "several") the column has
  // from a holder starting at i, and the end of that holder in the one
  // reading that counts. Filled from the right, so no recursion.
  final ways = List.filled(column.length + 1, 0);
  final ends = List.filled(column.length + 1, -1);
  for (var i = column.length - 2; i >= 0; i--) {
    if (!column.startsWith('("', i)) continue;
    for (var n = 0; n <= _ssNameMax; n++) {
      final tail = _ssHolderTail.matchAsPrefix(column, i + 2 + n);
      if (tail == null) continue;
      final end = tail.end;
      final rest = switch (column.length - end) {
        1 when column[end] == ')' => 1,
        > 1 when column[end] == ',' => ways[end + 1],
        _ => 0,
      };
      if (rest == 0) continue;
      ways[i] = min(2, ways[i] + rest);
      ends[i] = end;
    }
  }
  if (ways[0] != 1) return const [];

  final holders = <PortProcess>[];
  for (var i = 0; i < column.length && ends[i] >= 0; i = ends[i] + 1) {
    final tail = _ssHolderTail.matchAsPrefix(
      column,
      column.lastIndexOf('",pid=', ends[i]),
    )!;
    holders.add(
      PortProcess(
        name: column.substring(i + 2, tail.start),
        pid: int.parse(tail[1]!),
      ),
    );
  }
  return holders;
}

/// `tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN 812/sshd` and, for UDP, the same
/// without a state; `-` where the process is another user's.
ListeningSocket? _netstatLine(String line) {
  final words = line.trim().split(RegExp(r'\s+'));
  if (words.length < 6) return null;
  final protocol = _protocol(words[0]);
  final local = _hostPort(words[3]);
  if (protocol == null || local == null) return null;
  if (protocol == PortProtocol.tcp && words[5] != 'LISTEN') return null;
  // net-tools prints the command line cut to 20 characters, which can
  // hold spaces (`812/sshd: /usr/sbi`); BusyBox prints the bare name.
  final start = words.indexWhere(_netstatProcess.hasMatch, 5);
  final process = start < 0
      ? null
      : _netstatProcess.firstMatch(words.sublist(start).join(' '));
  return ListeningSocket(
    protocol: protocol,
    address: local.$1,
    port: local.$2,
    processes: [
      if (process != null)
        PortProcess(name: process[2]!, pid: int.parse(process[1]!)),
    ],
  );
}

PortProtocol? _protocol(String word) => switch (word) {
  'tcp' || 'tcp6' => PortProtocol.tcp,
  'udp' || 'udp6' => PortProtocol.udp,
  _ => null,
};

/// `0.0.0.0:22`, `[::]:80`, `*:68`, `127.0.0.53%lo:53`, `:::22`
/// (netstat's IPv6 any) as the address without brackets and the port.
(String, int)? _hostPort(String word) {
  final colon = word.lastIndexOf(':');
  if (colon < 0) return null;
  final port = int.tryParse(word.substring(colon + 1));
  if (port == null || port < 0 || port > 65535) return null;
  var host = word.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return (host.isEmpty ? '*' : host, port);
}
