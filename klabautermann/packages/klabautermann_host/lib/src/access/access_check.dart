/// The access check (CN-24, 03 §6.1, §8.1, §10.4): pure rules from a
/// [HostProfile], and what the engine's Docker endpoint found
/// ([DockerAccessFacts]), to one row per access right, each `ok`,
/// `missing` or `unknown` with an enum reason and, where one exists, a
/// copyable fix command that the app never runs implicitly. A row is
/// `missing` only when the probe or the endpoint answered; anything they
/// did not answer stays `unknown`, never zero.
library;

import 'package:meta/meta.dart';

import '../hws/collector.dart' show ArgValidators;
import '../hws/frames.dart' show SectionStatus;
import '../probe/host_profile.dart';

/// The three answers a row, panel or rule can give.
enum AccessStatus { ok, missing, unknown }

/// The access-check rows, in display order: the CN-24 list plus the
/// runtime per host (CN-09).
enum AccessItem {
  /// Elevation without a password (03 §8.3 rung 2): `sudo -n true`, or a
  /// blanket doas `permit nopass` where sudo is absent.
  sudoNoPassword,

  /// The whole system journal is readable (LOG-04, 03 §8.1).
  journal,

  /// The login user can connect to an engine socket (CN-07, SAF-08).
  dockerSocket,

  /// sshd allows streamlocal forwarding to the socket (03 §5.9 rank 1).
  streamlocal,

  /// The `docker compose` plugin.
  composePlugin,

  /// systemd and its version (CN-10 below 246).
  systemd,

  /// The container runtimes on the host (CN-09).
  runtime,
}

/// Why a row has its status, grouped by row. The UI words each value;
/// reasons never carry host text.
enum AccessReason {
  /// The probe area that answers the row did not report `ok`, or the
  /// probe has not run.
  probeAreaUnavailable,

  /// Logged in as root: no elevation or group is needed.
  rootLogin,

  /// `sudo -n true` succeeded: a broad NOPASSWD rule (root-equivalent).
  sudoNoPassword,

  /// sudo is absent and `doas -n true` succeeded.
  doasNoPassword,

  /// `sudo -n true` failed: sudo wants a password, or this user may not
  /// use it; the probe cannot tell which. Admin mode can still use the
  /// password (03 §8.3 rung 3). No fix is offered: a blanket NOPASSWD
  /// rule equals root (SAF-08), and narrow rules are SAF-17 (03 §8.1).
  sudoNotPasswordless,

  /// sudo is absent and doas wants a password, which no pipe can feed
  /// (03 §8.3 rung 5).
  doasNotPasswordless,

  /// Neither sudo nor doas is installed.
  noElevationTool,

  /// The user is in `systemd-journal`, `adm` or `wheel`.
  journalGroup,

  /// journalctl silently returns only the user's own entries (LOG-04).
  notInJournalGroup,

  /// The host has no `journalctl`.
  noJournal,

  /// A writable rootful socket: root-equivalent (SAF-08).
  rootfulSocket,

  /// Only rootless sockets are writable: equivalent to their user.
  rootlessSocket,

  /// Engine sockets exist but none is writable for this user.
  socketNotWritable,

  /// None of the 03 §5.4 socket candidates exists.
  noEngineSocket,

  /// The engine has not looked for the server's Docker endpoint yet: no
  /// link, or the ladder is still running (03 §5.9).
  dockerEndpointPending,

  /// sshd forwards the engine socket: the route is rank 1 (03 §5.9).
  streamlocalAllowed,

  /// sshd refused to forward a socket the user can write, so the engine
  /// is reached through a relay on the server, or not at all (03 §5.3).
  streamlocalDisabled,

  /// sshd could not open the socket as the login user, who cannot write
  /// it; the Docker socket row carries the fix.
  streamlocalSocketDenied,

  /// The endpoint failed before any socket could be tried: none exists,
  /// the exec probe failed, or the engine did not answer.
  streamlocalUntested,

  /// The `docker compose` plugin answered with its version.
  composePlugin,

  /// Only the standalone `docker-compose` (v2) exists: read-only here,
  /// and it does not verify stack sources (STK-05).
  composeStandaloneOnly,

