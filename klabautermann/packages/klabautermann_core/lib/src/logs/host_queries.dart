/// The engine's one-shot host queries (03 §7.6, §10.1): each [HostQuery]
/// runs one validated command over the server's link and answers with
/// one [HostResult], whose payload holds the parsed rows or why it read
/// none. Queries run concurrently with each other and with the streams;
/// each takes one channel for as long as its command runs.
library;

import 'dart:async';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart' show parseEnv;
import 'package:seance_core/seance_core.dart' show SshLink, quoteShellWord;

import '../engine/protocol.dart';
import '../sampling/argument_masking.dart'
    show ArgumentMaskingBudget, maskCommandLine;
import 'log_service.dart' show logEndDetail, logRefusal;

/// [bundle] as it may cross (CN-18, 03 §8.9): the command lines of its
/// `procs` sections and every line of its `cron` sections masked by the
/// argument rules, as the Processes and Jobs tabs get them. The export's
/// redactor knows secret-shaped values only, not `-p<secret>` or `curl -u
/// user:pass`, so a bundle exported as read would carry them. The
/// sections keep their shape, so a report still becomes a fixture; there
/// is no reveal, and the bundle itself when nothing in it was masked.
/// Never throws.
DiagnosticBundle maskDiagnosticBundle(DiagnosticBundle bundle) {
  var changed = false;
  final sections = [
    for (final section in bundle.sections)
      switch (_maskedSectionText(section)) {
        final text when text != section.text => () {
          changed = true;
          return DiagnosticSection(
            collector: section.collector,
            status: section.status,
            text: text,
          );
        }(),
        _ => section,
      },
  ];
  return changed ? DiagnosticBundle(sections, missing: bundle.missing) : bundle;
}

String _maskedSectionText(DiagnosticSection section) {
  if (section.collector == Collector.procs.wireName) {
    return _maskedProcsText(section.text);
  }
  if (section.collector == Collector.cron.wireName) {
    final budget = ArgumentMaskingBudget();
    return section.text
        .split('\n')
        .map((line) => _maskedLine(line, budget))
        .join('\n');
  }
  return section.text;
}

/// The line that opens the command lines of a `procs` payload, and the
/// ones that say `ps` printed them (03 §7.2).
const _cmdlineBlock = '== cmdline ==';
const _psBlocks = {'== ps ==', '== ps_w =='};

/// The header `head` prints before each `/proc/<pid>/cmdline`.
final _cmdlineHeader = RegExp(r'^==> .* <==$');

/// The separator the sampler turns a cmdline's NULs into.
const _argumentSeparator = '\x1f';

/// A `procs` payload with its command lines masked: each `/proc` cmdline
/// record as its arguments, which may hold newlines, and each row of a
/// `ps` fallback as one line. A payload without the block (an error's
/// text) is masked line by line. One budget covers the section, as for a
/// procs reading.
String _maskedProcsText(String text) {
  final budget = ArgumentMaskingBudget();
  final lines = text.split('\n');
  final block = lines.indexOf(_cmdlineBlock);
  if (block == -1 ||
      (block + 1 < lines.length && _psBlocks.contains(lines[block + 1]))) {
    return [
      for (final (index, line) in lines.indexed)
        index <= block ? line : _maskedLine(line, budget),
    ].join('\n');
  }

  final masked = lines.sublist(0, block + 1);
  var record = <String>[];
  void endRecord() {
    if (record.isEmpty) return;
    masked.add(_maskedLine(record.join('\n'), budget));
    record = [];
  }

  for (final line in lines.skip(block + 1)) {
    if (_cmdlineHeader.hasMatch(line)) {
      endRecord();
      masked.add(line);
    } else {
      record.add(line);
    }
  }
  endRecord();
  return masked.join('\n');
}

/// [text], a cmdline record or a line, masked as one command line: its
/// arguments where the sampler's separator parts them, which may hold
/// newlines, else its words, as a cron line is read. An empty program
/// stands in front, since the masker never reads the program's slot as a
/// value and a host may send text whose first word is one (a forged
/// header splits a record, a crontab line starts with `NAME=secret`).
String _maskedLine(String text, ArgumentMaskingBudget budget) =>
    maskCommandLine([
      '',
      ...text.split(_argumentSeparator),
    ], budget: budget).skip(1).map((m) => m.display).join(_argumentSeparator);

/// How long one query's command may run once its channel is open.
const kHostQueryTimeout = Duration(seconds: 30);

/// The stdout a query keeps: `/var/log` two levels deep lists a few
/// hundred files of about 60 bytes each, and a boot list a line or a
/// JSON object per boot.
const kHostQueryMaxOutputBytes = 1024 * 1024;

/// Owned by the engine isolate, which hands it each [HostQuery].
final class HostQueries {
  /// [linkFor] gives a server's ready link, null while it has none;
  /// [systemdVersionOf] the major systemd version its probe found;
  /// [readDiagnostics] a sampled server's diagnostic bundle (CN-18),
  /// which its samplers read, null while it is not sampled.
  HostQueries({
    required this._linkFor,
    required this._systemdVersionOf,
    required this._emit,
    this._readDiagnostics,
    this._quote = quoteShellWord,
    this._timeout = kHostQueryTimeout,
  });

