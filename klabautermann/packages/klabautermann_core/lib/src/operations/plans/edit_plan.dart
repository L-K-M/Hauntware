// SAF-12's edit plan (03 §8.5, §8.11, D67; M5 plan M15): the steps that
// back a file or crontab up and replace its content only while it still
// has the hash the editor read. Planning reads the target again, so a
// change since the editor opened it is refused before the preview, and
// the last step re-checks the hash on the host right before the rename.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        EditCommands,
        EditExit,
        HostCommandError,
        HostCommands,
        encodeFootprintManifest,
        kVerifyAsUnitSystemd,
        kRootBackupsDir,
        kRootManifestPath,
        parseFootprintManifest,
        unitFileName;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult, quoteShellWord;

import '../../engine/protocol.dart';
import '../confirmation.dart';
import '../edit_reader.dart';
import '../footprint.dart' show manifestWithBackups;
import '../operation_plan.dart';
import '../plan_types.dart';
import '../stack_edits.dart';

/// Files whose edit can lock the user out of the host or out of root, so
/// the typed confirmation applies (03 §8.6): sudo's rules and the SSH
/// server's configuration.
bool isProtectedEditPath(String path) =>
    path == '/etc/sudoers' ||
    path.startsWith('/etc/sudoers.d/') ||
    path.startsWith('/etc/ssh/');

/// Paths `visudo -c -f` validates before the rename.
bool _isSudoers(String path) =>
    path == '/etc/sudoers' || path.startsWith('/etc/sudoers.d/');

/// The step exit that means the target changed under the edit.
const _contentChanged = {
  EditExit.hashMismatch: RevalidationFailure.contentChanged,
};

/// Plans [intent], or says why it cannot be planned. [random] draws the
/// temp file's token; tests pass a seeded one. A [StackFileTarget] is
/// looked up through [stacks], as its read was.
Future<PlanAttempt> planEdit(
  EditFile intent,
  EditContext c, {
  Random? random,
  StackEditLookup? stacks,
}) async {
  try {
    return switch (intent.target) {
      FileTarget(:final path) => await _planFile(
        intent,
        path,
        c,
        random ?? Random.secure(),
      ),
      CrontabTarget(:final user) => await _planCrontab(intent, user, c),
      StackFileTarget(:final project, :final path) => await _planStackFile(
        intent,
        project,
        path,
        c,
        random ?? Random.secure(),
        stacks,
      ),
    };
  } on HostCommandError {
    return _refused(ActionRefusalReason.invalidTarget);
  } on RemoteCommandException {
    return _refused(ActionRefusalReason.noLink);
  }
}

/// A verified stack's file (STK-07): the file plan, with the candidate
/// checked by `compose config -q` before the rename.
Future<PlanAttempt> _planStackFile(
  EditFile intent,
  String project,
  String path,
  EditContext c,
  Random random,
  StackEditLookup? stacks,
) async {
  if (stacks == null) return _refused(ActionRefusalReason.engineUnavailable);
  final source = await stacks(project, path);
  final found = source.project;
  final socketPath = source.socketPath;
  if (found == null || socketPath == null) {
    return _readRefusal(
      EditReadFailed(
        stackReadFailure(source.failure ?? StackFileFailure.unknownStack),
      ),
    );
  }
  try {
    return await _planFile(
      intent,
      path,
      c,
      random,
      check: (temp) => stackCandidateCheck(
        project: found,
        socketPath: socketPath,
        dockerProgram: source.dockerProgram ?? 'docker',
        path: path,
        temp: temp,
      ),
    );
  } on ArgumentError {
    // Verification built the same invocation, so a label changed since.
    return _refused(ActionRefusalReason.stackUnverified);
  }
}

