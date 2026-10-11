import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'engine_session.dart';
import 'pane_permissions.dart' show nameIsFlagged;
import 'pane_rename.dart';

/// Rename Items (02 §2.6): the pure half of the batch rename. Rules turn
/// each selected name into a new one, the planner checks the whole set
/// against the folders it lives in, and the executor sends the plan's
/// renames one at a time. The pane controller owns the session around
/// them; nothing here touches a listing or a widget.

/// The dialog's mode picker.
enum BatchRenameMode { replaceText, addText, format }

/// Where Add Text and Format put their text relative to the name.
enum BatchRenamePlacement { beforeName, afterName }

/// One rename rule, applied to every selected name.
sealed class BatchRenameRule {
  const BatchRenameRule();
}

/// Replaces every literal occurrence of [find] with [replacement].
final class ReplaceTextRule extends BatchRenameRule {
  const ReplaceTextRule({
    required this.find,
    required this.replacement,
    this.matchCase = true,
    this.includeExtension = false,
  });

  final String find;
  final String replacement;

  /// Remote servers are case-sensitive, so matching is too by default.
  final bool matchCase;

  /// Off by default: a file's extension cannot change by accident.
  final bool includeExtension;
}

/// Adds [text] before the name or after it (before a file's extension).
final class AddTextRule extends BatchRenameRule {
  const AddTextRule({required this.text, required this.placement});

  final String text;
  final BatchRenamePlacement placement;
}

/// Numbers the selection: [name] (or each item's own name when empty)
/// joined by one space to a number counted from [startAt].
final class FormatRule extends BatchRenameRule {
  const FormatRule({
    required this.name,
    required this.placement,
    required this.startAt,
  }) : assert(startAt >= 0 && startAt <= batchRenameMaxStartAt);

  final String name;
  final BatchRenamePlacement placement;
  final int startAt;
}

/// The largest "Start numbers at" value the dialog accepts.
const int batchRenameMaxStartAt = 999999;

/// Splits a name into the part rules edit and the extension they keep:
/// the last dot starts the extension, a leading dot does not count, and
/// a folder never splits. The same rule numbers Keep Both copies
/// (`numberedConflictName`), so `archive.tar.gz` keeps `.gz` and
/// `.bashrc` has no extension.
({String stem, String extension}) splitRenameExtension(
  String name, {
  required bool isDirectory,
}) {
  if (isDirectory) return (stem: name, extension: '');
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return (stem: name, extension: '');
  return (stem: name.substring(0, dot), extension: name.substring(dot));
}

/// Applies [rule] to one [name]. [number] and [numberWidth] matter only
/// to Format. Nothing is trimmed: the result keeps exactly what the user
/// typed, as inline rename does. [stemEmptied] reports a Replace that
/// left a file with nothing before its extension (`report.txt` would
/// otherwise become the hidden `.txt`).
({String name, bool stemEmptied}) applyBatchRenameRule(
  BatchRenameRule rule,
  String name, {
  required bool isDirectory,
  int number = 0,
  int numberWidth = 1,
}) {
  final (:stem, :extension) = splitRenameExtension(
    name,
    isDirectory: isDirectory,
  );
  switch (rule) {
    case ReplaceTextRule(:final find, :final replacement):
      if (find.isEmpty) return (name: name, stemEmptied: false);
      final pattern = RegExp(
        RegExp.escape(find),
        caseSensitive: rule.matchCase,
        unicode: true,
      );
      // replaceAllMapped keeps the replacement literal: no `$1` expansion.
      String replace(String source) =>
          source.replaceAllMapped(pattern, (_) => replacement);
      if (rule.includeExtension || extension.isEmpty) {
        return (name: replace(name), stemEmptied: false);
      }
      final newStem = replace(stem);
      return (name: '$newStem$extension', stemEmptied: newStem.trim().isEmpty);
    case AddTextRule(:final text, :final placement):
      if (text.isEmpty) return (name: name, stemEmptied: false);
      return (
        name: switch (placement) {
          BatchRenamePlacement.beforeName => '$text$name',
          BatchRenamePlacement.afterName => '$stem$text$extension',
        },
        stemEmptied: false,
      );
    case FormatRule(name: final base, :final placement):
      final digits = '$number'.padLeft(numberWidth, '0');
      final label = base.isEmpty ? stem : base;
      return (
        name: switch (placement) {
          BatchRenamePlacement.beforeName => '$digits $label$extension',
          BatchRenamePlacement.afterName => '$label $digits$extension',
        },
        stemEmptied: false,
      );
  }
}

