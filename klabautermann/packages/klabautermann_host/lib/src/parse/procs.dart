/// Parser for the `procs` slow-collector payload (03 §6.4, §7.2, D48):
/// the `meta` block with the total and how rows were chosen, one trimmed
/// row per kept process, the `head|tr` `cmdline` dump with its
/// forged-header rules, and the `ps -eo`/`ps w` fallback blocks.
library;

import 'package:meta/meta.dart';

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// Which argv source a `procs` payload used (03 §7.2): the `head|tr`
/// `/proc/<pid>/cmdline` dump, `ps -eo`, BusyBox `ps w`, or none.
enum ProcsArgvSource { cmdline, ps, psW, none }

/// How the `procs` fragment chose its rows (D48): every process; above
/// `kProcsRowCap` processes, the union of the top halves by CPU share since
/// start and by resident memory; or, on a host without `sort` or `head`,
/// the first rows in pid order.
enum ProcsSelection {
  all('all'),
  cpuAndMemory('cpu_rss'),
  pidOrder('pid');

  const ProcsSelection(this.wireName);

  /// The `selection=` value in the payload's `meta` block.
  final String wireName;
}

/// One process row of a `procs` tick (03 §7.2).
@immutable
final class ProcEntry {
  ProcEntry({
    required this.pid,
    this.ppid,
    this.comm,
    this.state,
    this.uid,
    this.rssKb,
    this.userName,
    this.utime,
    this.stime,
    this.startTicks,
    List<String>? argv,
    this.argsJoined,
  }) : argv = argv == null ? null : List.unmodifiable(argv);

  final int pid;

  /// Field 4 of `/proc/<pid>/stat`.
  final int? ppid;

  /// `/proc/<pid>/stat` comm: the text between the first `(` and the
  /// last `)`; may itself contain spaces and `)`. It is the label when
  /// the command line is empty (kernel threads).
  final String? comm;

  /// `/proc/<pid>/stat` field 3 (one-letter run state).
  final String? state;

  /// The real uid from `status` `Uid:`.
  final int? uid;

  /// `status` `VmRSS:` in kB; null for kernel threads, which have none.
  final int? rssKb;

  /// The `USER` column of a `ps` fallback row, when no status `Uid:`
  /// line exists (names can differ from the numeric uid).
  final String? userName;

  /// `/proc/<pid>/stat` fields 14 and 15: user and system jiffies;
  /// the delta between ticks is the current CPU (03 §7.2).
  final int? utime, stime;

  /// `/proc/<pid>/stat` field 22: jiffies since boot at exec; the
  /// PID-reuse guard of PRC-02.
  final int? startTicks;

  /// The NUL-separated argument vector, or null when the tick marks it
  /// "command line unavailable" (03 §7.2 forged-header rule) or the
  /// source ran dry. An empty list is a real empty `cmdline`
  /// (kernel threads).
  final List<String>? argv;

  /// The whitespace-joined command line when only `ps` was available;
  /// argument boundaries are unrecoverable there (03 §7.2 masking note).
  final String? argsJoined;

  /// Total jiffies charged to the process: utime + stime.
  int? get jiffies => utime == null || stime == null ? null : utime! + stime!;

  /// Whether this row carries any command line at all.
  bool get hasCommandLine => argv != null || argsJoined != null;

  Map<String, Object?> toJson() => {
    'pid': pid,
    'ppid': ppid,
    'comm': comm,
    'state': state,
    'uid': uid,
    'rssKb': rssKb,
    'userName': userName,
    'utime': utime,
    'stime': stime,
    'startTicks': startTicks,
    'argv': argv,
    'argsJoined': argsJoined,
  };
}

/// One `procs` tick (03 §6.4).
@immutable
final class ProcsSnapshot {
  ProcsSnapshot({
    List<ProcEntry>? processes,
    this.totalProcesses,
    this.selection,
    this.argvSource = ProcsArgvSource.none,
    this.forgedHeaders = 0,
    this.skippedPids = 0,
    this.timeoutAbsent = false,
  }) : processes = List.unmodifiable(processes ?? []);

  /// Rows keyed by pid, in `/proc` glob order.
  final List<ProcEntry> processes;

  /// How many processes the host's stat pass read, of which [processes]
  /// holds the kept ones; null when the `meta` block lacked it.
  final int? totalProcesses;

