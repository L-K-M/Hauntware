/// The engine's one-shot host queries (03 §7.6, §10.1): each [HostQuery]
/// runs one validated command over the server's link and answers with
/// one [HostResult], whose payload holds the parsed rows or why it read
/// none. Queries run concurrently with each other and with the streams;
/// each takes one channel for as long as its command runs.
library;

import 'dart:async';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart' show SshLink, quoteShellWord;

import '../engine/protocol.dart';
import 'log_service.dart' show logEndDetail, logRefusal;

/// How long one query's command may run once its channel is open.
const kHostQueryTimeout = Duration(seconds: 30);

/// The stdout a query keeps: `/var/log` two levels deep lists a few
/// hundred files of about 60 bytes each, and a boot list a line or a
/// JSON object per boot.
const kHostQueryMaxOutputBytes = 1024 * 1024;

/// Owned by the engine isolate, which hands it each [HostQuery].
final class HostQueries {
  /// [linkFor] gives a server's ready link, null while it has none;
  /// [systemdVersionOf] the major systemd version its probe found.
  HostQueries({
    required this._linkFor,
    required this._systemdVersionOf,
    required this._emit,
    this._quote = quoteShellWord,
    this._timeout = kHostQueryTimeout,
  });

  final SshLink? Function(String serverId) _linkFor;
  final int? Function(String serverId) _systemdVersionOf;
  final void Function(EngineEvent event) _emit;
  final ShellQuote _quote;
  final Duration _timeout;

  /// Runs [request] and sends its [HostResult]; never throws.
  Future<void> query(HostQuery request) async {
    final HostQuery(:serverId, :queryId) = request;
    void answer(HostPayload payload, [List<String> warnings = const []]) =>
        _emit(
          HostResult(
            serverId: serverId,
            queryId: queryId,
            payload: payload,
            warnings: warnings,
          ),
        );

    final link = _linkFor(serverId);
    if (link == null) {
      return answer(const HostQueryFailed(HostQueryFailure.noLink));
    }

    // The parsers never throw on host output, but an answer must go out
    // whatever happens: the engine runs this unawaited, so an escape
    // would be an uncaught error in its isolate.
    try {
      switch (request.query) {
        case VarLogQuery():
          switch (await _run(link, HostCommands.logFiles())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              final parsed = parseLogFiles(stdout);
              answer(VarLogFiles(parsed.value), parsed.warnings);
          }
        case BootsQuery():
          final format =
              (_systemdVersionOf(serverId) ?? 0) >= kListBootsJsonSystemd
              ? JournalBootsFormat.json
              : JournalBootsFormat.text;
          switch (await _run(link, HostCommands.journalBoots(format))) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              final parsed = parseJournalBoots(stdout, format);
              answer(JournalBoots(parsed.value), parsed.warnings);
          }
        case OomKillsQuery():
          switch (await _run(link, HostCommands.oomKills())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              answer(switch (parseOomKills(stdout)) {
                final read? => OomKills(read),
                null => const HostQueryFailed(
                  HostQueryFailure.failed,
                  detail: 'The out-of-memory read printed something else.',
                ),
              });
          }
      }
    } on Object catch (error) {
      answer(HostQueryFailed(HostQueryFailure.failed, detail: '$error'));
    }
  }

  /// Runs [argv] and returns its stdout, or the failure to answer with.
  Future<_Outcome> _run(SshLink link, List<String> argv) async {
    try {
      final result = await link.run(
        HostCommands.commandLine(argv, quote: _quote),
        stdin: const [],
        timeout: _timeout,
        maxOutputBytes: kHostQueryMaxOutputBytes,
      );
      final failure = switch (result.exitCode) {
        0 => null,
        127 => HostQueryFailure.missing,
        126 => HostQueryFailure.denied,
        _ => switch (logRefusal(result.stderr)) {
          LogStreamEndReason.denied => HostQueryFailure.denied,
          LogStreamEndReason.missing => HostQueryFailure.missing,
          _ => HostQueryFailure.failed,
        },
      };
      if (failure == null) return _Ran(result.stdout);
      return _Failed(
        HostQueryFailed(failure, detail: logEndDetail(result.stderr)),
      );
      // The channel was refused, the link closed, or the command timed
      // out: a query answers rather than throws.
    } on Object catch (error) {
      return _Failed(
        HostQueryFailed(HostQueryFailure.failed, detail: '$error'),
      );
    }
  }
}

sealed class _Outcome {
  const _Outcome();
}

final class _Ran extends _Outcome {
  const _Ran(this.stdout);

  final String stdout;
}

final class _Failed extends _Outcome {
  const _Failed(this.payload);

  final HostQueryFailed payload;
}