/// The digits Format pads every number to: wide enough for the largest
/// number in the batch, so the new names sort in order.
int batchRenameNumberWidth({required int startAt, required int count}) {
  final last = count <= 0 ? startAt : startAt + count - 1;
  final first = '$startAt'.length;
  final widest = '$last'.length;
  return first > widest ? first : widest;
}

/// One selected item, as the planner sees it.
final class BatchRenameTarget {
  const BatchRenameTarget({
    required this.path,
    required this.name,
    required this.folder,
    required this.parentPrefix,
    required this.isDirectory,
    required this.ordinal,
    required this.present,
  });

  final String path;
  final String name;

  /// The directory whose listing holds this item.
  final String folder;

  /// [path] without its name; the new path is this plus the new name.
  final String parentPrefix;
  final bool isDirectory;

  /// The item's position in Format's numbering, fixed when the dialog
  /// opened; -1 for an item left out.
  final int ordinal;

  /// Whether the folder's current listing still holds this item.
  final bool present;
}

/// An entry of an affected folder: a selected item or any other name
/// that a new name must not reuse.
typedef BatchRenameFolderEntry = ({String path, String name});

/// Everything the planner checks one rule against: the selected items
/// in listing order and every entry of the folders they live in,
/// hidden and filtered-out names included.
final class BatchRenameSnapshot {
  BatchRenameSnapshot({
    required List<BatchRenameTarget> targets,
    required Map<String, List<BatchRenameFolderEntry>> folderEntries,
    required this.remote,
    required this.platform,
  }) : targets = List.unmodifiable(targets),
       _folderKeys = {
         for (final MapEntry(key: folder, value: entries)
             in folderEntries.entries)
           folder: _keyed(entries),
       };

  final List<BatchRenameTarget> targets;

  /// A remote pane checks names by the POSIX rules only.
  final bool remote;

  /// Decides which local name rules apply (Windows adds the NTFS set).
  final TargetPlatform platform;

  /// Folder -> name key -> entries with that key, built once so a
  /// keystroke only keys the new names.
  final Map<String, Map<String, List<BatchRenameFolderEntry>>> _folderKeys;

  /// How many items Format numbers.
  int get numberedCount =>
      targets.where((target) => target.ordinal >= 0).length;

  static Map<String, List<BatchRenameFolderEntry>> _keyed(
    List<BatchRenameFolderEntry> entries,
  ) {
    final keyed = <String, List<BatchRenameFolderEntry>>{};
    for (final entry in entries) {
      keyed.putIfAbsent(batchRenameNameKey(entry.name), () => []).add(entry);
    }
    return keyed;
  }
}

/// Two names that differ only by case or Unicode normalization count as
/// the same name everywhere. That is the transfer queue's unprobed
/// default: the pane cannot tell whether a volume or server folds case,
/// so it assumes it might.
String batchRenameNameKey(String name) => destinationNameKey(
  name,
  DestinationNameComparison.normalizedCaseInsensitive,
);

/// What the plan does with one selected item. [isBlocking] statuses stop
/// the whole batch until the user changes the rule.
enum BatchRenameStatus {
  rename,
  unchanged,

  /// The name is not valid UTF-8 (02 §13): never sent, never numbered.
  leftOut,
  gone,
  invalidName,
  becomesHidden,
  duplicate,
  exists,
  cycle;

  bool get isBlocking => switch (this) {
    rename || unchanged || leftOut => false,
    gone ||
    invalidName ||
    becomesHidden ||
    duplicate ||
    exists ||
    cycle => true,
  };
}

/// One preview row.
final class BatchRenameRow {
  const BatchRenameRow({
    required this.target,
    required this.newName,
    required this.status,
    this.nameError,
    this.conflictName,
    this.dependsOn,
  });

