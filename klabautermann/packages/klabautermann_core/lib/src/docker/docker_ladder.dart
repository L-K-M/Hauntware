/// Endpoint discovery and the transport ladder (03 §5.4, §5.9; CN-07):
/// which engine socket the Docker client reaches, and how.
///
/// ```text
///   candidates: override, then the probe's sockets in 03 §5.4 order
///   each ─▶ rank 1: open direct-streamlocal ─▶ route
///            └─ refused, or a Dropbear before 2024.84 (CN-15)
///                 ─▶ one exec probe (test -S, test -w)
///                 ├─ missing ─▶ next candidate
///                 ├─ denied, admin mode on ─▶ rank 3: sudo and the
///                 │    engine CLI's dial-stdio ─▶ route
///                 ├─ denied ─▶ next candidate (sudo: needs admin mode)
///                 └─ reachable, so forwarding is off
///                      ├─ rank 2: the engine CLI's dial-stdio ─▶ route
///                      ├─ rank 4: socat, then nc -U ─▶ route
///                      └─ no relay ─▶ next candidate
///   none left ─▶ DockerRouteNone with the first reason in precedence
/// ```
///
/// Rank 3, the sudo relay (M4 E16, plan M7), is offered only while admin
/// mode is on. The ladder only
/// opens a rank 1 channel to see that it works and closes it again; it
/// starts no relay, so a relay whose CLI cannot reach the daemon shows
/// first when the client pings through it; the engine's Docker session
/// then runs the ladder again without that route.
library;

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ByteDuplex, validateAbsolutePath, validateSocketPath;
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ChannelRefusal,
        ElevationAttempt,
        ElevationException,
        ElevationFailureKind,
        RemoteCommandException,
        SshLink,
        quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import 'dropbear.dart';
import 'duplex_adapters.dart';

/// A rung of 03 §5.9's ladder that M3 builds. Rank 3 (the sudo relay)
/// joins with admin mode in M4.
enum DockerRank {
  /// `direct-streamlocal` to the engine socket; costs no session.
  streamlocal(1, DockerRouteLabel.socketForward),

  /// The engine CLI's `system dial-stdio`, one session per connection.
  cliRelay(2, DockerRouteLabel.cliRelay),

  /// The same `dial-stdio` through admin mode's elevation: `sudo -n`
  /// first, then the password prelude; one elevated exec per connection,
  /// and only while admin mode is on (plan M7).
  sudoRelay(3, DockerRouteLabel.sudoRelay),

  /// `socat STDIO UNIX-CONNECT:<path>` or `nc -U <path>`, one session
  /// per connection.
  socketRelay(4, DockerRouteLabel.socatRelay);

  const DockerRank(this.number, this.label);

  /// The rank as 03 §5.9 numbers it.
  final int number;

  /// What the server header names this rank by.
  final DockerRouteLabel label;
}

/// The header labels of 03 §5.9 (E4), one per built rank plus none; the
/// app words them.
enum DockerRouteLabel {
  /// "Engine API via SSH socket forward".
  socketForward,

  /// "via docker CLI relay (limited streams)".
  cliRelay,

  /// "via sudo relay (root-equivalent)".
  sudoRelay,

  /// "via socat relay", also for `nc -U`.
  socatRelay,

  /// No route: Docker panels hidden with the reason.
  none,
}

/// The SAF-08 badge a route earns (03 §8.4).
enum DockerRootEquivalence {
  /// A rootful engine's socket: root-equivalent.
  rootfulSocket,

  /// A rootless engine: equals its user.
  rootlessEngine,

  /// A custom socket path whose engine the probe cannot classify; shown
  /// as root-equivalent until the engine tells otherwise.
  unclassified,

  /// The sudo relay: root-equivalent whatever the engine, since it runs
  /// as root (SAF-08's "sudo relay: root-equivalent" badge).
  sudoRelay,
}

/// Why no rung reached an engine, in precedence order: when several
/// candidates fail, the route names the first of their reasons here.
enum DockerNoRouteReason {
  /// The socket is reachable but forwarding is off, and the host has no
  /// relay: no engine CLI the probe saw, no usable socat, no `nc` with
  /// `-U`.
  noRelay,

  /// The user cannot write the socket and sudo exists: the sudo relay of
  /// admin mode (M4).
  needsAdminMode,

  /// The user cannot write the socket and there is no sudo; the access
  /// check carries the fix.
  socketDenied,

  /// The exec probe failed or answered something unreadable.
  probeFailed,