  /// Only the Python Compose v1 exists, unmaintained since 2023 and
  /// read-only here (STK-05).
  composeLegacyOnly,

  /// Neither the plugin nor a standalone binary answered.
  noCompose,

  /// The compose CLIs are looked for once the Docker endpoint is ready.
  composeNotChecked,

  /// The command that looks for the compose CLIs failed.
  composeCheckFailed,

  /// systemd 246 or later: JSON unit and timer lists.
  systemdJson,

  /// systemd 239 to 245: the text fallbacks of CN-10.
  systemdTextFallback,

  /// Older than the oldest tier A host (RHEL 8's 239, 03 §6.6).
  systemdOlderThanTested,

  /// systemd runs, but its version line did not parse.
  systemdVersionUnparsed,

  /// PID 1 is not systemd.
  notSystemd,

  /// At least one engine socket exists.
  enginesDetected,

  /// A `docker` or `podman` CLI exists but no socket does (the Podman
  /// socket offer is CN-25, v1).
  engineCliWithoutSocket,

  /// No engine socket and no engine CLI.
  noEngine,

  /// The user chose this server's engine socket on this device (CN-09,
  /// D54), and the endpoint reaches it.
  runtimeChosenManually,

  /// The socket chosen on this device is not the one the endpoint
  /// reaches: it did not answer, so another or none was used.
  runtimeChosenUnavailable,
}

/// How a fix command is elevated. [AccessFix.argv] never carries the
/// prefix, so a later operation plan can elevate it its own way.
enum FixElevation {
  /// Root login: run as is.
  none,

  /// Prefix `sudo`.
  sudo,

  /// Prefix `doas` (no sudo on the host).
  doas,

  /// Neither sudo nor doas was found: run it in a root shell.
  rootShell,
}

/// A copyable fix (03 §6.1, §10.4): shown, never run implicitly.
@immutable
final class AccessFix {
  AccessFix(List<String> argv, this.elevation) : argv = List.unmodifiable(argv);

  /// The command words, unquoted; the caller quotes each with
  /// `quoteShellWord` (03 §8.8).
  final List<String> argv;

  final FixElevation elevation;

  /// [argv] behind its `sudo` or `doas` prefix, ready to quote and copy.
  List<String> get commandLine => switch (elevation) {
    FixElevation.sudo => ['sudo', ...argv],
    FixElevation.doas => ['doas', ...argv],
    FixElevation.none || FixElevation.rootShell => argv,
  };
}

/// One access-check row.
@immutable
final class AccessRow {
  const AccessRow(
    this.item,
    this.status,
    this.reason, {
    this.fix,
    this.rootEquivalent = false,
  });

  final AccessItem item;
  final AccessStatus status;
  final AccessReason reason;

  /// The least-privileged fix, when one exists.
  final AccessFix? fix;

  /// The SAF-08 flag (03 §8.4): holding this right, or applying [fix], is
  /// root-equivalent, so the UI shows the notice beside the row.
  final bool rootEquivalent;
}

/// The engine behind a socket path (CN-09).
enum EngineRuntime { docker, podman }

/// Rootful engines are root-equivalent; rootless ones equal their user.
enum EngineMode { rootful, rootless }

/// An existing engine socket, classified by its 03 §5.4 path. A
/// `podman-docker` install may alias the Docker path to Podman; the API's
/// `Libpod-API-Version` header settles that once the engine connects
/// (M13).
@immutable
final class EngineEndpoint {
  const EngineEndpoint(this.runtime, this.mode, this.socket);

  final EngineRuntime runtime;
  final EngineMode mode;
  final EngineSocket socket;
}

/// The evaluated access check: every [AccessItem] once, in enum order.
@immutable
final class AccessReport {
  AccessReport._(List<AccessRow> rows, List<EngineEndpoint> engines)
    : rows = List.unmodifiable(rows),
      engines = List.unmodifiable(engines);

  final List<AccessRow> rows;

  /// The sockets that exist, in probe order.
  final List<EngineEndpoint> engines;

  AccessRow row(AccessItem item) => rows[item.index];