  final BatchRenameTarget target;
  final String newName;
  final BatchRenameStatus status;

  /// Why [BatchRenameStatus.invalidName] refused the new name.
  final RenameNameError? nameError;

  /// The existing name a [BatchRenameStatus.exists] row would reuse.
  final String? conflictName;

  /// The row that must rename first because this row takes its old name.
  final int? dependsOn;

  String get newPath => '${target.parentPrefix}$newName';
}

/// The previewed outcome of one rule over the snapshot.
final class BatchRenamePlan {
  BatchRenamePlan._(List<BatchRenameRow> rows, List<int> steps)
    : rows = List.unmodifiable(rows),
      steps = List.unmodifiable(steps),
      renameCount = _count(rows, BatchRenameStatus.rename),
      unchangedCount = _count(rows, BatchRenameStatus.unchanged),
      leftOutCount = _count(rows, BatchRenameStatus.leftOut),
      blockedCount = rows.where((row) => row.status.isBlocking).length;

  /// Listing order, as the preview shows them.
  final List<BatchRenameRow> rows;

  /// Row indexes in the order they rename: a row that takes another
  /// row's old name runs after it. Empty while the plan is blocked.
  final List<int> steps;

  final int renameCount;
  final int unchangedCount;
  final int leftOutCount;
  final int blockedCount;

  bool get runnable => blockedCount == 0 && renameCount > 0;

  /// The first row the user has to fix, for the summary's jump.
  int? get firstBlockedRow {
    final index = rows.indexWhere((row) => row.status.isBlocking);
    return index < 0 ? null : index;
  }

  static int _count(List<BatchRenameRow> rows, BatchRenameStatus status) =>
      rows.where((row) => row.status == status).length;
}

/// Plans [rule] over [snapshot]. Pure and deterministic: lookups are
/// keyed, never ordered by a map.
///
/// Each item is first checked alone (left out, gone, unchanged, an
/// invalid new name, a name that would become hidden). The rest move,
/// and are checked per folder: two moving items may not share a new
/// name, and a new name may not reuse any name that stays (other
/// entries, hidden ones and blocked or unchanged selected items). A new
/// name that is another moving item's old name is a chain: it runs after
/// that item. Chains that loop (a swap) are refused, because renaming
/// either first would collide.
BatchRenamePlan planBatchRename(
  BatchRenameSnapshot snapshot,
  BatchRenameRule rule,
) {
  final targets = snapshot.targets;
  final numberWidth = rule is FormatRule
      ? batchRenameNumberWidth(
          startAt: rule.startAt,
          count: snapshot.numberedCount,
        )
      : 1;

  final rows = <BatchRenameRow>[];
  final moving = <int>[];
  for (var index = 0; index < targets.length; index++) {
    final target = targets[index];
    final row = _checkAlone(snapshot, rule, target, numberWidth);
    rows.add(row);
    if (row.status == BatchRenameStatus.rename) moving.add(index);
  }

  _checkFolders(snapshot, rows, moving);
  _refuseCycles(rows);

  final blocked = rows.any((row) => row.status.isBlocking);
  return BatchRenamePlan._(rows, blocked ? const [] : _steps(rows));
}

BatchRenameRow _checkAlone(
  BatchRenameSnapshot snapshot,
  BatchRenameRule rule,
  BatchRenameTarget target,
  int numberWidth,
) {
  BatchRenameRow row(
    String newName,
    BatchRenameStatus status, {
    RenameNameError? nameError,
  }) => BatchRenameRow(
    target: target,
    newName: newName,
    status: status,
    nameError: nameError,
  );

  if (nameIsFlagged(target.name)) {
    return row(target.name, BatchRenameStatus.leftOut);
  }

  final startAt = rule is FormatRule ? rule.startAt : 0;
  final (name: newName, :stemEmptied) = applyBatchRenameRule(
    rule,
    target.name,
    isDirectory: target.isDirectory,
    number: startAt + target.ordinal,
    numberWidth: numberWidth,
  );

  if (!target.present) return row(newName, BatchRenameStatus.gone);
  if (newName == target.name) return row(newName, BatchRenameStatus.unchanged);

  final nameError = stemEmptied
      ? RenameNameError.empty
      : renameNameError(
              newName,
              remote: snapshot.remote,
              platform: snapshot.platform,
            ) ??
            // renameNameError lets these through; inline rename only fails
            // safe on them, and a typed U+FFFD must never reach the wire.
            (newName == '.' || newName == '..' || nameIsFlagged(newName)
                ? RenameNameError.invalid
                : null);
  if (nameError != null) {
    return row(newName, BatchRenameStatus.invalidName, nameError: nameError);
  }

  if (!target.name.startsWith('.') && newName.startsWith('.')) {
    return row(newName, BatchRenameStatus.becomesHidden);
  }
  return row(newName, BatchRenameStatus.rename);
}