  /// How the host chose the rows; null when the `meta` block lacked it.
  final ProcsSelection? selection;

  /// Whether the host left processes out (PRC-01's "showing N of M":
  /// [processes] of [totalProcesses]).
  bool get truncated =>
      selection != null && selection != ProcsSelection.all ||
      totalProcesses != null && totalProcesses! > processes.length;

  /// Where the argv data came from (03 §7.2).
  final ProcsArgvSource argvSource;

  /// `==> <pid>/cmdline <==` headers rejected by the once-each,
  /// glob-order rule (03 §7.2).
  final int forgedHeaders;

  /// Headers for pids absent from the rows, skipped per 03 §7.2. The
  /// fragment passes `head` the kept rows' paths only, so these are
  /// forged headers that kept the glob order.
  final int skippedPids;

  /// True when the payload reports the collector ran without `timeout`
  /// (03 §6.3); the cmdline read can block on a stuck process.
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'processes': processes.map((p) => p.toJson()).toList(),
    'totalProcesses': totalProcesses,
    'selection': selection?.name,
    'argvSource': argvSource.name,
    'forgedHeaders': forgedHeaders,
    'skippedPids': skippedPids,
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses a `procs` section payload; never throws (03 §6.5).
ParseResult<ProcsSnapshot> parseProcs(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.timeoutAbsent) {
    warnings.add('procs ran without a timeout guard');
  }
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }
  final blocks = split.blocks;

  final rows = <int, _Row>{};
  final order = <int>[];
  if (blocks['rows'] case final lines?) {
    for (final line in lines) {
      final row = _parseRow(line, warnings);
      if (row != null && !rows.containsKey(row.pid)) {
        rows[row.pid] = row;
        order.add(row.pid);
      }
    }
  } else {
    warnings.add('procs: missing rows block');
  }
  final meta = _parseMeta(blocks['meta'], warnings);

  // The argv source is exclusive: `cmdline` from the head|tr dump, else
  // the first working `ps` fallback (03 §7.2).
  var argvSource = ProcsArgvSource.none;
  Map<int, List<String>?> argv = const {};
  Map<int, _PsRow> psRows = const {};
  var forgedHeaders = 0;
  var skippedPids = 0;
  if (blocks['cmdline'] case final lines? when lines.isNotEmpty) {
    argvSource = ProcsArgvSource.cmdline;
    final r = _parseCmdline(lines, rows.keys.toSet(), warnings);
    argv = r.entries;
    forgedHeaders = r.forged;
    skippedPids = r.skipped;
  } else if (blocks['ps'] case final lines?) {
    argvSource = ProcsArgvSource.ps;
    psRows = _parsePs(lines, warnings, wide: false);
  } else if (blocks['ps_w'] case final lines?) {
    argvSource = ProcsArgvSource.psW;
    psRows = _parsePs(lines, warnings, wide: true);
  } else {
    warnings.add('procs: no argv source (cmdline, ps and ps_w absent)');
  }

  final entries = <ProcEntry>[];
  for (final pid in order) {
    final r = rows[pid]!;
    final ps = psRows[pid];
    entries.add(
      ProcEntry(
        pid: pid,
        ppid: r.ppid,
        comm: r.comm,
        state: r.state,
        uid: r.uid,
        rssKb: r.rssKb ?? ps?.rssKb,
        userName: ps?.user,
        utime: r.utime,
        stime: r.stime,
        startTicks: r.startTicks,
        argv: argv[pid],
        argsJoined: argv.containsKey(pid) ? null : ps?.args,
      ),
    );
  }
  // A `ps` fallback also lists processes missing from the rows, unless the
  // host left processes out on purpose: those would come back here.
  if (meta.selection == null || meta.selection == ProcsSelection.all) {
    for (final e in psRows.entries) {
      if (rows.containsKey(e.key)) continue;
      entries.add(
        ProcEntry(
          pid: e.key,
          ppid: e.value.ppid,
          state: e.value.state,
          rssKb: e.value.rssKb,
          userName: e.value.user,
          argsJoined: e.value.args,
        ),
      );
    }
  }

  return ParseResult(
    ProcsSnapshot(
      processes: entries,
      totalProcesses: meta.total,
      selection: meta.selection,
      argvSource: argvSource,
      forgedHeaders: forgedHeaders,
      skippedPids: skippedPids,
      timeoutAbsent: split.timeoutAbsent,
    ),
    warnings,
  );
}

