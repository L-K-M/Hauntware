/// The access check (CN-24, 03 §6.1, §8.1, §10.4): pure rules from a
/// [HostProfile] to one row per access right, each `ok`, `missing` or
/// `unknown` with an enum reason and, where one exists, a copyable fix
/// command that the app never runs implicitly. A row is `missing` only
/// when the probe answered; anything it did not answer stays `unknown`,
/// never zero.
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

  /// Answered once the Docker transport and compose detection land (M3).
  pendingDockerSupport,

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
/// `Libpod-API-Version` header settles that once M3 connects.
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

/// Groups that can read the whole journal (03 §8.1); `systemd-journal`
/// is the least-privileged one and the one the fix adds.
const _journalGroups = {'systemd-journal', 'adm', 'wheel'};

/// systemd's first release with `list-units --output=json` (03 §6.4).
const _systemdJsonVersion = 246;

/// RHEL 8's systemd, the oldest on a tier A host (03 §6.6).
const _systemdOldestTested = 239;

/// Evaluates the access check over [profile].
AccessReport evaluateAccess(HostProfile profile) {
  final engines = [
    for (final s in profile.engineSockets)
      if (s.exists) ?classifyEngineSocket(s),
  ];
  final elevation = _fixElevation(profile);
  const pending = AccessReason.pendingDockerSupport;
  return AccessReport._([
    _sudoRow(profile),
    _journalRow(profile, elevation),
    _socketRow(profile, engines, elevation),
    _unknown(AccessItem.streamlocal, pending),
    _unknown(AccessItem.composePlugin, pending),
    _systemdRow(profile),
    _runtimeRow(profile, engines),
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

AccessRow _runtimeRow(HostProfile p, List<EngineEndpoint> engines) {
  const item = AccessItem.runtime;
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
