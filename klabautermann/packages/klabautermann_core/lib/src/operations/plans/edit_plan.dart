// SAF-12's edit plan (03 §8.5, §8.11, D67; M5 plan M15): the steps that
// back a file or crontab up and replace its content only while it still
// has the hash the editor read. Planning reads the target again, so a
// change since the editor opened it is refused before the preview, and
// the last step re-checks the hash on the host right before the rename.
import 'dart:convert';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart'
    show
        EditCommands,
        EditExit,
        HostCommandError,
        HostCommands,
        kRootBackupsDir;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, quoteShellWord;

import '../../engine/protocol.dart';
import '../confirmation.dart';
import '../edit_reader.dart';
import '../operation_plan.dart';
import '../plan_types.dart';

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
/// temp file's token; tests pass a seeded one.
Future<PlanAttempt> planEdit(
  EditFile intent,
  EditContext c, {
  Random? random,
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
    };
  } on HostCommandError {
    return _refused(ActionRefusalReason.invalidTarget);
  } on RemoteCommandException {
    return _refused(ActionRefusalReason.noLink);
  }
}

Future<PlanAttempt> _planFile(
  EditFile intent,
  String path,
  EditContext c,
  Random random,
) async {
  // Validates the path before anything reads it.
  final token = _token(random);
  final temp = EditCommands.tempPathFor(path, token);

  final current = await readEditable(FileTarget(path), c);
  if (current is! EditContent || current.sha256 != intent.baseSha256) {
    return _readRefusal(current);
  }
  final privileged = current.privileged;

  final backups = privileged ? kRootBackupsDir : await _userBackupsDir(c);
  if (backups == null) return _refused(ActionRefusalReason.noLink);
  final relabel = await _selinuxEnforcing(c);

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
        step(EditCommands.writeTemp(temp), input: utf8.encode(intent.text)),
        if (_isSudoers(path)) step(['visudo', '-c', '-f', temp]),
        step(EditCommands.copyAttributes(path, temp)),
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
        HostWriteRow.loginRecords,
      ],
      protected: isProtectedEditPath(path) ? ProtectedReason.builtIn : null,
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
  },
});

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
