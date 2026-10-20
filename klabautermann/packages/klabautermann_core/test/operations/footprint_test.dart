// SAF-14's footprint (03 §8.11; M5 plan M16, P13) against a link that
// plays the host: what the reader reports for each scope's manifest and
// backups, and the backup removals it plans.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/edit_reader.dart';
import 'package:klabautermann_core/src/operations/footprint.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/plans/backup_plans.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        BackupEntry,
        EditCommands,
        EditExit,
        FootprintKind,
        FootprintRow,
        HostProfile,
        backupFootprint,
        encodeBackupIndex,
        encodeFootprintManifest,
        kRootBackupsDir,
        kRootManifestPath;
import 'package:seance_core/seance_core.dart'
    show ElevatedExecutor, ElevationProbe;
import 'package:test/test.dart';

import '../support/edit_host.dart';

const _server = 'srv-1';
final _profile = HostProfile(uid: 1000, user: 'deploy');

/// A backup of [content] for [source], saved at [epoch] seconds.
BackupEntry _entry(String content, String source, int epoch) => BackupEntry(
  savedAt: DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true),
  sha256: sha256Of(content),
  source: source,
);

void main() {
  late EditHost host;
  AdminSession? admin;

  setUp(() {
    host = EditHost();
    admin = null;
  });

  EditContext context() => (link: host, profile: _profile, admin: admin);

  void adminOn() => admin = AdminSession.test(
    ElevatedExecutor(
      host,
      const ElevationProbe(
        sudoVersionLine: 'Sudo version 1.9.16p2',
        printfIsBuiltin: true,
      ),
    ),
    'correct-horse-staple',
  );

  /// Puts a scope's manifest, backup directory and index on the host,
  /// with a blob for each backup in [blobs] keyed by its name.
  void scope(
    String manifest,
    String dir,
    List<BackupEntry> entries, {
    Map<String, String> blobs = const {},
  }) {
    host.readable[manifest] = encodeFootprintManifest(backupFootprint(dir));
    host.directories.add(dir);
    host.readable['$dir/index'] = encodeBackupIndex(entries);
    for (final MapEntry(key: name, value: content) in blobs.entries) {
      host.blobs['$dir/$name'] = content;
    }
  }

  group('reads', () {
    test("the login user's backups are intact, modified or missing, and "
        "root's go unchecked without admin mode", () async {
      final intact = _entry('a=1\n', '/home/deploy/.env', 100);
      final modified = _entry('a=2\n', '/home/deploy/.env', 200);
      final missing = _entry('a=3\n', 'crontab:deploy', 300);
      scope(
        kHostUserManifest,
        kHostUserBackups,
        [intact, modified, missing],
        blobs: {intact.name: 'a=1\n', modified.name: 'tampered\n'},
      );

      final state = await readFootprint(_server, context());

      expect(state.serverId, _server);
      expect(state.warnings, isEmpty);
      expect(state.rootUnchecked, isTrue);
      expect(
        [for (final f in state.files) (f.scope, f.row.path, f.present)],
        [
          (FootprintScope.user, kHostUserBackups, true),
          (FootprintScope.user, '$kHostUserBackups/index', true),
        ],
      );
      expect(
        {for (final b in state.backups) b.entry: b.status},
        {
          intact: FootprintBackupStatus.intact,
          modified: FootprintBackupStatus.modified,
          missing: FootprintBackupStatus.missing,
        },
      );
      expect(state.backups.every((b) => b.scope == FootprintScope.user), true);
      // Root's part is never read without admin mode.
      expect(
        host.commands.where((c) => c.contains(kRootManifestPath)),
        isEmpty,
      );
    });

    test('a host without a manifest has no footprint', () async {
      final state = await readFootprint(_server, context());

      expect(state.files, isEmpty);
      expect(state.backups, isEmpty);
      expect(state.warnings, isEmpty);
    });

    test("root's part reads through admin mode; a listed directory that "
        'is gone shows absent', () async {
      host.readable[kRootManifestPath] = encodeFootprintManifest(
        backupFootprint(kRootBackupsDir),
      );
      adminOn();

      final state = await readFootprint(_server, context());

      expect(state.rootUnchecked, isFalse);
      expect(
        [for (final f in state.files) (f.scope, f.row.path, f.present)],
        [
          (FootprintScope.root, kRootBackupsDir, false),
          (FootprintScope.root, '$kRootBackupsDir/index', false),
        ],
      );
      expect(state.backups, isEmpty);
      expect(
        host.commands
            .where((c) => c.contains(kRootManifestPath))
            .every((c) => c.contains(' elevate ')),
        isTrue,
      );
    });

    test('a malformed index line warns and the rest still verify', () async {
      final entry = _entry('x\n', '/home/deploy/x', 100);
      scope(
        kHostUserManifest,
        kHostUserBackups,
        [entry],
        blobs: {entry.name: 'x\n'},
      );
      host.readable['$kHostUserBackups/index'] =
          '${host.readable['$kHostUserBackups/index']}not a line\n';

      final state = await readFootprint(_server, context());

      expect(state.warnings, hasLength(1));
      expect(state.backups.single.status, FootprintBackupStatus.intact);
    });

    test('a manifest gains the rows of a directory it does not list yet', () {
      const other = FootprintRow('/x', FootprintKind.backupDirectory);
      final rows = backupFootprint(kHostUserBackups);

      expect(manifestWithBackups([other], kHostUserBackups), [other, ...rows]);
      expect(manifestWithBackups(rows, kHostUserBackups), isNull);
    });
  });

  group('plans', () {
    final a1 = _entry('a1', '/home/deploy/a', 100);
    final a2 = _entry('a2', '/home/deploy/a', 200);
    final a3 = _entry('a3', '/home/deploy/a', 300);
    final b1 = _entry('b1', '/home/deploy/b', 150);

    List<List<String>> argvs(OperationPlan plan) => [
      for (final step in plan.steps) (step as ShellStep).argv,
    ];

    Future<OperationPlan> planned(ActionIntent intent) async {
      final attempt = await planBackupRemoval(intent, context());
      expect(attempt.refusal, isNull);
      return attempt.plan!;
    }

    test('keep last N keeps the newest of each file and rewrites the '
        'index only while it holds', () async {
      scope(kHostUserManifest, kHostUserBackups, [a1, b1, a2, a3]);
      final index = host.readable['$kHostUserBackups/index']!;

      final p = await planned(
        const KeepLastBackups(_server, scope: FootprintScope.user, count: 2),
      );

      expect(p.kind, OperationKind.keepLastBackups);
      expect(p.tier, ConfirmationTier.acknowledge);
      expect(p.requiredLevel, RequiredLevel.login);
      expect(argvs(p), [
        EditCommands.backupIndexWrite(kHostUserBackups, sha256Of(index)),
        EditCommands.removeBackups(kHostUserBackups, [a1.name]),
      ]);
      expect(
        utf8.decode((p.steps.first as ShellStep).input!),
        encodeBackupIndex([b1, a2, a3]),
      );
      expect((p.steps.first as ShellStep).exitMeanings, {
        EditExit.hashMismatch: RevalidationFailure.contentChanged,
      });
      expect(p.steps.every((s) => !(s as ShellStep).elevated), isTrue);
      expect(p.hostWrites, [
        HostWriteRow.userBackups,
        HostWriteRow.loginRecords,
      ]);
    });

    test("removing every backup of one file needs the typed confirmation "
        'and names each', () async {
      scope(kHostUserManifest, kHostUserBackups, [a1, b1, a2]);

      final p = await planned(
        const RemoveBackups(
          _server,
          scope: FootprintScope.user,
          source: '/home/deploy/a',
        ),
      );

      expect(p.kind, OperationKind.removeAllBackups);
      expect(p.tier, ConfirmationTier.typedPhrase);
      expect(p.targetName, '/home/deploy/a');
      expect(
        argvs(p).last,
        EditCommands.removeBackups(kHostUserBackups, [a1.name, a2.name]),
      );
      expect(
        utf8.decode((p.steps.first as ShellStep).input!),
        encodeBackupIndex([b1]),
      );
    });

    test("root's backups need admin mode, then run elevated", () async {
      final r1 = _entry('r1', '/etc/hosts', 100);
      host.readable['$kRootBackupsDir/index'] = encodeBackupIndex([r1]);
      const intent = RemoveBackups(
        _server,
        scope: FootprintScope.root,
        source: '/etc/hosts',
      );

      expect(
        (await planBackupRemoval(intent, context())).refusal,
        ActionRefusalReason.adminRequired,
      );

      adminOn();
      final p = await planned(intent);

      expect(p.requiredLevel, RequiredLevel.admin);
      expect(p.steps.every((s) => (s as ShellStep).elevated), isTrue);
      expect(
        argvs(p).last,
        EditCommands.removeBackups(kRootBackupsDir, [r1.name]),
      );
      expect(p.hostWrites.first, HostWriteRow.rootBackups);
    });

    test('a plan that removes nothing, or an index with lines it would '
        'drop, is refused', () async {
      scope(kHostUserManifest, kHostUserBackups, [a1, b1]);

      Future<ActionRefusalReason?> refusal(ActionIntent intent) async =>
          (await planBackupRemoval(intent, context())).refusal;

      expect(
        await refusal(
          const KeepLastBackups(_server, scope: FootprintScope.user),
        ),
        ActionRefusalReason.invalidTarget,
      );
      expect(
        await refusal(
          const RemoveBackups(
            _server,
            scope: FootprintScope.user,
            source: '/home/deploy/none',
          ),
        ),
        ActionRefusalReason.invalidTarget,
      );

      host.readable['$kHostUserBackups/index'] =
          '${host.readable['$kHostUserBackups/index']}broken\n';
      expect(
        await refusal(
          const RemoveBackups(
            _server,
            scope: FootprintScope.user,
            source: '/home/deploy/a',
          ),
        ),
        ActionRefusalReason.invalidTarget,
      );
    });
  });
}