  /// Whether the LOG-04 notice applies: true when journalctl returns only
  /// the user's own entries, false when the whole journal is readable,
  /// null when unknown or the host has no journal.
  bool? get journalLimited => switch (row(AccessItem.journal)) {
    AccessRow(status: AccessStatus.ok) => false,
    AccessRow(reason: AccessReason.notInJournalGroup) => true,
    _ => null,
  };
}

/// Whether sshd forwards the engine socket (03 §5.3, §5.9), as the
/// engine's ladder found it.
enum StreamlocalAccess {
  /// The route is rank 1.
  allowed,

  /// sshd refused the socket, which the user can write.
  disabled,

  /// sshd refused the socket, which the user cannot write.
  socketDenied,

  /// The endpoint failed before a socket could be tried.
  untested,
}

/// The compose CLIs the engine found on the server (STK-05), each version
/// as it printed it.
@immutable
final class ComposeFacts {
  const ComposeFacts({
    this.pluginVersion,
    this.standaloneVersion,
    this.standaloneLegacy = false,
  });

  /// `docker compose version`; null without the plugin.
  final String? pluginVersion;

  /// `docker-compose version`; null without the standalone binary.
  final String? standaloneVersion;

  /// Whether the standalone binary is the Python Compose v1.
  final bool standaloneLegacy;
}

/// What the engine's Docker endpoint told of the rights the probe cannot
/// see (CN-24): whether sshd forwards the socket, the compose CLIs, and
/// CN-09's socket chosen on this device. Each fact the endpoint has not
/// answered yet is null and reads as unknown.
@immutable
final class DockerAccessFacts {
  const DockerAccessFacts({
    this.streamlocal,
    this.compose,
    this.composeCheckFailed = false,
    this.chosenSocket,
    this.chosenSocketInUse,
  });

  /// Null until the ladder has run on the current link.
  final StreamlocalAccess? streamlocal;

  /// Null until the compose CLIs were looked for.
  final ComposeFacts? compose;

  /// Whether looking for the compose CLIs failed; [compose] is null then.
  final bool composeCheckFailed;

  /// The socket chosen for the server on this device (CN-09), or null
  /// when the engine finds one itself.
  final String? chosenSocket;

  /// Whether the endpoint reaches [chosenSocket]; null while it has not
  /// settled on a route or a failure.
  final bool? chosenSocketInUse;
}

/// Groups that can read the whole journal (03 §8.1); `systemd-journal`
/// is the least-privileged one and the one the fix adds.
const _journalGroups = {'systemd-journal', 'adm', 'wheel'};

/// systemd's first release with `list-units --output=json` (03 §6.4).
const _systemdJsonVersion = 246;

/// RHEL 8's systemd, the oldest on a tier A host (03 §6.6).
const _systemdOldestTested = 239;

/// Evaluates the access check over [profile] and, for the streamlocal,
/// compose and runtime rows, what the engine's Docker endpoint found
/// ([docker]; null before it reported anything).
AccessReport evaluateAccess(HostProfile profile, {DockerAccessFacts? docker}) {
  final engines = [
    for (final s in profile.engineSockets)
      if (s.exists) ?classifyEngineSocket(s),
  ];
  final elevation = _fixElevation(profile);
  return AccessReport._([
    _sudoRow(profile),
    _journalRow(profile, elevation),
    _socketRow(profile, engines, elevation),
    _streamlocalRow(docker),
    _composeRow(docker),
    _systemdRow(profile),
    _runtimeRow(profile, engines, docker),
  ], engines);
}

/// Classifies a 03 §5.4 socket candidate; null for any other path.
EngineEndpoint? classifyEngineSocket(EngineSocket socket) {
  final path = socket.path;
  if (path == '/var/run/docker.sock' || path == '/run/docker.sock') {
    return EngineEndpoint(EngineRuntime.docker, EngineMode.rootful, socket);
  }
  if (path == '/run/podman/podman.sock') {
    return EngineEndpoint(EngineRuntime.podman, EngineMode.rootful, socket);
  }
  final rootless = _rootlessSocket.firstMatch(path);
  if (rootless == null) return null;
  final runtime = rootless[1] == null
      ? EngineRuntime.docker
      : EngineRuntime.podman;
  return EngineEndpoint(runtime, EngineMode.rootless, socket);
}

final _rootlessSocket = RegExp(
  r'^/run/user/\d+/(?:docker\.sock|(podman)/podman\.sock)$',
);

