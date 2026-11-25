// SAF-14's backup removal (03 §8.11; M5 plan M16, Q11): "keep last N"
// keeps the newest backups of each file and removes the rest; removing
// every backup of one file needs the typed confirmation, since they are
// its edits' only undo. Each plan names every file it deletes and
// rewrites the index without their lines, only while the index still
// hashes to what planning read.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart'
    show
        BackupEntry,
        EditCommands,
        EditExit,
        HostCommandError,
        HostCommands,
        encodeBackupIndex,
        kRootBackupsDir,
        parseBackupIndex;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult, quoteShellWord;

import '../../engine/protocol.dart';
import '../confirmation.dart';
import '../edit_reader.dart' show EditContext, kIndexReadMaxBytes;
import '../operation_plan.dart';
import '../plan_support.dart';
import '../plan_types.dart';

/// Plans [intent], a [KeepLastBackups] or [RemoveBackups], or says why
/// it cannot be planned: root's backups need admin mode, and a plan that
/// would remove nothing is refused.
Future<PlanAttempt> planBackupRemoval(
  ActionIntent intent,
  EditContext c,
) async {
  final (scope, kind) = switch (intent) {
    KeepLastBackups(:final scope) => (scope, OperationKind.keepLastBackups),
    RemoveBackups(:final scope) => (scope, OperationKind.removeAllBackups),
    _ => throw ArgumentError.value(intent, 'intent', 'not a backup removal'),
  };
  final root = scope == FootprintScope.root;
  final admin = c.admin;
  if (root && admin == null) return refused(ActionRefusalReason.adminRequired);

  Future<RemoteCommandResult> run(List<String> argv) => root
      ? admin!.executor.run(argv, password: admin.password)
      : c.link.run(
          HostCommands.commandLine(argv, quote: quoteShellWord),
          stdin: const [],
          maxOutputBytes: kIndexReadMaxBytes,
        );

  try {
    final dir = root ? kRootBackupsDir : await _userBackupsDir(run);
    if (dir == null) return refused(ActionRefusalReason.noLink);
    final read = await run(EditCommands.backupIndexRead(dir));
    if (read.exitCode != 0) return refused(ActionRefusalReason.noLink);
    // An index cut at the output cap is not the index: its hash is not
    // the file's, and the rewrite would lose the lines past the cut.
    if (read.truncated) {
      return refused(
        ActionRefusalReason.invalidTarget,
        detail: 'backup index: too large to read whole',
      );
    }
    final index = parseBackupIndex(read.stdout);
    // Lines the parser skipped would vanish from the rewrite.
    if (index.warnings.isNotEmpty) {
      return refused(ActionRefusalReason.invalidTarget);
    }

    final removed = switch (intent) {
      KeepLastBackups(:final count) => _beyondNewest(index.value, count),
      RemoveBackups(:final source) => [
        for (final entry in index.value)
          if (entry.source == source) entry,
      ],
      _ => const <BackupEntry>[],
    }.toSet();
    if (removed.isEmpty) return refused(ActionRefusalReason.invalidTarget);
    final kept = [
      for (final entry in index.value)
        if (!removed.contains(entry)) entry,
    ];

    return planned(
      OperationPlan(
        intent: intent,
        kind: kind,
        targetName: switch (intent) {
          RemoveBackups(:final source) => source,
          _ => dir,
        },
        steps: [
          ShellStep(
            EditCommands.backupIndexWrite(dir, sha256OfText(read.stdout)),
            elevated: root,
            input: utf8.encode(encodeBackupIndex(kept)),
            exitMeanings: const {
              EditExit.hashMismatch: RevalidationFailure.contentChanged,
            },
          ),
          ShellStep(
            EditCommands.removeBackups(dir, [
              for (final entry in removed) entry.name,
            ]),
            elevated: root,
          ),
        ],
        requiredLevel: root ? RequiredLevel.admin : RequiredLevel.login,
        runner: runnerFacts(elevated: root, user: c.profile.user),
        hostWrites: [
          root ? HostWriteRow.rootBackups : HostWriteRow.userBackups,
          HostWriteRow.loginRecords,
        ],
      ),
    );
  } on HostCommandError {
    return refused(ActionRefusalReason.invalidTarget);
  } on RemoteCommandException {
    return refused(ActionRefusalReason.noLink);
  }
}

/// The backups of each source older than its newest [count].
List<BackupEntry> _beyondNewest(List<BackupEntry> entries, int count) {
  final bySource = <String, List<BackupEntry>>{};
  for (final entry in entries) {
    (bySource[entry.source] ??= []).add(entry);
  }
  return [
    for (final group in bySource.values)
      ...(group..sort((a, b) => b.savedAt.compareTo(a.savedAt))).skip(count),
  ];
}

Future<String?> _userBackupsDir(
  Future<RemoteCommandResult> Function(List<String> argv) run,
) async {
  final result = await run(EditCommands.userBackupsDir());
  final dir = result.stdout.trim();
  return result.exitCode == 0 && dir.startsWith('/') ? dir : null;
}
