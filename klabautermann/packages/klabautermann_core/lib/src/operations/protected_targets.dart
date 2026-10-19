// 03 §8.6's protected targets (SAF-22, M4 plan M9): what a plan may touch
// only with the typed confirmation, because touching it can cut this
// session off or take the host's core services down.
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ContainerPort;
import 'package:klabautermann_host/klabautermann_host.dart' show HostProfile;
import 'package:meta/meta.dart';

import '../engine/protocol.dart' show ServerSafety;

import 'plan_types.dart' show ProtectedReason;

/// The built-in protected units. A `*` matches any run of characters
/// within the name, so `wg-quick@*.service` covers every WireGuard
/// interface.
const kProtectedUnits = [
  // The session's own path.
  'ssh.service',
  'sshd.service',
  'ssh.socket',
  'sshd.socket',
  'sshd@*.service',
  // Network managers.
  'NetworkManager.service',
  'systemd-networkd.service',
  'networking.service',
  'network.service',
  'wicked.service',
  'systemd-resolved.service',
  // Firewalls.
  'firewalld.service',
  'ufw.service',
  'nftables.service',
  'iptables.service',
  'ip6tables.service',
  // VPNs.
  'tailscaled.service',
  'wg-quick@*.service',
  'zerotier-one.service',
  'openvpn.service',
  'openvpn@*.service',
  'openvpn-client@*.service',
  'openvpn-server@*.service',
  // Container engines.
  'docker.service',
  'docker.socket',
  'containerd.service',
  'podman.service',
  'podman.socket',
];

/// Process names protected wherever they run: PID 1 is protected by its
/// PID, these by their `comm`. OpenSSH 9.8 moved each connection into
/// `sshd-session`, and 10.0 its pre-auth work into `sshd-auth`.
const kProtectedComms = {
  'sshd',
  'sshd-session',
  'sshd-auth',
  'dockerd',
  'containerd',
};

/// VPN ports a published container port must not carry [guess list]: a
/// port and its protocol, null for either.
const kVpnPorts = [(51820, 'udp'), (1194, null), (41641, 'udp')];

/// The SSH port when the probe could not read the session's own.
const kDefaultSshPort = 22;

/// What the engine knows about one server's session when it plans: the
/// PIDs on its path, its SSH port and the user's marks.
@immutable
final class ProtectionContext {
  const ProtectionContext({
    this.sessionPids = const {},
    this.sshPort,
    this.marks = const {},
  });

  /// The sampler shells and their sshd parents (E07's `SELF`) and the
  /// probe's session parent (03 §6.1).
  final Set<int> sessionPids;

  /// The server port of `$SSH_CONNECTION`, or null when unknown.
  final int? sshPort;

  /// Targets the user marked protected (SAF-22).
  final Set<String> marks;
}

/// [serverId]'s context: the sampler PIDs and their parents, the probe's
/// session parent and SSH port from [profile], and the user's marks from
/// [policy].
ProtectionContext protectionContextOf({
  required Set<int> samplerPids,
  required HostProfile? profile,
  required ServerSafety? safety,
}) => ProtectionContext(
  sessionPids: {...samplerPids, ?profile?.sessionParentPid},
  sshPort: sshServerPort(profile?.sshConnection),
  marks: safety?.marks ?? const {},
);

/// The server port of `$SSH_CONNECTION`'s value (`client-ip client-port
/// server-ip server-port`), or null when it is not one.
int? sshServerPort(String? sshConnection) {
  final fields = sshConnection?.trim().split(RegExp(r'\s+'));
  if (fields == null || fields.length != 4) return null;
  final port = int.tryParse(fields[3]);
  return port != null && port > 0 && port < 65536 ? port : null;
}

/// Why [unit] is protected, or null when it is not.
ProtectedReason? unitProtection(String unit, ProtectionContext context) {
  if (context.marks.contains(unit)) return ProtectedReason.userMarked;
  for (final pattern in kProtectedUnits) {
    if (_globMatch(pattern, unit)) {
      return pattern.startsWith('ssh')
          ? ProtectedReason.sessionPath
          : ProtectedReason.builtIn;
    }
  }
  return null;
}

/// Why process [pid] named [comm] is protected, or null when it is not.
ProtectedReason? processProtection({
  required int pid,
  required String comm,
  required ProtectionContext context,
}) {
  if (context.sessionPids.contains(pid)) return ProtectedReason.sessionPath;
  if (pid == 1 || kProtectedComms.contains(comm)) {
    return ProtectedReason.builtIn;
  }
  return null;
}

/// Why the container [name] publishing [ports] is protected, or null
/// when it is not: it publishes the session's SSH port, port 22 or a VPN
/// port, or the user marked it.
ProtectedReason? containerProtection({
  required String name,
  required List<ContainerPort> ports,
  required ProtectionContext context,
}) {
  if (context.marks.contains(name)) return ProtectedReason.userMarked;
  final sshPorts = {kDefaultSshPort, ?context.sshPort};
  for (final port in ports) {
    final public = port.publicPort;
    if (public == null) continue;
    final protocol = port.type ?? 'tcp';
    if (protocol == 'tcp' && sshPorts.contains(public)) {
      return ProtectedReason.publishesSessionPort;
    }
    for (final (vpnPort, vpnProtocol) in kVpnPorts) {
      if (public == vpnPort && (vpnProtocol ?? protocol) == protocol) {
        return ProtectedReason.publishesSessionPort;
      }
    }
  }
  return null;
}

/// Why the stack [project] is protected: only the user's mark protects a
/// whole stack; its containers are checked one by one.
ProtectedReason? stackProtection(String project, ProtectionContext context) =>
    context.marks.contains(project) ? ProtectedReason.userMarked : null;

/// Whether [name] matches [pattern], whose `*` matches any run of
/// characters.
bool _globMatch(String pattern, String name) {
  final parts = pattern.split('*');
  if (parts.length == 1) return pattern == name;
  if (!name.startsWith(parts.first) || !name.endsWith(parts.last)) {
    return false;
  }
  var at = parts.first.length;
  for (final part in parts.sublist(1, parts.length - 1)) {
    final found = name.indexOf(part, at);
    if (found < 0) return false;
    at = found + part.length;
  }
  return at <= name.length - parts.last.length;
}
