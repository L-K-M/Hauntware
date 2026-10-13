/// Parser for the `procs` slow-collector payload (03 §6.4, §7.2):
/// `/proc/<pid>/stat` and `status` rows read with builtins, the
/// `head|tr` `cmdline` dump with its forged-header rules, and the
/// `ps -eo`/`ps w` fallback blocks.
library;

import 'package:meta/meta.dart';

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// Which argv source a `procs` payload used (03 §7.2): the `head|tr`
/// `/proc/<pid>/cmdline` dump, `ps -eo`, BusyBox `ps w`, or none.
enum ProcsArgvSource { cmdline, ps, psW, none }

/// One process row of a `procs` tick (03 §7.2).
@immutable
final class ProcEntry {
  ProcEntry({
    required this.pid,
    this.ppid,
    this.comm,
    this.state,
    this.uid,
    this.gid,
    this.name,
    this.threads,
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
  /// last `)`; may itself contain spaces and `)`.
  final String? comm;

  /// `/proc/<pid>/stat` field 3 (one-letter run state).
  final String? state;

  /// Real and effective uid from `status` `Uid:`.
  final int? uid, gid;

  /// `status` `Name:`; the fallback label when the command line is
  /// absent (kernel threads have an empty `cmdline`).
  final String? name;

  /// `status` `Threads:`.
  final int? threads;

  /// `status` `VmRSS:` in kB.
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
    'gid': gid,
    'name': name,
    'threads': threads,
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
    this.argvSource = ProcsArgvSource.none,
    this.forgedHeaders = 0,
    this.skippedPids = 0,
    this.timeoutAbsent = false,
  }) : processes = List.unmodifiable(processes ?? []);

  /// Rows keyed by pid, in `/proc` glob order.
  final List<ProcEntry> processes;

  /// Where the argv data came from (03 §7.2).
  final ProcsArgvSource argvSource;

  /// `==> <pid>/cmdline <==` headers rejected by the once-each,
  /// glob-order rule (03 §7.2).
  final int forgedHeaders;

  /// Headers for pids absent from the stat pass: new processes and the
  /// collector's own pipeline, skipped per 03 §7.2.
  final int skippedPids;

  /// True when the payload reports the collector ran without `timeout`
  /// (03 §6.3); the cmdline read can block on a stuck process.
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'processes': processes.map((p) => p.toJson()).toList(),
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

  final statRows = <int, _StatRow>{};
  final order = <int>[];
  if (blocks['stat'] case final lines?) {
    for (final line in lines) {
      final row = _parseStatLine(line, warnings);
      if (row != null && !statRows.containsKey(row.pid)) {
        statRows[row.pid] = row;
        order.add(row.pid);
      }
    }
  } else {
    warnings.add('procs: missing stat block');
  }

  final statusRows = <int, _StatusRow>{};
  if (blocks['status'] case final lines?) {
    for (final line in lines) {
      final row = _parseStatusLine(line, warnings);
      if (row != null) statusRows[row.pid] = row.merge(statusRows[row.pid]);
    }
  } else {
    warnings.add('procs: missing status block');
  }