/// One row of the `rows` block (D48): eight space-separated fields, then
/// the comm verbatim, which may hold spaces and `)`. The fields are pid,
/// state, ppid, utime, stime and starttime (fields 3, 4, 14, 15 and 22 of
/// `/proc/<pid>/stat`), then the uid and the RSS in kB, `-` when unknown.
final class _Row {
  _Row(List<String> f, List<int?> n, this.comm)
    : pid = n[0]!,
      state = f[1],
      ppid = n[2],
      utime = n[3],
      stime = n[4],
      startTicks = n[5],
      uid = n[6],
      rssKb = n[7];

  final int pid;
  final String state, comm;
  final int? ppid, utime, stime, startTicks, uid, rssKb;
}

_Row? _parseRow(String line, List<String> warnings) {
  if (line.trim().isEmpty) return null;
  final fields = <String>[];
  var rest = line;
  for (var i = 0; i < 8; i++) {
    final sp = rest.indexOf(' ');
    if (sp <= 0) {
      warnings.add('procs row: too few fields');
      return null;
    }
    fields.add(rest.substring(0, sp));
    rest = rest.substring(sp + 1);
  }
  final numbers = fields.map(int.tryParse).toList();
  if (const [0, 2, 3, 4, 5].any((i) => numbers[i] == null) ||
      const [6, 7].any((i) => numbers[i] == null && fields[i] != '-')) {
    warnings.add('procs row: malformed fields "${fields.join(' ')}"');
    return null;
  }
  return _Row(fields, numbers, rest);
}

/// The `meta` block: the `total=` count and the `selection=` wire name.
({int? total, ProcsSelection? selection}) _parseMeta(
  List<String>? lines,
  List<String> warnings,
) {
  if (lines == null) {
    warnings.add('procs: missing meta block');
    return (total: null, selection: null);
  }
  int? total;
  ProcsSelection? selection;
  for (final line in lines) {
    if (line.startsWith('total=')) {
      total = int.tryParse(line.substring(6));
    } else if (line.startsWith('selection=')) {
      final name = line.substring(10);
      selection = ProcsSelection.values
          .where((s) => s.wireName == name)
          .firstOrNull;
    }
  }
  if (total == null) warnings.add('procs: meta block lacks the total');
  if (selection == null) warnings.add('procs: meta block lacks the selection');
  return (total: total, selection: selection);
}

/// The result of the `cmdline` block pass.
final class _CmdlineResult {
  _CmdlineResult(this.entries, this.forged, this.skipped);

  /// pid to argv; a null value is the "command line unavailable" mark of
  /// 03 §7.2 (forged header named or interrupted this entry).
  final Map<int, List<String>?> entries;
  final int forged, skipped;
}

/// Splits the `head -n 1000 [0-9]*/cmdline | tr '\000' '\037'` dump into
/// per-pid argument vectors (03 §7.2).
///
/// Real `==> <pid>/cmdline <==` headers appear once each, in the
/// `LC_ALL=C` glob order of `[0-9]*/cmdline`, which is byte order on the
/// pid text. A header that repeats a pid or breaks that order is forged
/// by an argument containing newlines: it marks the pid it names and the
/// entry it interrupts "command line unavailable". Headers for pids
/// missing from the stat pass are skipped.
_CmdlineResult _parseCmdline(
  List<String> lines,
  Set<int> statPids,
  List<String> warnings,
) {
  final header = RegExp(r'^==> (\d+)/cmdline <==$');
  final entries = <int, List<String>?>{};
  final unavailable = <int>{};
  final seen = <int>{};
  var lastPidText = '';
  var forged = 0;
  var skipped = 0;
  int? current;
  final buf = <String>[];

  // A payload read from a file may carry the file's final newline as an
  // empty trailing line; the wire payload never does (the frame's byte
  // count excludes the terminator), so drop it rather than treat it as an
  // empty argument.
  final content = lines.isNotEmpty && lines.last.isEmpty
      ? lines.sublist(0, lines.length - 1)
      : lines;

  void flush() {
    final pid = current;
    if (pid == null) return;
    if (!statPids.contains(pid)) {
      skipped++;
      return;
    }
    entries[pid] = _splitArgs(buf);
  }

  for (final line in content) {
    final m = header.firstMatch(line);
    if (m != null) {
      final pidText = m[1]!;
      final pid = int.parse(pidText);
      final forgedHeader =
          seen.contains(pid) ||
          (lastPidText.isNotEmpty && pidText.compareTo(lastPidText) <= 0);
      if (forgedHeader) {
        forged++;
        unavailable.add(pid);
        if (current != null) unavailable.add(current);
        // The forged line is argument bytes of the entry it interrupts;
        // that entry is already marked, so keep accounting simple.
        if (current != null) buf.add(line);
        continue;
      }
      flush();
      seen.add(pid);
      lastPidText = pidText;
      current = pid;
      buf.clear();
      continue;
    }
    if (current == null) {
      if (line.trim().isNotEmpty) {
        warnings.add('cmdline: content before the first header');
      }
      continue;
    }
    buf.add(line);
  }
  flush();

  // An entry marked "command line unavailable" stays null even when its
  // header arrived before the forged one that condemned it (03 §7.2).
  for (final pid in unavailable) {
    if (entries.containsKey(pid)) entries[pid] = null;
  }

  if (forged > 0) {
    warnings.add('cmdline: $forged forged head header(s)');
  }
  if (skipped > 0) {
    warnings.add('cmdline: $skipped header(s) for pids outside the stat pass');
  }
  if (entries.isEmpty && forged == 0 && skipped == 0) {
    warnings.add('cmdline: block carried no headers');
  }
  return _CmdlineResult(entries, forged, skipped);
}

