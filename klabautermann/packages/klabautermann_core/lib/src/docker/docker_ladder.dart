/// Endpoint discovery and the transport ladder (03 §5.4, §5.9; CN-07):
/// which engine socket the Docker client reaches, and how.
///
/// ```text
///   candidates: override, then the probe's sockets in 03 §5.4 order
///   each ─▶ rank 1: open direct-streamlocal ─▶ route
///            └─ refused ─▶ one exec probe (test -S, test -w)
///                 ├─ missing ─▶ next candidate
///                 ├─ denied ─▶ next candidate (sudo: needs admin mode)
///                 └─ reachable, so forwarding is off
///                      ├─ rank 2: the engine CLI's dial-stdio ─▶ route
///                      ├─ rank 4: socat, then nc -U ─▶ route
///                      └─ no relay ─▶ next candidate
///   none left ─▶ DockerRouteNone with the first reason in precedence
/// ```
///
/// Rank 3, the sudo relay, arrives with admin mode in M4. The ladder only
/// opens a rank 1 channel to see that it works and closes it again; it
/// starts no relay, so a relay whose CLI cannot reach the daemon shows
/// first when the client pings through it.
library;

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ByteDuplex, validateAbsolutePath, validateSocketPath;
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ChannelRefusal,
        RemoteCommandException,
        SshLink,
        quoteShellWord;

import 'duplex_adapters.dart';

/// A rung of 03 §5.9's ladder that M3 builds. Rank 3 (the sudo relay)
/// joins with admin mode in M4.
enum DockerRank {
  /// `direct-streamlocal` to the engine socket; costs no session.
  streamlocal(1, DockerRouteLabel.socketForward),

  /// The engine CLI's `system dial-stdio`, one session per connection.
  cliRelay(2, DockerRouteLabel.cliRelay),

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
}

/// Why no rung reached an engine, in precedence order: when several
/// candidates fail, the route names the first of their reasons here.
enum DockerNoRouteReason {
  /// The socket is reachable but forwarding is off, and the host has no
  /// relay: no engine CLI the probe saw, no usable socat, no `nc`.
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
    EngineMode.rootful => DockerRootEquivalence.rootfulSocket,
    EngineMode.rootless => DockerRootEquivalence.rootlessEngine,
    null => DockerRootEquivalence.unclassified,
  };

  @override
  String toString() =>
      'DockerRoute(${rank.name}, $socketPath, ${runtime?.name}, '
      '${mode?.name}, $relayArgv)';
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

/// Opens one duplex over [route] on [link]: a streamlocal channel, or a
/// fresh relay process per connection (03 §5.9).
Future<ByteDuplex> openDockerDuplex(SshLink link, DockerRoute route) async {
  if (route.rank == DockerRank.streamlocal) {
    return SshDuplexAdapter(await link.openUnixStream(route.socketPath));
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
  /// Throws an [ArgumentError] when [override] is not an absolute path
  /// free of NUL and line breaks.
  static Future<DockerRouteResult> resolve(
    SshLink link,
    HostProfile profile, {
    String? override,
  }) async {
    if (override != null) validateAbsolutePath(override);

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
      final outcome = await _try(link, profile, candidate);
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
  ) async {
    final path = candidate.path;
    try {
      final duplex = await link.openUnixStream(path);
      await duplex.close();
      return candidate.route(DockerRank.streamlocal);
    } on ChannelOpenException catch (e) {
      if (e.refusal != ChannelRefusal.forwardDisabled) rethrow;
    }

    final probe = await _probe(link, path);
    switch (probe) {
      case null:
        return const DockerRouteNone._(DockerNoRouteReason.probeFailed);
      case (access: _SocketAccess.missing, netcat: _):
        return const DockerRouteNone._(DockerNoRouteReason.noSocket);
      case (access: _SocketAccess.denied, netcat: _):
        return DockerRouteNone._(
          _hasSudo(profile)
              ? DockerNoRouteReason.needsAdminMode
              : DockerNoRouteReason.socketDenied,
        );
      case (access: _SocketAccess.reachable, netcat: final netcat):
        return _relay(profile, candidate, netcat: netcat);
    }
  }

  /// Rank 2 when the probe saw a CLI that reaches this engine, else rank
  /// 4: socat when the probe saw it and the path is safe in a socat
  /// address, else `nc -U` when the exec probe found `nc`.
  static DockerRouteResult _relay(
    HostProfile profile,
    _Candidate candidate, {
    required bool netcat,
  }) {
    final path = candidate.path;
    final host = validateSocketPath(path);
    for (final cli in _relayClis(candidate.runtime)) {
      if (profile.toolPresent(cli.binary) != true) continue;
      return candidate.route(
        DockerRank.cliRelay,
        relayArgv: [cli.binary, cli.hostOption, host, 'system', 'dial-stdio'],
      );
    }

    if (profile.toolPresent('socat') == true && _socatSafePath.hasMatch(path)) {
      return candidate.route(
        DockerRank.socketRelay,
        relayArgv: ['socat', 'STDIO', 'UNIX-CONNECT:$path'],
      );
    }
    if (netcat) {
      return candidate.route(
        DockerRank.socketRelay,
        relayArgv: ['nc', '-U', path],
      );
    }
    return const DockerRouteNone._(DockerNoRouteReason.noRelay);
  }

  /// The one exec probe of a refused path: whether it is a socket,
  /// whether the user may write it, and whether `nc` is on the exec
  /// `PATH` (the capability probe lists socat but not nc). The path is a
  /// positional parameter of a constant script, so it is never parsed as
  /// shell text. Null when the probe fails or answers something else.
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
}

/// The exec probe's script; `$1` is the socket path. Each line is an exit
/// status: `test -S`, `test -w`, `command -v nc`.
const _probeScript =
    r'test -S "$1"; echo $?; test -w "$1"; echo $?; '
    r'command -v nc >/dev/null 2>&1; echo $?';

/// The exec probe's bound [E]: three builtins and a `PATH` lookup.
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
