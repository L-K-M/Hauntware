/// Parser for MEM-03's out-of-memory kills (03 §7.1), as
/// [HostCommands.oomKills] prints them.
library;

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show
        HostCommands,
        kOomLinesKept,
        kOomReadMarker,
        kOomSourceMarker,
        kOomVmstatMarker;

/// Which kernel log [HostCommands.oomKills] read.
enum OomLogSource {
  /// `journalctl -k -b`, whose lines carry wall-clock times.
  journal,

  /// `dmesg`, whose lines carry seconds since boot.
  dmesg,
}

/// One process the kernel's OOM killer ended.
@immutable
final class OomKill {
  const OomKill({
    required this.pid,
    required this.command,
    this.at,
    this.sinceBoot,
    this.anonRssKb,
    this.cgroupLimit = false,
    this.cgroup,
  });

  final int pid;

  /// The process's command name, as the kernel cuts it (`comm`).
  final String command;

  /// When it was killed, from the journal; null from `dmesg`.
  final DateTime? at;

  /// How long after boot it was killed, from `dmesg`; null from the
  /// journal.
  final Duration? sinceBoot;

  /// Its anonymous memory when killed.
  final int? anonRssKb;

  /// Whether a memory cgroup's limit ran out, as in a container with a
  /// memory limit, rather than the whole system's memory.
  final bool cgroupLimit;

  /// The killed task's memory cgroup (`task_memcg`), where the kernel
  /// printed an `oom-kill:` line for it (Linux 4.19+).
  final String? cgroup;
}

/// [HostCommands.oomKills]' answer.
@immutable
final class OomKillsRead {
  OomKillsRead({
    required this.killsSinceBoot,
    required this.source,
    required this.logRead,
    required List<OomKill> kills,
  }) : kills = List.unmodifiable(kills);

  /// `/proc/vmstat`'s `oom_kill`; null on kernels before 4.13.
  final int? killsSinceBoot;

  final OomLogSource source;

  /// Whether the kernel log gave any line. The current boot always has
  /// kernel lines, so none means the login user may not read the log.
  final bool logRead;

  /// The current boot's kills the log names, oldest first; at most
  /// [kOomLinesKept].
  final List<OomKill> kills;
}

final _journalTime = RegExp(r'^(\d+)\.(\d{6}) ');
final _dmesgTime = RegExp(r'^\[\s*(\d+)\.(\d+)\]');
final _killed = RegExp(r'Killed process (\d+) \(([^)]*)\)');
final _anonRss = RegExp(r'anon-rss:(\d+)kB');
final _oomKillFields = RegExp(r'oom-kill:(\S+)');

/// The read in [raw], or null when it is not the read's output.
OomKillsRead? parseOomKills(String raw) {
  final lines = raw.split('\n');
  if (lines.length < 3 || !lines[0].startsWith(kOomVmstatMarker)) {
    return null;
  }
  final source = switch (lines[1].trim()) {
    '$kOomSourceMarker journal' => OomLogSource.journal,
    '$kOomSourceMarker dmesg' => OomLogSource.dmesg,
    _ => null,
  };
  if (source == null) return null;

  final readAt = lines.lastIndexWhere(
    (line) => line.startsWith(kOomReadMarker),
  );
  if (readAt < 2) return null;
  final read = int.tryParse(
    lines[readAt].substring(kOomReadMarker.length).trim(),
  );
  if (read == null) return null;

  // The kernel prints `oom-kill:` before the kill line it explains: the
  // task's memory cgroup and the limit that ran out, CONSTRAINT_MEMCG for
  // a cgroup's.
  final explained = <int, ({String? cgroup, bool memcg})>{};
  final kills = <OomKill>[];
  for (final line in lines.sublist(2, readAt)) {
    if (_oomKillFields.firstMatch(line) case final match?) {
      final fields = {
        for (final field in match[1]!.split(','))
          if (field.split('=') case [final key, final value]) key: value,
      };
      if (int.tryParse(fields['pid'] ?? '') case final pid?) {
        explained[pid] = (
          cgroup: fields['task_memcg'],
          memcg: fields['constraint'] == 'CONSTRAINT_MEMCG',
        );
      }
      continue;
    }

    final killed = _killed.firstMatch(line);
    if (killed == null) continue;
    // Digit runs past 64 bits are no pid and no stamp: the line is
    // skipped, or its time left unknown, rather than thrown on.
    final pid = int.tryParse(killed[1]!);
    if (pid == null) continue;
    final explanation = explained.remove(pid);
    kills.add(
      OomKill(
        pid: pid,
        command: killed[2]!,
        at: switch (_journalTime.firstMatch(line)) {
          final time? when source == OomLogSource.journal => _journalInstant(
            time[1]!,
            time[2]!,
          ),
          _ => null,
        },
        sinceBoot: switch (_dmesgTime.firstMatch(line)) {
          final time? when source == OomLogSource.dmesg => _sinceBoot(
            time[1]!,
            time[2]!,
          ),
          _ => null,
        },
        anonRssKb: int.tryParse(_anonRss.firstMatch(line)?[1] ?? ''),
        cgroupLimit:
            (explanation?.memcg ?? false) ||
            line.contains('Memory cgroup out of memory'),
        cgroup: explanation?.cgroup,
      ),
    );
  }

  final vmstat = lines[0].substring(kOomVmstatMarker.length).trim();
  return OomKillsRead(
    killsSinceBoot: int.tryParse(vmstat),
    source: source,
    logRead: read > 0,
    kills: kills,
  );
}

/// The journal's `<seconds>.<microseconds>` stamp as an instant, or null
/// for digits no [DateTime] holds.
DateTime? _journalInstant(String seconds, String micros) {
  final s = int.tryParse(seconds);
  final us = int.tryParse(micros);
  if (s == null || us == null || s > _maxEpochSeconds) return null;
  return DateTime.fromMicrosecondsSinceEpoch(
    s * Duration.microsecondsPerSecond + us,
    isUtc: true,
  );
}

/// dmesg's `[<seconds>.<fraction>]` stamp as a time since boot, or null
/// for digits no [Duration] holds.
Duration? _sinceBoot(String seconds, String fraction) {
  final s = int.tryParse(seconds);
  final us = int.tryParse(fraction.padRight(6, '0').substring(0, 6));
  if (s == null || us == null || s > _maxEpochSeconds) return null;
  return Duration(seconds: s, microseconds: us);
}

/// Seconds either side of which [DateTime] and a microsecond [Duration]
/// stop holding a value (100,000,000 days).
const _maxEpochSeconds = 8640000000000;