  /// No candidate socket exists: none was detected, or each was gone
  /// when probed.
  noSocket,

  /// The capability probe has not answered its sockets area and no
  /// override names one.
  socketsUnknown,
}

/// What [DockerLadder.resolve] found.
@immutable
sealed class DockerRouteResult {
  const DockerRouteResult();

  /// The header label (E4).
  DockerRouteLabel get label;
}

/// A rung that reaches an engine socket.
final class DockerRoute extends DockerRouteResult {
  const DockerRoute._({
    required this.rank,
    required this.socketPath,
    required this.runtime,
    required this.mode,
    this.relayArgv = const [],
  });

  final DockerRank rank;

  /// The engine socket, validated absolute.
  final String socketPath;

  /// The engine the path names (03 §5.4), or null for a custom path the
  /// probe cannot classify. The API's ping settles a Podman behind a
  /// Docker path later (M13).
  final EngineRuntime? runtime;

  /// Rootful or rootless by the path; null with [runtime].
  final EngineMode? mode;

  /// The relay's words on relay ranks, empty on [DockerRank.streamlocal].
  final List<String> relayArgv;

  @override
  DockerRouteLabel get label => rank.label;

  DockerRootEquivalence get rootEquivalence => switch (mode) {
    _ when rank == DockerRank.sudoRelay => DockerRootEquivalence.sudoRelay,
    EngineMode.rootful => DockerRootEquivalence.rootfulSocket,
    EngineMode.rootless => DockerRootEquivalence.rootlessEngine,
    null => DockerRootEquivalence.unclassified,
  };

  /// Routes are equal when they reach the same path the same way, so the
  /// engine can exclude one that failed and run the ladder again.
  @override
  bool operator ==(Object other) =>
      other is DockerRoute &&
      other.rank == rank &&
      other.socketPath == socketPath &&
      _sameWords(other.relayArgv, relayArgv);

  @override
  int get hashCode => Object.hash(rank, socketPath, Object.hashAll(relayArgv));

  @override
  String toString() =>
      'DockerRoute(${rank.name}, $socketPath, ${runtime?.name}, '
      '${mode?.name}, $relayArgv)';
}