  final SshLink? Function(String serverId) _linkFor;
  final int? Function(String serverId) _systemdVersionOf;
  final void Function(EngineEvent event) _emit;
  final Future<DiagnosticBundle?> Function(String serverId)? _readDiagnostics;
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
        case DiagnosticBundleQuery():
          // Not sampled after all (the link just went, say), so nothing
          // could read it.
          final bundle = await _readDiagnostics?.call(serverId);
          answer(
            bundle == null
                ? const HostQueryFailed(HostQueryFailure.noLink)
                : maskDiagnosticBundle(bundle),
          );
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
        case ProcessDetailQuery(:final pid, :final startTicks):
          answer(await _processDetail(link, pid, startTicks));
        case ListeningPortsQuery():
          switch (await _run(link, HostCommands.listeningPorts())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              answer(switch (parseListeningPorts(stdout)) {
                final read? => ListeningPorts(read),
                null => const HostQueryFailed(
                  HostQueryFailure.failed,
                  detail: 'The listening ports read printed something else.',
                ),
              });
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
        case BootEndsQuery():
          switch (await _run(link, HostCommands.bootEnds())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              answer(BootEnds(parseBootEnds(stdout)));
          }
        case KernelsQuery():
          switch (await _run(link, HostCommands.kernels())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              answer(switch (parseKernels(stdout)) {
                final check? => Kernels(check),
                null => const HostQueryFailed(
                  HostQueryFailure.failed,
                  detail: 'The kernel read printed something else.',
                ),
              });
          }
        case CpuTopologyQuery():
          switch (await _run(link, HostCommands.cpuTopology())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              answer(switch (parseCpuTopology(stdout)) {
                final topology? => CpuTopologyRead(topology),
                null => const HostQueryFailed(
                  HostQueryFailure.failed,
                  detail: 'The processor read printed something else.',
                ),
              });
          }
        case InterfacesQuery():
          switch (await _run(link, HostCommands.interfaces())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              answer(switch (parseInterfaces(stdout)) {
                final read? => NetInterfaces(read),
                null => const HostQueryFailed(
                  HostQueryFailure.failed,
                  detail: 'The interface read printed something else.',
                ),
              });
          }
        case MountsQuery():
          switch (await _run(link, HostCommands.mounts())) {
            case _Failed(:final payload):
              answer(payload);
            case _Ran(:final stdout):
              answer(switch (parseMounts(stdout)) {
                final read? => Mounts(read),
                null => const HostQueryFailed(
                  HostQueryFailure.failed,
                  detail: 'The mounts read printed something else.',
                ),
              });
          }
      }
    } on Object catch (error) {
      answer(HostQueryFailed(HostQueryFailure.failed, detail: '$error'));
    }
  }

  /// PRC-04's read of [pid]: its details with the environment masked by
  /// key, or how it ended. The script exits with the start-ticks guard's
  /// codes when the process is gone or its PID reused.
  Future<HostPayload> _processDetail(
    SshLink link,
    int pid,
    int startTicks,
  ) async {
    final List<String> argv;
    try {
      argv = HostCommands.processDetail(pid, startTicks);
    } on HostCommandError catch (error) {
      return HostQueryFailed(HostQueryFailure.failed, detail: error.reason);
    }
    switch (await _run(link, argv, accept: _processEnds.keys.toSet())) {
      case _Failed(:final payload):
        return payload;
      case _Ran(:final exitCode) when _processEnds.containsKey(exitCode):
        return ProcessEnded(_processEnds[exitCode]!);
      case _Ran(:final stdout):
        final detail = parseProcessDetail(stdout);
        if (detail == null) {
          return const HostQueryFailed(
            HostQueryFailure.failed,
            detail: 'The process read printed something else.',
          );
        }
        return ProcessDetails(
          detail.withoutEnvironment(),
          environment: switch (detail.environment) {
            final entries? => parseEnv(entries),
            null => null,
          },
        );
    }
  }

  /// The process read's exits for a process no longer there.
  static const _processEnds = {
    kGuardedKillGone: ProcessEnd.gone,
    kProcessDetailReused: ProcessEnd.reused,
  };

  /// Runs [argv] and returns its stdout and exit status, which is 0 or
  /// one of [accept], or the failure to answer with.
  Future<_Outcome> _run(
    SshLink link,
    List<String> argv, {
    Set<int> accept = const {},
  }) async {
    try {
      final result = await link.run(
        HostCommands.commandLine(argv, quote: _quote),
        stdin: const [],
        timeout: _timeout,
        maxOutputBytes: kHostQueryMaxOutputBytes,
      );
      if (result.exitCode case final code? when accept.contains(code)) {
        return _Ran(result.stdout, exitCode: code);
      }
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
  const _Ran(this.stdout, {this.exitCode = 0});

  final String stdout;
  final int exitCode;
}

final class _Failed extends _Outcome {
  const _Failed(this.payload);

  final HostQueryFailed payload;
}