/// Turns one entry's content lines back into the argv list: the content
/// is the file's bytes with `\037` for each NUL, and the lines between
/// `head` headers joined by newlines reproduce them exactly.
List<String> _splitArgs(List<String> buf) {
  final content = buf.join('\n');
  if (content.isEmpty) return const [];
  final args = content.split('\x1f');
  // cmdline ends in a NUL, so a trailing \037 leaves one empty tail
  // element; interior empties are real empty arguments.
  if (args.isNotEmpty && args.last.isEmpty) {
    return args.sublist(0, args.length - 1);
  }
  return args;
}

/// A `ps` fallback row: pid plus whatever the layout carries.
final class _PsRow {
  _PsRow({
    required this.pid,
    this.ppid,
    this.user,
    this.state,
    this.rssKb,
    this.args,
  });

  final int pid;
  final int? ppid;
  final String? user, state;
  final int? rssKb;
  final String? args;
}

/// Parses `ps -eo pid,ppid,user,stat,rss,args` (`== ps ==`) or BusyBox
/// `ps w` (`== ps_w ==`). The first non-empty line is the header; rows
/// are positional and the last column swallows the rest.
Map<int, _PsRow> _parsePs(
  List<String> lines,
  List<String> warnings, {
  required bool wide,
}) {
  final out = <int, _PsRow>{};
  var seenHeader = false;
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (!seenHeader) {
      seenHeader = true;
      if (!t.toUpperCase().startsWith('PID')) {
        warnings.add('procs ps: no header row');
      }
      continue;
    }
    final parts = t.split(RegExp(r'\s+'));
    if (wide) {
      // `ps w`: PID USER TIME COMMAND
      if (parts.length < 4) {
        warnings.add('procs ps_w: short row');
        continue;
      }
      final pid = int.tryParse(parts[0]);
      if (pid == null) {
        warnings.add('procs ps_w: malformed row');
        continue;
      }
      // `ps w`: PID USER TIME COMMAND, so the command starts at column 4.
      out[pid] = _PsRow(
        pid: pid,
        user: parts[1],
        args: parts.sublist(3).join(' '),
      );
      continue;
    }
    // `ps -eo pid,ppid,user,stat,rss,args`
    if (parts.length < 5) {
      warnings.add('procs ps: short row');
      continue;
    }
    final pid = int.tryParse(parts[0]);
    final ppid = int.tryParse(parts[1]);
    final rss = int.tryParse(parts[4]);
    if (pid == null || ppid == null || rss == null) {
      warnings.add('procs ps: malformed row');
      continue;
    }
    out[pid] = _PsRow(
      pid: pid,
      ppid: ppid,
      user: parts[2],
      state: parts[3],
      rssKb: rss,
      args: parts.length > 5 ? parts.sublist(5).join(' ') : '',
    );
  }
  if (!seenHeader) warnings.add('procs ps: empty block');
  return out;
}
