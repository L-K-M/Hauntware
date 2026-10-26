import 'package:klabautermann_core/klabautermann_core.dart'
    show HostProfile, MaskedValue, ProcessRow, ProcsResult, ProcsSelection;

/// The Processes tab's columns, whose names key them in the table and
/// its sort (PRC-01).
enum ProcessColumn { command, pid, user, cpu, memory, started }

/// Up to how many UTF-16 code units of a command line, or of one argument,
/// the tab draws and its filter reads. A command line can fill the 1 MiB
/// `procs` section, which neither text layout nor a keystroke in the
/// filter should pay for on every row.
const int kProcessTextLimit = 4096;

/// [text] up to [kProcessTextLimit], a cut ending in an ellipsis.
String clipProcessText(String text) {
  if (text.length <= kProcessTextLimit) return text;

  var end = kProcessTextLimit;
  // A surrogate pair stays whole.
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return '${text.substring(0, end)}…';
}

/// [argument] as shown: its display text, with [maskWord] in place of the
/// mask when given, since a screen reader would read eight asterisks.
String argumentText(MaskedValue argument, {String? maskWord}) {
  if (maskWord == null || !argument.isMasked) return argument.display;
  return argument.display.replaceAll(MaskedValue.maskToken, maskWord);
}

/// [row]'s command line as the tab shows it: its arguments' display text
/// joined by spaces, so a masked one shows its mask and never its secret
/// (03 §8.9). Null where the host gave none: unreadable (7.2's "command
/// line unavailable") or empty, as for a kernel thread.
String? commandLineText(ProcessRow row, {String? maskWord}) {
  final arguments = row.arguments;
  if (arguments == null || arguments.isEmpty) return null;

  final line = StringBuffer();
  for (final argument in arguments) {
    if (line.isNotEmpty) line.write(' ');
    line.write(argumentText(argument, maskWord: maskWord));
    if (line.length > kProcessTextLimit) break;
  }
  return clipProcessText(line.toString());
}

/// Who runs [row] by name: the name a `ps` fallback gave, or the probe's
/// login user (`id -un`) for that user's uid. Null otherwise, leaving the
/// uid: the host sends no user table, and a name is never guessed. GNU
/// `ps` cuts a name wider than its 8-column field to 7 characters and a
/// `+`, which is not the name. GNU and BusyBox `ps` print the uid where
/// no passwd entry names it, which is not a name either.
String? processUserName(ProcessRow row, HostProfile? profile) {
  if (row.userName case final name?
      when !(name.length == 8 && name.endsWith('+')) &&
          name != row.uid?.toString()) {
    return name;
  }

  final uid = row.uid;
  if (uid == null || uid != profile?.uid) return null;
  return profile?.user;
}

/// The user column's sort key: named users by name, then those known only
/// by uid in number order; null, sorting last, when neither is known.
Comparable<Object>? processUserSortKey(ProcessRow row, HostProfile? profile) {
  final name = processUserName(row, profile);
  final uid = row.uid;
  if (name == null && uid == null) return null;
  return _UserKey(name, uid);
}

final class _UserKey implements Comparable<_UserKey> {
  const _UserKey(this.name, this.uid);

  final String? name;
  final int? uid;

  @override
  int compareTo(_UserKey other) => switch ((name, other.name)) {
    (final mine?, final theirs?) => mine.compareTo(theirs),
    (_?, null) => -1,
    (null, _?) => 1,
    (null, null) => uid!.compareTo(other.uid!),
  };
}

/// The rows whose PID, name, user or shown command line hold every
/// whitespace-separated term of [query], ignoring case; every row for a
/// blank query. The user is [userText], as its column shows it, or the
/// uid. It reads shown text only, so a masked secret never decides a
/// match (03 §8.9).
List<ProcessRow> filterProcesses(
  List<ProcessRow> rows,
  String query,
  String Function(ProcessRow row) userText,
) {
  final terms = query.toLowerCase().split(_whitespace)
    ..removeWhere((term) => term.isEmpty);
  if (terms.isEmpty) return rows;

  return [
    for (final row in rows)
      if (_haystack(row, userText) case final haystack
          when terms.every(haystack.contains))
        row,
  ];
}