void _checkFolders(
  BatchRenameSnapshot snapshot,
  List<BatchRenameRow> rows,
  List<int> moving,
) {
  final movingPaths = {for (final index in moving) rows[index].target.path};

  // Folder -> new-name key -> moving rows, and the same for old names.
  final newKeys = <String, Map<String, List<int>>>{};
  final oldKeys = <String, Map<String, List<int>>>{};
  for (final index in moving) {
    final target = rows[index].target;
    newKeys
        .putIfAbsent(target.folder, () => {})
        .putIfAbsent(batchRenameNameKey(rows[index].newName), () => [])
        .add(index);
    oldKeys
        .putIfAbsent(target.folder, () => {})
        .putIfAbsent(batchRenameNameKey(target.name), () => [])
        .add(index);
  }

  for (final index in moving) {
    final row = rows[index];
    final folder = row.target.folder;
    final key = batchRenameNameKey(row.newName);

    if (newKeys[folder]![key]!.length > 1) {
      rows[index] = _withStatus(row, BatchRenameStatus.duplicate);
      continue;
    }

    final staying = (snapshot._folderKeys[folder]?[key] ?? const [])
        .where(
          (entry) =>
              entry.path != row.target.path &&
              !movingPaths.contains(entry.path),
        )
        .toList();
    if (staying.isNotEmpty) {
      rows[index] = _withStatus(
        row,
        BatchRenameStatus.exists,
        conflictName: staying.first.name,
      );
      continue;
    }

    final blockers = (oldKeys[folder]![key] ?? const <int>[])
        .where((other) => other != index)
        .toList();
    if (blockers.length > 1) {
      // Two moving names fold to this one (`a` and `A` on a
      // case-sensitive volume). Renaming after both would be safe, but
      // a row waits on one other row, so it is refused instead.
      rows[index] = _withStatus(
        row,
        BatchRenameStatus.exists,
        conflictName: rows[blockers.first].target.name,
      );
    } else if (blockers.length == 1) {
      rows[index] = _withStatus(
        row,
        BatchRenameStatus.rename,
        dependsOn: blockers.single,
      );
    }
  }
}

/// Marks every row on a dependency loop. Each row depends on at most one
/// other, so walking the edges from each row finds every loop; a row
/// already walked is never walked again.
void _refuseCycles(List<BatchRenameRow> rows) {
  final settled = <int>{};
  final onCycle = <int>{};
  for (var start = 0; start < rows.length; start++) {
    final path = <int>[];
    final position = <int, int>{};
    int? current = start;
    while (current != null && !settled.contains(current)) {
      final seenAt = position[current];
      if (seenAt != null) {
        onCycle.addAll(path.sublist(seenAt));
        break;
      }
      position[current] = path.length;
      path.add(current);
      final row = rows[current];
      current = row.status == BatchRenameStatus.rename ? row.dependsOn : null;
    }
    settled.addAll(path);
  }
  for (final index in onCycle) {
    rows[index] = _withStatus(
      rows[index],
      BatchRenameStatus.cycle,
      dependsOn: rows[index].dependsOn,
    );
  }
}