AccessRow _sudoRow(HostProfile p) {
  const item = AccessItem.sudoNoPassword;
  if (p.uid == 0) return _ok(item, AccessReason.rootLogin);

  switch (p.sudoKind) {
    case null:
      return _unknown(item);
    case SudoKind.none:
      return _doasRow(p);
    case SudoKind.sudo || SudoKind.sudoRs || SudoKind.unknown:
      break;
  }

  return switch (p.sudoNonInteractive) {
    true => _ok(item, AccessReason.sudoNoPassword, rootEquivalent: true),
    false => _missing(
      item,
      AccessReason.sudoNotPasswordless,
      rootEquivalent: true,
    ),
    null => _unknown(item),
  };
}

AccessRow _doasRow(HostProfile p) {
  const item = AccessItem.sudoNoPassword;
  return switch ((p.doasPresent, p.doasNonInteractive)) {
    (false, _) => _missing(item, AccessReason.noElevationTool),
    (true, true) => _ok(
      item,
      AccessReason.doasNoPassword,
      rootEquivalent: true,
    ),
    // No doas fix: where its config lives varies by distribution [U].
    (true, false) => _missing(
      item,
      AccessReason.doasNotPasswordless,
      rootEquivalent: true,
    ),
    _ => _unknown(item),
  };
}

AccessRow _journalRow(HostProfile p, FixElevation elevation) {
  const item = AccessItem.journal;
  final journalctl = p.toolPresent('journalctl');
  if (journalctl == false) return _missing(item, AccessReason.noJournal);
  if (p.uid == 0) return _ok(item, AccessReason.rootLogin);
  if (!_answered(p, 'identity')) return _unknown(item);
  if (p.groups.any(_journalGroups.contains)) {
    return _ok(item, AccessReason.journalGroup);
  }
  if (journalctl == null) return _unknown(item);

  return _missing(
    item,
    AccessReason.notInJournalGroup,
    fix: _groupFix(p, 'systemd-journal', elevation),
  );
}

AccessRow _socketRow(
  HostProfile p,
  List<EngineEndpoint> engines,
  FixElevation elevation,
) {
  const item = AccessItem.dockerSocket;
  if (!_answered(p, 'sockets')) return _unknown(item);

  final writable = engines.where((e) => e.socket.writable);
  if (writable.isNotEmpty) {
    final rootful = writable.any((e) => e.mode == EngineMode.rootful);
    return _ok(
      item,
      rootful ? AccessReason.rootfulSocket : AccessReason.rootlessSocket,
      rootEquivalent: rootful,
    );
  }
  if (engines.isEmpty) return _missing(item, AccessReason.noEngineSocket);

  // Only the rootful Docker socket has a conventional group; a member
  // whose socket is still closed needs more than the same advice again.
  final dockerGroupHelps =
      engines.any(
        (e) =>
            e.runtime == EngineRuntime.docker && e.mode == EngineMode.rootful,
      ) &&
      !p.groups.contains('docker');
  return _missing(
    item,
    AccessReason.socketNotWritable,
    fix: dockerGroupHelps ? _groupFix(p, 'docker', elevation) : null,
    rootEquivalent: engines.any((e) => e.mode == EngineMode.rootful),
  );
}

// No fix for either: sshd_config and the compose packages differ by
// distribution and install method [U], and neither is one command.
AccessRow _streamlocalRow(DockerAccessFacts? docker) {
  const item = AccessItem.streamlocal;
  return switch (docker?.streamlocal) {
    null => _unknown(item, AccessReason.dockerEndpointPending),
    StreamlocalAccess.allowed => _ok(item, AccessReason.streamlocalAllowed),
    StreamlocalAccess.disabled => _missing(
      item,
      AccessReason.streamlocalDisabled,
    ),
    StreamlocalAccess.socketDenied => _missing(
      item,
      AccessReason.streamlocalSocketDenied,
    ),
    StreamlocalAccess.untested => _unknown(
      item,
      AccessReason.streamlocalUntested,
    ),
  };
}

