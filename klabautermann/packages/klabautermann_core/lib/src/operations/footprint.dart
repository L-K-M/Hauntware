// Reads what Klabautermann keeps on a host (SAF-14, 03 §8.11; M5 plan
// M16, P13): each scope's manifest, whether its rows are there, and every
// backup its indexes record, checked against the recorded hash. The
// login user's part reads unelevated on every connect; root's needs admin
// mode, since its manifest and backups are root 0600 and 0700.
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        BackupEntry,
        EditCommands,
        backupFootprint,
        FootprintKind,
        FootprintRow,
        HostCommands,
        kRootManifestPath,
        parseBackupIndex,
        parseFootprintManifest,
        parseSha256List;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandResult, quoteShellWord;

import '../engine/protocol.dart';
import 'edit_reader.dart' show EditContext;

/// Runs one command for a scope: as the login user, or through admin
/// mode for root's.
typedef _Run = Future<RemoteCommandResult> Function(List<String> argv);

/// Reads [serverId]'s footprint; never throws. A scope whose reads fail
/// adds a warning and no rows.
Future<FootprintState> readFootprint(String serverId, EditContext c) async {
  final files = <FootprintFile>[];
  final backups = <FootprintBackup>[];
  final warnings = <String>[];

  Future<RemoteCommandResult> plain(List<String> argv) => c.link.run(
    HostCommands.commandLine(argv, quote: quoteShellWord),
    stdin: const [],
  );

  Future<void> scope(FootprintScope scope, String manifest, _Run run) async {
    try {
      await _readScope(scope, manifest, run, files, backups, warnings);
    } on Object catch (error) {
      warnings.add('${scope.name} footprint: $error');
    }
  }

  try {
    final userManifest = await _userManifestPath(plain);
    if (userManifest == null) {
      warnings.add('user footprint: no manifest path');
    } else {
      await scope(FootprintScope.user, userManifest, plain);
    }
  } on Object catch (error) {
    warnings.add('user footprint: $error');
  }
  final admin = c.admin;
  if (admin != null) {
    await scope(
      FootprintScope.root,
      kRootManifestPath,
      (argv) => admin.executor.run(argv, password: admin.password),
    );
  }
  return FootprintState(
    serverId,
    files: List.unmodifiable(files),
    backups: List.unmodifiable(backups),
    rootUnchecked: admin == null,
    warnings: List.unmodifiable(warnings),
  );
}

Future<void> _readScope(
  FootprintScope scope,
  String manifestPath,
  _Run run,
  List<FootprintFile> files,
  List<FootprintBackup> backups,
  List<String> warnings,
) async {
  final manifest = await run(EditCommands.manifestRead(manifestPath));
  if (manifest.exitCode != 0) {
    warnings.add('${scope.name} manifest: exit ${manifest.exitCode}');
    return;
  }
  final rows = parseFootprintManifest(manifest.stdout);
  warnings.addAll(rows.warnings);
  if (rows.value.isEmpty) return;

  final listed = [for (final row in rows.value) row.path];
  final present = (await run(
    EditCommands.existingPaths(listed),
  )).stdout.split('\n').toSet();
  for (final row in rows.value) {
    files.add(FootprintFile(scope, row, present: present.contains(row.path)));
  }

  for (final row in rows.value) {
    if (row.kind != FootprintKind.backupDirectory) continue;
    if (!present.contains(row.path)) continue;
    final index = await run(EditCommands.backupIndexRead(row.path));
    if (index.exitCode != 0) {
      warnings.add('${scope.name} backup index: exit ${index.exitCode}');
      continue;
    }
    final entries = parseBackupIndex(index.stdout);
    warnings.addAll(entries.warnings);
    if (entries.value.isEmpty) continue;
    final sums = parseSha256List(
      (await run(
        EditCommands.sha256List([
          for (final entry in entries.value) '${row.path}/${entry.name}',
        ]),
      )).stdout,
    );
    for (final entry in entries.value) {
      backups.add(
        FootprintBackup(
          scope,
          entry,
          _status(sums['${row.path}/${entry.name}'], entry),
        ),
      );
    }
  }
}

FootprintBackupStatus _status(String? sum, BackupEntry entry) => switch (sum) {
  null => FootprintBackupStatus.missing,
  final s when s == entry.sha256 => FootprintBackupStatus.intact,
  _ => FootprintBackupStatus.modified,
};

/// The login user's manifest path, resolved in its login shell.
Future<String?> _userManifestPath(_Run run) async {
  final result = await run(EditCommands.userManifestPath());
  final path = result.stdout.trim();
  return result.exitCode == 0 && path.startsWith('/') ? path : null;
}

/// [rows] with the rows [dir]'s backups add, or null when [rows] already
/// list them.
List<FootprintRow>? manifestWithBackups(List<FootprintRow> rows, String dir) {
  final missing = [
    for (final row in backupFootprint(dir))
      if (!rows.contains(row)) row,
  ];
  return missing.isEmpty ? null : [...rows, ...missing];
}