bool _sameWords(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// No rung reaches an engine.
final class DockerRouteNone extends DockerRouteResult {
  const DockerRouteNone._(this.reason);

  final DockerNoRouteReason reason;

  @override
  DockerRouteLabel get label => DockerRouteLabel.none;

  @override
  String toString() => 'DockerRouteNone(${reason.name})';
}

/// Why a path cannot be CN-09's chosen engine socket (D54).
enum DockerSocketPathProblem {
  /// It does not start with `/`, which an empty path does not either.
  notAbsolute,

  /// It holds a NUL or a line break (03 §8.8).
  unsafeCharacter,
}

/// Why [path] cannot name the engine socket a server's endpoint uses, or
/// null when the ladder and the CLI's `--host unix://` option take it as
/// written (`validateSocketPath`, 03 §8.8). The app checks a typed path
/// with it, the settings store a stored one, and the engine every
/// [DockerLadder.resolve] override.
DockerSocketPathProblem? dockerSocketPathProblem(String path) {
  if (!path.startsWith('/')) return DockerSocketPathProblem.notAbsolute;
  try {
    validateSocketPath(path);
    return null;
  } on ArgumentError {
    return DockerSocketPathProblem.unsafeCharacter;
  }
}

/// Why [path] cannot name a server's `docker` program (CN-16), or null
/// when the relays and compose commands run it as written. The rules are
/// [dockerSocketPathProblem]'s, since the program is an argv word as the
/// socket path is; the app checks a typed path with it, and the engine
/// every program it is sent.
DockerSocketPathProblem? dockerProgramPathProblem(String path) =>
    dockerSocketPathProblem(path);

/// Opens one duplex over [route] on [link]: a streamlocal channel, or a
/// fresh relay process per connection (03 §5.9). The sudo relay starts
/// through [admin]'s elevation and fails without it, as when admin mode
/// ended since the route was found.
Future<ByteDuplex> openDockerDuplex(
  SshLink link,
  DockerRoute route, {
  AdminSession? admin,
}) async {
  if (route.rank == DockerRank.streamlocal) {
    return SshDuplexAdapter(await link.openUnixStream(route.socketPath));
  }
  if (route.rank == DockerRank.sudoRelay) {
    if (admin == null) {
      throw const ElevationException(ElevationFailureKind.unavailable, '');
    }
    return ProcessDuplex(
      await admin.executor.start(
        route.relayArgv,
        password: admin.password,
        attempt: ElevationAttempt.nopasswdFirst,
      ),
    );
  }

  final command = HostCommands.commandLine(
    route.relayArgv,
    quote: quoteShellWord,
  );
  return ProcessDuplex(await link.start(command));
}

/// The ladder of 03 §5.9 over one link (M8).
abstract final class DockerLadder {
  /// Finds the first route to an engine: [override] (CN-09, D54), then
  /// the sockets [profile] found, in 03 §5.4's order. A refused
  /// streamlocal open costs one exec probe of that path. A link failure
  /// other than a forwarding refusal propagates, since it tells nothing
  /// about the path.
  ///
  /// A route in [excluding], one the engine reached but could not talk
  /// to, is passed over: an excluded streamlocal route skips its path,
  /// since a relay would reach the same socket, and an excluded relay
  /// gives way to the next relay of its path.
  ///
  /// A socket the user cannot write is reached through the sudo relay
  /// while [adminMode] is on (rank 3).
  ///
  /// [dockerProgram], the server's `docker` program path override
  /// (CN-16), names the CLI the relays run in place of the `docker` on
  /// the exec `PATH`, which counts as present whether the probe found a
  /// `docker` or not.
  ///
  /// Throws an [ArgumentError] when [override] or [dockerProgram] is not
  /// an absolute path free of NUL and line breaks.
  static Future<DockerRouteResult> resolve(
    SshLink link,
    HostProfile profile, {
    String? override,
    String? dockerProgram,
    Set<DockerRoute> excluding = const {},
    bool adminMode = false,
  }) async {
    if (override != null) validateAbsolutePath(override);
    if (dockerProgram != null) validateAbsolutePath(dockerProgram);

    final candidates = _candidates(profile, override);
    if (candidates.isEmpty) {
      final answered = profile.areaStatuses['sockets'] == SectionStatus.ok;
      return DockerRouteNone._(
        answered
            ? DockerNoRouteReason.noSocket
            : DockerNoRouteReason.socketsUnknown,
      );
    }

    var reason = DockerNoRouteReason.noSocket;
    for (final candidate in candidates) {
      final outcome = await _try(
        link,
        profile,
        candidate,
        excluding,
        dockerProgram: dockerProgram,
        adminMode: adminMode,
      );
      switch (outcome) {
        case DockerRoute():
          return outcome;
        case DockerRouteNone(reason: final r) when r.index < reason.index:
          reason = r;
        case DockerRouteNone():
          break;
      }
    }
    return DockerRouteNone._(reason);
  }

  static Future<DockerRouteResult> _try(
    SshLink link,
    HostProfile profile,
    _Candidate candidate,
    Set<DockerRoute> excluding, {
    required String? dockerProgram,
    required bool adminMode,
  }) async {
    final path = candidate.path;
    if (excluding.contains(candidate.route(DockerRank.streamlocal))) {
      return const DockerRouteNone._(DockerNoRouteReason.noSocket);
    }
    // CN-15: a Dropbear older than 2024.84 has no Unix stream forwarding,
    // so its refusal is known before asking.
    final dropbear = DropbearRelease.fromIdentification(
      link.seen.serverIdentification,
    );
    if (dropbear == null || dropbear.forwardsUnixStreams) {
      try {
        final duplex = await link.openUnixStream(path);
        await duplex.close();
        return candidate.route(DockerRank.streamlocal);
      } on ChannelOpenException catch (e) {
        if (e.refusal != ChannelRefusal.forwardDisabled) rethrow;
      }
    }

    final probe = await _probe(link, path);
    switch (probe) {
      case null:
        return const DockerRouteNone._(DockerNoRouteReason.probeFailed);
      case (access: _SocketAccess.missing, netcat: _):
        return const DockerRouteNone._(DockerNoRouteReason.noSocket);
      case (access: _SocketAccess.denied, netcat: _)
          when adminMode && _hasSudo(profile):
        return _sudoRelay(profile, candidate, excluding, dockerProgram);
      case (access: _SocketAccess.denied, netcat: _):
        return DockerRouteNone._(
          _hasSudo(profile)
              ? DockerNoRouteReason.needsAdminMode
              : DockerNoRouteReason.socketDenied,
        );
      case (access: _SocketAccess.reachable, netcat: final netcat):
        return _relay(
          profile,
          candidate,
          excluding,
          dockerProgram,
          netcat: netcat,
        );
    }
  }

  /// Rank 2 when the probe saw a CLI that reaches this engine, else rank
  /// 4: socat when the probe saw it and the path is safe in a socat
  /// address, else `nc -U` when the exec probe found an `nc` with `-U`.
  /// The first of these not in [excluding] wins.
  static DockerRouteResult _relay(
    HostProfile profile,
    _Candidate candidate,
    Set<DockerRoute> excluding,
    String? dockerProgram, {
    required bool netcat,
  }) {
    final path = candidate.path;
    final host = validateSocketPath(path);
    final relays = [
      for (final (:binary, :hostOption) in _presentClis(
        profile,
        candidate.runtime,
        dockerProgram,
      ))
        candidate.route(
          DockerRank.cliRelay,
          relayArgv: [binary, hostOption, host, 'system', 'dial-stdio'],
        ),
      if (profile.toolPresent('socat') == true && _socatSafePath.hasMatch(path))
        candidate.route(
          DockerRank.socketRelay,
          relayArgv: ['socat', 'STDIO', 'UNIX-CONNECT:$path'],
        ),
      if (netcat)
        candidate.route(DockerRank.socketRelay, relayArgv: ['nc', '-U', path]),
    ];
    for (final route in relays) {
      if (!excluding.contains(route)) return route;
    }
    return const DockerRouteNone._(DockerNoRouteReason.noRelay);
  }

  /// Rank 3: a CLI the probe saw that reaches this engine, through
  /// sudo. A host without one has no sudo relay.
  static DockerRouteResult _sudoRelay(
    HostProfile profile,
    _Candidate candidate,
    Set<DockerRoute> excluding,
    String? dockerProgram,
  ) {
    final host = validateSocketPath(candidate.path);
    for (final (:binary, :hostOption) in _presentClis(
      profile,
      candidate.runtime,
      dockerProgram,
    )) {
      final route = candidate.route(
        DockerRank.sudoRelay,
        relayArgv: [binary, hostOption, host, 'system', 'dial-stdio'],
      );
      if (!excluding.contains(route)) return route;
    }
    return const DockerRouteNone._(DockerNoRouteReason.noRelay);
  }

  /// The one exec probe of a refused path: whether it is a socket,
  /// whether the user may write it, and whether the `nc` on the exec
  /// `PATH` has `-U` (the capability probe lists socat but not nc). The
  /// path is a positional parameter of a constant script, so it is never
  /// parsed as shell text. Null when the probe fails or answers something
  /// else.
  static Future<_Probe?> _probe(SshLink link, String path) async {
    final command = HostCommands.commandLine([
      'sh',
      '-c',
      _probeScript,
      'sh',
      path,
    ], quote: quoteShellWord);
    try {
      final result = await link.run(
        command,
        timeout: _probeTimeout,
        maxOutputBytes: _probeMaxOutputBytes,
      );
      if (!result.succeeded) return null;
      return _parseProbe(result.stdout);
    } on RemoteCommandException {
      return null;
    } on ChannelOpenException {
      return null;
    }
  }

  static _Probe? _parseProbe(String stdout) {
    final codes = [
      for (final line in stdout.trim().split('\n')) int.tryParse(line.trim()),
    ];
    if (codes case [final socket?, final writable?, final netcat?]) {
      final access = socket != 0
          ? _SocketAccess.missing
          : writable != 0
          ? _SocketAccess.denied
          : _SocketAccess.reachable;
      return (access: access, netcat: netcat == 0);
    }
    return null;
  }

  static bool _hasSudo(HostProfile profile) => switch (profile.sudoKind) {
    SudoKind.sudo || SudoKind.sudoRs || SudoKind.unknown => true,
    SudoKind.none || null => false,
  };

  /// [override] first, then each socket the probe found, in 03 §5.4's
  /// order rather than the probe's.
  static List<_Candidate> _candidates(HostProfile profile, String? override) {
    final detected = [
      for (final s in profile.engineSockets)
        if (s.exists && s.path != override) ?classifyEngineSocket(s),
    ]..sort((a, b) => _discoveryOrder(a).compareTo(_discoveryOrder(b)));

    return [
      if (override != null) _Candidate.of(override),
      for (final e in detected) _Candidate(e.socket.path, e.runtime, e.mode),
    ];
  }

  static int _discoveryOrder(EngineEndpoint e) => switch ((e.runtime, e.mode)) {
    (EngineRuntime.docker, EngineMode.rootful) => 0,
    (EngineRuntime.docker, EngineMode.rootless) => 1,
    (EngineRuntime.podman, EngineMode.rootful) => 2,
    (EngineRuntime.podman, EngineMode.rootless) => 3,
  };

  /// The CLIs whose `dial-stdio` reaches [runtime]'s socket, preferred
  /// first. Docker's is taken to be a plain byte proxy, so it is also
  /// offered for Podman's compat socket [U]. Podman's pings `/_ping` and
  /// expects the Libpod API (`pkg/bindings/connection.go`); it only warns
  /// when a Docker socket lacks it, but whether its relay then works is
  /// untested, so the ladder conservatively never offers it there.
  static List<_RelayCli> _relayClis(EngineRuntime? runtime) =>
      switch (runtime) {
        EngineRuntime.docker => const [_RelayCli.docker],
        EngineRuntime.podman => const [_RelayCli.podman, _RelayCli.docker],
        null => const [_RelayCli.docker, _RelayCli.podman],
      };

  /// The relay CLIs for [runtime] the server can run, in order, each by
  /// the program it runs: [dockerProgram] for `docker` when the user set
  /// one, else a CLI the probe saw on the exec `PATH`.
  static List<({String binary, String hostOption})> _presentClis(
    HostProfile profile,
    EngineRuntime? runtime,
    String? dockerProgram,
  ) => [
    for (final cli in _relayClis(runtime))
      if (cli == _RelayCli.docker && dockerProgram != null)
        (binary: dockerProgram, hostOption: cli.hostOption)
      else if (profile.toolPresent(cli.binary) == true)
        (binary: cli.binary, hostOption: cli.hostOption),
  ];
}

/// The exec probe's script; `$1` is the socket path. Each line is an exit
/// status: `test -S`, `test -w`, and whether `nc`'s usage names `-U`.
///
/// Not every `nc` has `-U`: BusyBox's, the one an Alpine host has, and
/// netcat-traditional's do not, and only print their usage for it, so a
/// relay through them would fail at its first request and leave the
/// endpoint unreachable instead of naming no relay (M3 D22). OpenBSD's
/// and ncat list `-U` in the usage `-h` prints; the others print theirs,
/// without it, for `-h` too. A missing `nc` prints nothing grep matches.
const _probeScript =
    r'test -S "$1"; echo $?; test -w "$1"; echo $?; '
    r'nc -h </dev/null 2>&1 | grep -q -e -U; echo $?';

/// The exec probe's bound [E]: two builtins and `nc`'s usage.
const _probeTimeout = Duration(seconds: 10);

/// The probe prints three short lines; more is not its answer.
const _probeMaxOutputBytes = 256;

/// Socket paths socat's address parser reads as written: socat splits an
/// address at `:` and `,` and treats `!!`, quotes and brackets specially
/// (socat(1) "ADDRESS SPECIFICATIONS"), so any other path goes to
/// `nc -U`, which takes it as a word of its own.
final _socatSafePath = RegExp(r'^/[A-Za-z0-9._/+-]+$');

/// A CLI with `system dial-stdio` and its global endpoint option (03
/// §5.4: the endpoint is always named, so no context or environment
/// picks another engine).
enum _RelayCli {
  docker('docker', '--host'),

  /// Podman's hidden `system dial-stdio` (Podman 4.0 and later,
  /// `cmd/podman/system/dial_stdio.go`) dials the global `--url`, which
  /// also switches on remote mode (podman(1)).
  podman('podman', '--url');

  const _RelayCli(this.binary, this.hostOption);

  final String binary;
  final String hostOption;
}

enum _SocketAccess { missing, denied, reachable }

typedef _Probe = ({_SocketAccess access, bool netcat});

final class _Candidate {
  const _Candidate(this.path, this.runtime, this.mode);

  /// An override, classified by its path when it is a 03 §5.4 one.
  factory _Candidate.of(String path) {
    final endpoint = classifyEngineSocket(
      EngineSocket(path: path, exists: true, writable: false),
    );
    return _Candidate(path, endpoint?.runtime, endpoint?.mode);
  }

  final String path;
  final EngineRuntime? runtime;
  final EngineMode? mode;

  DockerRoute route(DockerRank rank, {List<String> relayArgv = const []}) =>
      DockerRoute._(
        rank: rank,
        socketPath: path,
        runtime: runtime,
        mode: mode,
        relayArgv: List.unmodifiable(relayArgv),
      );
}