/// [check] builds a step that validates the candidate at its temp path,
/// run after its attributes are carried over and before the rename.
Future<PlanAttempt> _planFile(
  EditFile intent,
  String path,
  EditContext c,
  Random random, {
  List<String> Function(String temp)? check,
}) async {
  // Validates the path before anything reads it.
  final token = _token(random);
  final temp = EditCommands.tempPathFor(path, token);
  final checkArgv = check?.call(temp);

  final current = await readEditable(FileTarget(path), c);
  if (current is! EditContent || current.sha256 != intent.baseSha256) {
    return _readRefusal(current);
  }
  final privileged = current.privileged;
  // Root's backups and manifest are root's alone, so even planning needs
  // admin mode.
  if (privileged && c.admin == null) {
    return _refused(ActionRefusalReason.adminRequired);
  }

  final backups = privileged ? kRootBackupsDir : await _userBackupsDir(c);
  if (backups == null) return _refused(ActionRefusalReason.noLink);
  final manifest = await _manifestStep(c, root: privileged, backups: backups);
  if (manifest case _ManifestRefused(:final reason)) return _refused(reason);
  final relabel = await _selinuxEnforcing(c);
  // A unit file is checked as its unit before the rename where the
  // host's systemd can load the temp under the unit's name; elsewhere the
  // preview says it is not.
  final unit = unitFileName(path);
  final verifyUnit =
      unit != null &&
      !temp.contains(':') &&
      (c.profile.systemdVersion ?? 0) >= kVerifyAsUnitSystemd;

  ShellStep step(List<String> argv, {List<int>? input, bool cas = false}) =>
      ShellStep(
        argv,
        elevated: privileged,
        input: input,
        exitMeanings: cas ? _contentChanged : const {},
      );

  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.editFile,
      targetName: path,
      steps: [
        step(EditCommands.backupFile(path, backups)),
        if (manifest case _ManifestWrite(:final step)) step,
        step(EditCommands.writeTemp(temp), input: utf8.encode(intent.text)),
        if (_isSudoers(path)) step(['visudo', '-c', '-f', temp]),
        if (verifyUnit) step(EditCommands.verifyUnit(temp, unit)),
        step(EditCommands.copyAttributes(path, temp)),
        // Status only: compose's errors can quote interpolated values.
        if (checkArgv != null)
          ShellStep(checkArgv, elevated: privileged, discardOutput: true),
        step(
          EditCommands.replaceIfHash(path, temp, intent.baseSha256),
          cas: true,
        ),
        if (relabel) step(EditCommands.restorecon(path)),
      ],
      cleanup: [step(EditCommands.removeTemp(temp))],
      requiredLevel: privileged ? RequiredLevel.admin : RequiredLevel.login,
      runner: _runner(c, elevated: privileged),
      hostWrites: [
        HostWriteRow.editTarget,
        HostWriteRow.editTempFile,
        privileged ? HostWriteRow.rootBackups : HostWriteRow.userBackups,
        if (manifest is _ManifestWrite) HostWriteRow.footprintManifest,
        HostWriteRow.loginRecords,
      ],
      protected: isProtectedEditPath(path) ? ProtectedReason.builtIn : null,
      warnings: [if (unit != null && !verifyUnit) PlanWarning.unitNotVerified],
    ),
  );
}

Future<PlanAttempt> _planCrontab(
  EditFile intent,
  String? user,
  EditContext c,
) async {
  final own = user == null || user == c.profile.user;
  final current = await readEditable(CrontabTarget(user: user), c);
  if (current is! EditContent || current.sha256 != intent.baseSha256) {
    return _readRefusal(current);
  }

  final backups = own ? await _userBackupsDir(c) : kRootBackupsDir;
  if (backups == null) return _refused(ActionRefusalReason.noLink);
  final manifest = await _manifestStep(c, root: !own, backups: backups);
  if (manifest case _ManifestRefused(:final reason)) return _refused(reason);
  final name = own ? (c.profile.user ?? 'login user') : user;
  final crontabUser = own ? null : user;

  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.crontabOverwrite,
      targetName: 'crontab:$name',
      steps: [
        ShellStep(
          EditCommands.crontabBackup(
            backups,
            indexName: 'crontab:$name',
            user: crontabUser,
          ),
          elevated: !own,
        ),
        if (manifest case _ManifestWrite(:final step)) step,
        ShellStep(
          EditCommands.crontabWriteIfHash(intent.baseSha256, user: crontabUser),
          elevated: !own,
          input: utf8.encode(intent.text),
          exitMeanings: _contentChanged,
        ),
      ],
      requiredLevel: own ? RequiredLevel.login : RequiredLevel.admin,
      runner: _runner(c, elevated: !own),
      hostWrites: [
        HostWriteRow.editTarget,
        own ? HostWriteRow.userBackups : HostWriteRow.rootBackups,
        if (manifest is _ManifestWrite) HostWriteRow.footprintManifest,
        HostWriteRow.loginRecords,
      ],
    ),
  );
}