AccessRow _composeRow(DockerAccessFacts? docker) {
  const item = AccessItem.composePlugin;
  final compose = docker?.compose;
  if (compose == null) {
    return _unknown(
      item,
      docker?.composeCheckFailed ?? false
          ? AccessReason.composeCheckFailed
          : AccessReason.composeNotChecked,
    );
  }
  if (compose.pluginVersion != null) {
    return _ok(item, AccessReason.composePlugin);
  }
  if (compose.standaloneVersion == null) {
    return _missing(item, AccessReason.noCompose);
  }
  return _missing(
    item,
    compose.standaloneLegacy
        ? AccessReason.composeLegacyOnly
        : AccessReason.composeStandaloneOnly,
  );
}

AccessRow _systemdRow(HostProfile p) {
  const item = AccessItem.systemd;
  switch (p.systemdDir) {
    case null:
      return _unknown(item);
    case false:
      return _missing(item, AccessReason.notSystemd);
    case true:
      break;
  }

  final version = p.systemdVersion;
  if (version == null) {
    return _unknown(item, AccessReason.systemdVersionUnparsed);
  }
  if (version >= _systemdJsonVersion) {
    return _ok(item, AccessReason.systemdJson);
  }
  if (version >= _systemdOldestTested) {
    return _ok(item, AccessReason.systemdTextFallback);
  }
  return _unknown(item, AccessReason.systemdOlderThanTested);
}

AccessRow _runtimeRow(
  HostProfile p,
  List<EngineEndpoint> engines,
  DockerAccessFacts? docker,
) {
  const item = AccessItem.runtime;
  // A choice made on this device stands whatever the probe found; the
  // endpoint tells whether it is in use.
  if (docker?.chosenSocket != null) {
    return docker!.chosenSocketInUse == false
        ? _missing(item, AccessReason.runtimeChosenUnavailable)
        : _ok(item, AccessReason.runtimeChosenManually);
  }
  if (!_answered(p, 'sockets')) return _unknown(item);
  if (engines.isNotEmpty) return _ok(item, AccessReason.enginesDetected);

  return switch ((p.toolPresent('docker'), p.toolPresent('podman'))) {
    (true, _) ||
    (_, true) => _missing(item, AccessReason.engineCliWithoutSocket),
    (false, false) => _missing(item, AccessReason.noEngine),
    _ => _unknown(item),
  };
}

AccessRow _ok(
  AccessItem item,
  AccessReason reason, {
  bool rootEquivalent = false,
}) => AccessRow(item, AccessStatus.ok, reason, rootEquivalent: rootEquivalent);

AccessRow _missing(
  AccessItem item,
  AccessReason reason, {
  AccessFix? fix,
  bool rootEquivalent = false,
}) => AccessRow(
  item,
  AccessStatus.missing,
  reason,
  fix: fix,
  rootEquivalent: rootEquivalent,
);

AccessRow _unknown(
  AccessItem item, [
  AccessReason reason = AccessReason.probeAreaUnavailable,
]) => AccessRow(item, AccessStatus.unknown, reason);

bool _answered(HostProfile p, String area) =>
    p.areaStatuses[area] == SectionStatus.ok;

FixElevation _fixElevation(HostProfile p) {
  if (p.uid == 0) return FixElevation.none;
  if (p.sudoKind case SudoKind.sudo || SudoKind.sudoRs || SudoKind.unknown) {
    return FixElevation.sudo;
  }
  if (p.doasPresent == true) return FixElevation.doas;
  return FixElevation.rootShell;
}

/// The login name, only when it passes the sampler's user-name grammar:
/// a fix is never built from unvalidated host text (03 §8.8).
String? _validUser(HostProfile p) {
  final user = p.user;
  if (user == null || ArgValidators.userName(user) != null) return null;
  return user;
}

/// Group membership takes effect at the next login. BusyBox userlands
/// (Alpine) have `addgroup` instead of shadow's `usermod`.
AccessFix? _groupFix(HostProfile p, String group, FixElevation elevation) {
  final user = _validUser(p);
  if (user == null) return null;
  final busybox =
      p.distroId == 'alpine' ||
      (p.distroIdLike?.split(' ').contains('alpine') ?? false);
  return AccessFix(
    busybox ? ['addgroup', user, group] : ['usermod', '-aG', group, user],
    elevation,
  );
}
