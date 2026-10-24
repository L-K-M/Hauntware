// Restores a journal's trash in this process's working directory, which
// the journal test sets: a legacy relative trash location resolves against
// it. Moving Directory.current inside the test runner instead would move it
// for every suite running beside that test.
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

Future<void> main(List<String> arguments) async {
  final [journalPath, restoreRoot] = arguments;
  final fs = LocalFileSystem();
  final report = await restoreTrashedFiles(
    await SyncRunJournal.open(journalPath),
    fsFor: (_) => fs,
    rootFor: (_) => restoreRoot,
  );
  stdout.write(
    jsonEncode({
      'restored': report.restored,
      'skipped': [
        for (final skip in report.skipped)
          '${skip.relativePath}: ${skip.reason}',
      ],
    }),
  );
}
