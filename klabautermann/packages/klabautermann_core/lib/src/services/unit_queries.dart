// The v1 unit reads (03 §7.5; M5 plan M22): a unit's file and drop-ins
// (SVC-07), its resources (SVC-08) and the sockets (SVC-10), for the
// system manager or the login user's (SVC-09). Each runs as the login
// user, never through sudo: `systemctl cat`, `show` and `list-sockets`
// need no privilege, and sudo would address root's user manager.
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue;
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        HostCommandError,
        HostCommands,
        HostProfile,
        UnitManager,
        UnitTableFormat,
        parseUnitResources,
        parseUnitSockets;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult, SshLink, quoteShellWord;

import '../engine/protocol.dart';
import '../sampling/argument_masking.dart' show maskCommandLine;

/// The first systemd release whose `list-sockets` prints JSON (03 §6.4).
const int _jsonTablesSince = 246;

/// The most of a failure's error text a [UnitQueryFailed] carries.
const int _detailLimit = 500;

/// An `Environment=` assignment, whose values the unit file view masks.
final _environment = RegExp(r'^(\s*Environment\s*=\s*)(.*)$');

/// An `Exec*=` command line, which can carry a secret argument.
final _exec = RegExp(r'^(\s*Exec[A-Za-z]*\s*=\s*)(.*)$');

/// Runs [query] on [link], the server [profile] describes; never throws.
Future<UnitQueryResult> runUnitQuery(
  String serverId,
  String requestId,
  UnitQuerySpec query, {
  required SshLink link,
  required HostProfile profile,
}) async {
  UnitQueryResult answer(
    UnitPayload payload, [
    List<String> warnings = const [],
  ]) => UnitQueryResult(
    serverId: serverId,
    requestId: requestId,
    payload: payload,
    warnings: warnings,
  );

  final manager = switch (query.scope) {
    UnitScope.system => const UnitManager.system(),
    UnitScope.user => UnitManager.userFor(
      uid: profile.uid,
      xdgRuntimeDir: profile.xdgRuntimeDir,
    ),
  };
  final json = (profile.systemdVersion ?? 0) >= _jsonTablesSince;
  final format = json ? UnitTableFormat.json : UnitTableFormat.text;

  try {
    final argv = switch (query) {
      UnitFileQuery(:final unit) => HostCommands.unitFile(
        unit,
        manager: manager,
      ),
      UnitResourcesQuery(:final unit) => HostCommands.unitResources(
        unit,
        manager: manager,
      ),
      SocketsQuery() => HostCommands.unitSockets(format, manager: manager),
    };
    final result = await link.run(
      HostCommands.commandLine(argv, quote: quoteShellWord),
      stdin: const [],
    );
    if (result.exitCode != 0) return answer(_failure(result));

    switch (query) {
      case UnitFileQuery():
        return answer(UnitFilePayload(maskUnitFile(result.stdout)));
      case UnitResourcesQuery():
        final parsed = parseUnitResources(result.stdout);
        return answer(UnitResourcesPayload(parsed.value), parsed.warnings);
      case SocketsQuery():
        final parsed = parseUnitSockets(result.stdout, format);
        return answer(UnitSocketsPayload(parsed.value), parsed.warnings);
    }
  } on HostCommandError {
    return answer(const UnitQueryFailed(UnitQueryFailure.invalidUnit));
  } on RemoteCommandException {
    return answer(const UnitQueryFailed(UnitQueryFailure.noLink));
  }
}

/// What a failed `systemctl` says went wrong, read from its stderr.
UnitQueryFailed _failure(RemoteCommandResult result) {
  final stderr = result.stderr.trim();
  if (stderr.contains('Failed to connect to bus') ||
      stderr.contains('XDG_RUNTIME_DIR')) {
    return const UnitQueryFailed(UnitQueryFailure.managerUnavailable);
  }
  if (stderr.contains('No files found') || stderr.contains('not found')) {
    return const UnitQueryFailed(UnitQueryFailure.notFound);
  }
  return UnitQueryFailed(
    UnitQueryFailure.failed,
    detail: stderr.length > _detailLimit
        ? stderr.substring(0, _detailLimit)
        : stderr,
  );
}

/// [text], `systemctl cat`'s output, with each `Environment=` value masked
/// whole and secrets in `Exec*=` lines masked as a process's arguments are
/// (03 §8.9). Over-masking is the safe direction: the reveal shows the
/// real text.
List<MaskedValue> maskUnitFile(String text) {
  final spans = <MaskedValue>[];
  final plain = StringBuffer();

  void flush() {
    if (plain.isEmpty) return;
    spans.add(MaskedValue.plain(plain.toString()));
    plain.clear();
  }

  final lines = text.split('\n');
  for (final (index, line) in lines.indexed) {
    final last = index == lines.length - 1;
    final environment = _environment.firstMatch(line);
    final exec = environment == null ? _exec.firstMatch(line) : null;
    final match = environment ?? exec;
    final value = match?[2] ?? '';
    if (match == null || value.isEmpty) {
      plain.write(line);
    } else {
      plain.write(match[1]);
      flush();
      if (environment != null) {
        spans.add(MaskedValue.secret(value));
      } else {
        final masked = maskCommandLine([value]).single;
        if (masked.isMasked) {
          spans.add(masked);
        } else {
          plain.write(value);
        }
      }
    }
    if (!last) plain.write('\n');
  }
  flush();
  return spans;
}