/// Rename rows ordered so each runs after the row whose name it takes:
/// by chain depth, then listing order. Only called on a plan without
/// cycles, so every chain ends.
List<int> _steps(List<BatchRenameRow> rows) {
  final depth = <int, int>{};
  int depthOf(int index) {
    final chain = <int>[];
    int? current = index;
    while (current != null && !depth.containsKey(current)) {
      chain.add(current);
      current = rows[current].dependsOn;
    }
    var value = current == null ? -1 : depth[current]!;
    for (final link in chain.reversed) {
      depth[link] = ++value;
    }
    return depth[index]!;
  }

  final renames = [
    for (var index = 0; index < rows.length; index++)
      if (rows[index].status == BatchRenameStatus.rename) index,
  ];
  renames.sort((a, b) {
    final byDepth = depthOf(a).compareTo(depthOf(b));
    return byDepth != 0 ? byDepth : a.compareTo(b);
  });
  return renames;
}

BatchRenameRow _withStatus(
  BatchRenameRow row,
  BatchRenameStatus status, {
  String? conflictName,
  int? dependsOn,
}) => BatchRenameRow(
  target: row.target,
  newName: row.newName,
  status: status,
  nameError: row.nameError,
  conflictName: conflictName,
  dependsOn: dependsOn,
);

/// Why a run ended.
enum BatchRenameStop { completed, stopped, paneChanged, connectionLost, fault }

/// What happened to one rename row during a run. A row without an
/// outcome after the run ended was not attempted.
sealed class BatchRenameOutcome {
  const BatchRenameOutcome();
}

final class BatchRenameRenamed extends BatchRenameOutcome {
  const BatchRenameRenamed();
}

/// The filesystem refused this item; the run went on.
final class BatchRenameFailed extends BatchRenameOutcome {
  const BatchRenameFailed(this.error);

  final RemoteFileException error;
}

/// Not sent: the row whose name it takes could not be renamed first.
final class BatchRenameSkippedBlocked extends BatchRenameOutcome {
  const BatchRenameSkippedBlocked(this.blocker);

  /// The row index that did not rename.
  final int blocker;
}

/// The request may or may not have applied (a lost connection, a
/// timeout or an unexpected error); the run stopped here.
final class BatchRenameUnknown extends BatchRenameOutcome {
  const BatchRenameUnknown(this.error);

  final Object error;
}

/// Sends [plan]'s renames over [channel], strictly one at a time and in
/// [BatchRenamePlan.steps] order. [checkpoint] runs before every step;
/// a non-null answer ends the run there. A typed refusal is recorded and
/// the run continues, as Apply to enclosed items does: one locked file
/// must not void the rest. A lost connection, a timeout (reported as
/// `disconnected`) or a cancelled request leaves the outcome unknown and
/// ends the run, and so does an unexpected error, which goes to
/// [onFault] for reporting.
Future<BatchRenameStop> executeBatchRename(
  AppBrowseChannel channel,
  BatchRenamePlan plan, {
  required BatchRenameStop? Function() checkpoint,
  required void Function(int row) onStart,
  required void Function(int row, BatchRenameOutcome outcome) onOutcome,
  void Function(Object error, StackTrace stackTrace)? onFault,
}) async {
  final renamed = <int>{};
  for (final index in plan.steps) {
    final stop = checkpoint();
    if (stop != null) return stop;

    final row = plan.rows[index];
    final dependsOn = row.dependsOn;
    if (dependsOn != null && !renamed.contains(dependsOn)) {
      onOutcome(index, BatchRenameSkippedBlocked(dependsOn));
      continue;
    }

    onStart(index);
    try {
      await channel.rename(row.target.path, row.newPath);
    } on RemoteFileException catch (error) {
      switch (error.kind) {
        case RemoteFileErrorKind.disconnected:
        case RemoteFileErrorKind.cancelled:
          onOutcome(index, BatchRenameUnknown(error));
          return BatchRenameStop.connectionLost;
        case RemoteFileErrorKind.notFound:
        case RemoteFileErrorKind.permissionDenied:
        case RemoteFileErrorKind.unsupported:
        case RemoteFileErrorKind.conflict:
        case RemoteFileErrorKind.other:
          onOutcome(index, BatchRenameFailed(error));
          continue;
      }
    } on Object catch (error, stackTrace) {
      onOutcome(index, BatchRenameUnknown(error));
      onFault?.call(error, stackTrace);
      return BatchRenameStop.fault;
    }
    renamed.add(index);
    onOutcome(index, const BatchRenameRenamed());
  }
  return BatchRenameStop.completed;
}