final _whitespace = RegExp(r'\s+');

String _haystack(ProcessRow row, String Function(ProcessRow) userText) => [
  row.pid,
  ?row.name,
  userText(row),
  ?row.uid,
  ?commandLineText(row),
].join('\n').toLowerCase();

/// How many processes [result] lists, and of how many the host counted
/// when it said, if the host left some out (D48: PRC-01's "showing N of
/// M"); null when it lists them all.
({int shown, int? total})? processesLeftOut(ProcsResult result) {
  final shown = result.processes.length;
  final total = result.totalProcesses;
  final counted = total != null && total > shown ? total : null;
  final selection = result.selection;
  final selected = selection != null && selection != ProcsSelection.all;
  if (!selected && counted == null) return null;
  return (shown: shown, total: counted);
}

/// A run state PRC-06 flags in the Processes tab.
enum ProcessFlag {
  /// `Z`: exited, its parent has not collected it.
  zombie,

  /// `D`: waiting on I/O it cannot be interrupted from, which no signal
  /// ends; many at once point at a stuck disk or network mount.
  uninterruptible,
}

/// The flag [row]'s run state raises, or null.
ProcessFlag? processFlag(ProcessRow row) => switch (row.state) {
  'Z' => ProcessFlag.zombie,
  'D' => ProcessFlag.uninterruptible,
  _ => null,
};

/// How many of [rows] each flag marks, in [ProcessFlag]'s order; the
/// flags no row raises are absent.
Map<ProcessFlag, int> processFlagCounts(List<ProcessRow> rows) {
  final counts = <ProcessFlag, int>{};
  for (final row in rows) {
    if (processFlag(row) case final flag?) {
      counts[flag] = (counts[flag] ?? 0) + 1;
    }
  }
  return {for (final flag in ProcessFlag.values) flag: ?counts[flag]};
}

/// The deepest a tree indents a row; deeper ones line up at it.
const int kProcessTreeDepthShown = 12;

/// One row of PRC-03's tree: [depth] parents above it among the rows.
typedef ProcessTreeRow = ({ProcessRow row, int depth});

/// [rows], already in the order siblings should keep, as a tree: each row
/// followed by its children, depth first. A row whose parent is not among
/// them (PID 1, a kernel thread's `kthreadd`, a row the host left out) is
/// a root. Each row appears once, even where reused PIDs make a cycle.
List<ProcessTreeRow> processTree(List<ProcessRow> rows) {
  final pids = {for (final row in rows) row.pid};
  final children = <int, List<ProcessRow>>{};
  final roots = <ProcessRow>[];
  for (final row in rows) {
    final parent = row.parentPid;
    if (parent != null && parent != row.pid && pids.contains(parent)) {
      (children[parent] ??= []).add(row);
    } else {
      roots.add(row);
    }
  }

  final out = <ProcessTreeRow>[];
  final placed = <int>{};
  void visit(ProcessRow row, int depth) {
    if (!placed.add(row.pid)) return;
    out.add((row: row, depth: depth));
    for (final child in children[row.pid] ?? const <ProcessRow>[]) {
      visit(child, depth + 1);
    }
  }

  for (final root in roots) {
    visit(root, 0);
  }
  // Rows only a cycle reaches have no root; they follow as roots.
  for (final row in rows) {
    visit(row, 0);
  }
  return out;
}

/// [shown] with each one's ancestors among [all], in [all]'s order, so a
/// filtered tree keeps the path to each match.
List<ProcessRow> withAncestors(List<ProcessRow> shown, List<ProcessRow> all) {
  final byPid = {for (final row in all) row.pid: row};
  final keep = <int>{};
  for (final row in shown) {
    var current = row;
    while (keep.add(current.pid)) {
      final parent = byPid[current.parentPid];
      if (parent == null) break;
      current = parent;
    }
  }
  return [
    for (final row in all)
      if (keep.contains(row.pid)) row,
  ];
}