/// Why a read at planning time means no plan: the target changed since
/// the editor read it, or the read itself failed.
PlanAttempt _readRefusal(EditReadResult current) => _refused(switch (current) {
  EditContent() => ActionRefusalReason.targetChanged,
  EditReadFailed(:final failure) => switch (failure) {
    EditReadFailure.adminRequired => ActionRefusalReason.adminRequired,
    EditReadFailure.noLink ||
    EditReadFailure.failed => ActionRefusalReason.noLink,
    EditReadFailure.invalidTarget ||
    EditReadFailure.tooLarge ||
    EditReadFailure.notText => ActionRefusalReason.invalidTarget,
    EditReadFailure.notFound => ActionRefusalReason.targetChanged,
    EditReadFailure.stackUnverified => ActionRefusalReason.stackUnverified,
  },
});

/// What the plan does about the manifest (03 §8.11): nothing while it
/// already lists [backups], else writes it with the backup directory's
/// rows added.
sealed class _Manifest {
  const _Manifest();
}

final class _ManifestListed extends _Manifest {
  const _ManifestListed();
}

final class _ManifestWrite extends _Manifest {
  const _ManifestWrite(this.step);

  final ShellStep step;
}

final class _ManifestRefused extends _Manifest {
  const _ManifestRefused(this.reason);

  final ActionRefusalReason reason;
}

/// Reads the [root] or login user's manifest and says whether the plan
/// must write it, so the first backup lands with its manifest rows
/// (SAF-14). A manifest the engine cannot read whole is refused rather
/// than written over.
Future<_Manifest> _manifestStep(
  EditContext c, {
  required bool root,
  required String backups,
}) async {
  Future<RemoteCommandResult> run(List<String> argv) => root
      ? c.admin!.executor.run(argv, password: c.admin!.password)
      : c.link.run(
          HostCommands.commandLine(argv, quote: quoteShellWord),
          stdin: const [],
        );

  final String path;
  if (root) {
    path = kRootManifestPath;
  } else {
    final resolved = await run(EditCommands.userManifestPath());
    final userPath = resolved.stdout.trim();
    if (resolved.exitCode != 0 || !userPath.startsWith('/')) {
      return const _ManifestRefused(ActionRefusalReason.noLink);
    }
    path = userPath;
  }
  final read = await run(EditCommands.manifestRead(path));
  if (read.exitCode != 0) {
    return const _ManifestRefused(ActionRefusalReason.noLink);
  }
  final parsed = parseFootprintManifest(read.stdout);
  // The rewrite keeps only the rows the parser understood, so a manifest
  // with any it skipped is refused rather than shortened, as the backup
  // index is.
  if (parsed.warnings.isNotEmpty ||
      (parsed.value.isEmpty && read.stdout.trim().isNotEmpty)) {
    return const _ManifestRefused(ActionRefusalReason.invalidTarget);
  }
  final rows = manifestWithBackups(parsed.value, backups);
  if (rows == null) return const _ManifestListed();
  return _ManifestWrite(
    ShellStep(
      // Against the read above: a manifest another run changed since is
      // not overwritten with rows built from the old one. The check and
      // the rename are two steps, so two runs between them can still
      // drop one's rows; its backup then shows as an orphan.
      EditCommands.manifestWrite(
        path,
        sha256.convert(utf8.encode(read.stdout)).toString(),
      ),
      elevated: root,
      input: utf8.encode(encodeFootprintManifest(rows)),
      exitMeanings: _contentChanged,
    ),
  );
}

/// Whether SELinux enforces on the host, so the rename needs
/// `restorecon` (D67): read at planning time, as the target is, rather
/// than probed.
Future<bool> _selinuxEnforcing(EditContext c) async {
  final result = await c.link.run(
    HostCommands.commandLine(
      EditCommands.selinuxEnforcing(),
      quote: quoteShellWord,
    ),
    stdin: const [],
  );
  return result.exitCode == 0 && result.stdout.trim() == '1';
}

/// The login user's backup directory, resolved in its login shell.
Future<String?> _userBackupsDir(EditContext c) async {
  final result = await c.link.run(
    HostCommands.commandLine(
      EditCommands.userBackupsDir(),
      quote: quoteShellWord,
    ),
    stdin: const [],
  );
  final dir = result.stdout.trim();
  return result.exitCode == 0 && dir.startsWith('/') ? dir : null;
}

String _token(Random random) => [
  for (var i = 0; i < 8; i++)
    random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

RunnerFacts _runner(EditContext c, {required bool elevated}) => RunnerFacts(
  identity: elevated ? 'root' : (c.profile.user ?? 'login user'),
  credentials: elevated
      ? RunnerCredentials.adminPassword
      : RunnerCredentials.session,
);

PlanAttempt _planned(OperationPlan plan) => (plan: plan, refusal: null);

PlanAttempt _refused(ActionRefusalReason reason) =>
    (plan: null, refusal: reason);