  // The argv source is exclusive: `cmdline` from the head|tr dump, else
  // the first working `ps` fallback (03 §7.2).
  var argvSource = ProcsArgvSource.none;
  Map<int, List<String>?> argv = const {};
  Map<int, _PsRow> psRows = const {};
  var forgedHeaders = 0;
  var skippedPids = 0;
  if (blocks['cmdline'] case final lines? when lines.isNotEmpty) {
    argvSource = ProcsArgvSource.cmdline;
    final r = _parseCmdline(lines, statRows.keys.toSet(), warnings);
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

  final rows = <ProcEntry>[];
  for (final pid in order) {
    final s = statRows[pid]!;
    final st = statusRows[pid];
    final ps = psRows[pid];
    rows.add(
      ProcEntry(
        pid: pid,
        ppid: s.ppid,
        comm: s.comm,
        state: s.state ?? ps?.state,
        uid: st?.uid,
        gid: st?.gid,
        name: st?.name,
        threads: st?.threads ?? s.threads,
        rssKb: st?.rssKb ?? ps?.rssKb,
        userName: ps?.user,
        utime: s.utime,
        stime: s.stime,
        startTicks: s.startTicks,
        argv: argv[pid],
        argsJoined: argv.containsKey(pid) ? null : ps?.args,
      ),
    );
  }
  // A `ps` fallback also lists processes missing from the stat pass.
  for (final e in psRows.entries) {
    if (statRows.containsKey(e.key)) continue;
    rows.add(
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

  return ParseResult(
    ProcsSnapshot(
      processes: rows,
      argvSource: argvSource,
      forgedHeaders: forgedHeaders,
      skippedPids: skippedPids,
      timeoutAbsent: split.timeoutAbsent,
    ),
    warnings,
  );
}

/// The `== stat ==` row: `<pid> <pid> (<comm>) <field3> <field4> ...`
/// where `comm` is text between parens that may hold `)` itself.
/// Fields after the last `)` count from 3 (03 §7.2), so comm survives
/// embedded spaces and parentheses.
final class _StatRow {
  _StatRow({required this.pid, required this.comm, required this.fields});

  final int pid;
  final String? comm;

  /// Field k of the stat line sits at `fields[k - 3]`; field 3 is the
  /// one-letter state and the rest are numeric where needed.
  final List<String> fields;

  String? get state => fields.isNotEmpty ? fields[0] : null;
  int? get ppid => _at(1);
  int? get utime => _at(11);
  int? get stime => _at(12);
  int? get threads => _at(17);
  int? get startTicks => _at(19);
  int? _at(int i) => i < fields.length ? int.tryParse(fields[i]) : null;
}

_StatRow? _parseStatLine(String line, List<String> warnings) {
  final t = line.trim();
  if (t.isEmpty) return null;
  final sp = t.indexOf(' ');
  if (sp < 0) {
    warnings.add('procs stat: short line');
    return null;
  }
  final pathPid = int.tryParse(t.substring(0, sp));
  final stat = t.substring(sp + 1).trim();
  // The raw line is `<pid> (<comm>) <fields>`; comm ends at the LAST
  // `)` because the kernel quotes nothing inside it (03 §7.2).
  final open = stat.indexOf('(');
  final close = stat.lastIndexOf(')');
  if (pathPid == null || open < 0 || close < open) {
    warnings.add('procs stat: malformed line');
    return null;
  }
  final comm = stat.substring(open + 1, close);
  final fields = stat.substring(close + 1).trim().split(RegExp(r'\s+'));
  if (fields.length < 20 || fields.any((f) => f.isEmpty)) {
    warnings.add('procs stat: short field list for pid $pathPid');
    return null;
  }
  return _StatRow(pid: pathPid, comm: comm, fields: fields);
}

/// A `status` row keeps the fields the list needs (03 §7.2): Name, the
/// Uid/Gid real ids, VmRSS and Threads.
final class _StatusRow {
  _StatusRow({required this.pid});

  final int pid;
  String? name;
  int? uid, gid, rssKb, threads;

  /// Accumulates the fields of an earlier row for the same pid.
  _StatusRow merge(_StatusRow? prev) {
    if (prev == null) return this;
    name ??= prev.name;
    uid ??= prev.uid;
    gid ??= prev.gid;
    rssKb ??= prev.rssKb;
    threads ??= prev.threads;
    return this;
  }
}

/// One `<pid> <Key>: <value>` row of the `status` block.
_StatusRow? _parseStatusLine(String line, List<String> warnings) {
  final t = line.trimRight();
  if (t.trim().isEmpty) return null;
  final sp = t.indexOf(' ');
  if (sp < 0) {
    warnings.add('procs status: short line');
    return null;
  }
  final pid = int.tryParse(t.substring(0, sp));
  if (pid == null) {
    warnings.add('procs status: bad pid prefix');
    return null;
  }
  final rest = t.substring(sp + 1);
  final colon = rest.indexOf(':');
  if (colon <= 0) {
    warnings.add('procs status: malformed line for pid $pid');
    return null;
  }
  final key = rest.substring(0, colon);
  final value = rest.substring(colon + 1).trim();
  final row = _StatusRow(pid: pid);
  final firstInt = RegExp(r'^-?\d+').firstMatch(value)?.group(0);
  switch (key) {
    case 'Name':
      row.name = value.isEmpty ? null : value;
    case 'Uid':
      row.uid = int.tryParse(firstInt ?? '');
    case 'Gid':
      row.gid = int.tryParse(firstInt ?? '');
    case 'VmRSS':
      row.rssKb = int.tryParse(firstInt ?? '');
    case 'Threads':
      row.threads = int.tryParse(firstInt ?? '');
    default:
      // Forward-compatible: the fragment filters, but extra keys parse.
      return null;
  }
  return row;
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
