// SAF-12's edit read and plan (03 §8.5, D67; M5 plan M15) against a link
// that plays the host: what a read returns for the login user's files,
// root's, missing, large and binary ones and crontabs, and the steps,
// tiers and host writes each edit plans.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/edit_reader.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/plans/edit_plan.dart';
import 'package:klabautermann_core/src/operations/stack_edits.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ComposeProject, Ownership, composeConfig;
import 'package:klabautermann_host/klabautermann_host.dart'
    show EditCommands, EditExit, HostProfile, kRootBackupsDir;
import 'package:seance_core/seance_core.dart'
    show ElevatedExecutor, ElevationProbe, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';
const _password = 'correct-horse-staple';
const _home = '/home/deploy/.local/state/klabautermann/backups';
final _profile = HostProfile(uid: 1000, user: 'deploy');

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

/// A file the host serves to the read script: its owner, mode and text,
/// and whether only root may read it.
typedef _File = ({int uid, String mode, String text, bool rootOnly});

/// Plays the host: the read script over [files], `crontab -l` over
/// [crontabs], and the backup directory; through the elevation prelude
/// when the command carries it.
final class _Host extends TestLinkBase {
  final files = <String, _File>{};
  final crontabs = <String, String>{};
  final commands = <String>[];
  bool enforcing = false;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    final elevated = command.contains(' elevate ');
    if (command.contains('klabautermann-read')) {
      final path = files.keys.firstWhere(command.contains, orElse: () => '');
      final file = files[path];
      if (file == null) {
        return const RemoteCommandResult(
          exitCode: 1,
          stderr: 'stat: cannot statx: No such file or directory\n',
        );
      }
      if (file.rootOnly && !elevated) {
        return const RemoteCommandResult(
          exitCode: 1,
          stderr: 'stat: Permission denied\n',
        );
      }
      final bytes = utf8.encode(file.text).length;
      return RemoteCommandResult(
        exitCode: 0,
        stdout:
            '$bytes ${file.uid} ${file.uid} ${file.mode} '
            '${_sha(file.text)}\n${file.text}',
      );
    }
    if (command.contains("'crontab' '-l'")) {
      final user =
          RegExp(r"'-u' '([a-z_][a-z0-9_-]*)'").firstMatch(command)?[1] ??
          'deploy';
      final table = crontabs[user];
      return table == null
          ? RemoteCommandResult(exitCode: 1, stderr: 'no crontab for $user\n')
          : RemoteCommandResult(exitCode: 0, stdout: table);
    }
    if (command.contains('/sys/fs/selinux/enforce')) {
      return enforcing
          ? const RemoteCommandResult(exitCode: 0, stdout: '1\n')
          : const RemoteCommandResult(
              exitCode: 1,
              stderr: 'cat: /sys/fs/selinux/enforce: No such file\n',
            );
    }
    if (command.contains(kBackupsDirSuffixForTest)) {
      return const RemoteCommandResult(exitCode: 0, stdout: '$_home\n');
    }
    return const RemoteCommandResult(exitCode: 0);
  }
}

const kBackupsDirSuffixForTest = 'klabautermann/backups';

void main() {
  late _Host host;
  AdminSession? admin;

  setUp(() {
    host = _Host();
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
    _password,
  );

  group('reads', () {
    test("the login user's file reads with its owner and mode", () async {
      host.files['/home/deploy/app/.env'] = (
        uid: 1000,
        mode: '600',
        text: 'TOKEN=a\n',
        rootOnly: false,
      );

      final read = await readEditable(
        const FileTarget('/home/deploy/app/.env'),
        context(),
      );

      expect(read, isA<EditContent>());
      final content = read as EditContent;
      expect(content.text, 'TOKEN=a\n');
      expect(content.sha256, _sha('TOKEN=a\n'));
      expect((content.uid, content.mode), (1000, 384));
      expect(content.privileged, isFalse);
    });

    test("root's readable file is privileged; an unreadable one needs "
        'admin mode, and reads through it', () async {
      host.files['/etc/hosts'] = (
        uid: 0,
        mode: '644',
        text: '127.0.0.1 localhost\n',
        rootOnly: false,
      );
      host.files['/etc/shadow'] = (
        uid: 0,
        mode: '640',
        text: 'root:*:1::::::\n',
        rootOnly: true,
      );

      final hosts = await readEditable(
        const FileTarget('/etc/hosts'),
        context(),
      );
      expect((hosts as EditContent).privileged, isTrue);

      final refused = await readEditable(
        const FileTarget('/etc/shadow'),
        context(),
      );
      expect(
        (refused as EditReadFailed).failure,
        EditReadFailure.adminRequired,
      );

      adminOn();
      final shadow = await readEditable(
        const FileTarget('/etc/shadow'),
        context(),
      );
      expect((shadow as EditContent).text, 'root:*:1::::::\n');
      expect(host.commands.last, contains(' elevate '));
      expect(host.commands.last, isNot(contains(_password)));
    });

    test('a missing file, a large one, a binary one and a bad path each '
        'say why', () async {
      host.files['/var/big'] = (
        uid: 1000,
        mode: '644',
        text: 'x' * (kEditReadCap + 1),
        rootOnly: false,
      );
      host.files['/var/blob'] = (
        uid: 1000,
        mode: '644',
        text: 'a\u0000b',
        rootOnly: false,
      );
      Future<EditReadFailure> failure(String path) async =>
          ((await readEditable(FileTarget(path), context())) as EditReadFailed)
              .failure;

      expect(await failure('/var/missing'), EditReadFailure.notFound);
      expect(await failure('/var/big'), EditReadFailure.tooLarge);
      expect(await failure('/var/blob'), EditReadFailure.notText);
      expect(await failure('var/relative'), EditReadFailure.invalidTarget);
    });

    test('an absent crontab reads as empty; another account\'s needs admin '
        'mode', () async {
      final own = await readEditable(const CrontabTarget(), context());
      expect((own as EditContent).text, '');
      expect(own.sha256, _sha(''));
      expect(own.privileged, isFalse);

      final other = await readEditable(
        const CrontabTarget(user: 'www-data'),
        context(),
      );
      expect((other as EditReadFailed).failure, EditReadFailure.adminRequired);

      host.crontabs['www-data'] = '*/5 * * * * /usr/bin/true\n';
      adminOn();
      final read = await readEditable(
        const CrontabTarget(user: 'www-data'),
        context(),
      );
      expect((read as EditContent).text, '*/5 * * * * /usr/bin/true\n');
      expect(read.privileged, isTrue);
    });

    test('a crontab past the read cap is refused as a file is', () async {
      host.crontabs['deploy'] = '# ${'x' * kEditReadCap}\n';
      final read = await readEditable(const CrontabTarget(), context());
      expect((read as EditReadFailed).failure, EditReadFailure.tooLarge);
    });
  });

  group('plans', () {
    Future<PlanAttempt> plan(EditTarget target, String text, String base) =>
        planEdit(
          EditFile(_server, target: target, text: text, baseSha256: base),
          context(),
          random: Random(1),
        );

    List<List<String>> argvs(OperationPlan plan) => [
      for (final step in plan.steps) (step as ShellStep).argv,
    ];

    test("the login user's file: backup, temp, attributes, swap", () async {
      const path = '/home/deploy/app/.env';
      host.files[path] = (
        uid: 1000,
        mode: '600',
        text: 'TOKEN=a\n',
        rootOnly: false,
      );

      final attempt = await plan(
        const FileTarget(path),
        'TOKEN=b\n',
        _sha('TOKEN=a\n'),
      );
      final p = attempt.plan!;
      final temp = (p.steps[1] as ShellStep).argv.last;

      expect(temp, startsWith('/home/deploy/app/..env.klabautermann-tmp-'));
      expect(argvs(p), [
        EditCommands.backupFile(path, _home),
        EditCommands.writeTemp(temp),
        EditCommands.copyAttributes(path, temp),
        EditCommands.replaceIfHash(path, temp, _sha('TOKEN=a\n')),
      ]);
      expect(utf8.decode((p.steps[1] as ShellStep).input!), 'TOKEN=b\n');
      expect((p.steps.last as ShellStep).exitMeanings, {
        EditExit.hashMismatch: RevalidationFailure.contentChanged,
      });
      expect(p.cleanup.map((s) => s.argv), [EditCommands.removeTemp(temp)]);
      expect(p.steps.every((s) => !(s as ShellStep).elevated), isTrue);
      expect(p.requiredLevel, RequiredLevel.login);
      expect(p.kind, OperationKind.editFile);
      expect(p.tier, ConfirmationTier.acknowledge);
      expect(p.hostWrites, [
        HostWriteRow.editTarget,
        HostWriteRow.editTempFile,
        HostWriteRow.userBackups,
        HostWriteRow.loginRecords,
      ]);
      expect(p.targetName, path);
      expect(p.danger, isEmpty, reason: 'the scripts are fixed text');
    });

    test("root's file runs every step elevated and backs up under "
        '/var/lib', () async {
      host.files['/etc/app.conf'] = (
        uid: 0,
        mode: '640',
        text: 'a=1\n',
        rootOnly: false,
      );

      final p = (await plan(
        const FileTarget('/etc/app.conf'),
        'a=2\n',
        _sha('a=1\n'),
      )).plan!;

      expect(p.steps.every((s) => (s as ShellStep).elevated), isTrue);
      expect(p.cleanup.single.elevated, isTrue);
      expect(
        argvs(p).first,
        EditCommands.backupFile('/etc/app.conf', kRootBackupsDir),
      );
      expect(p.requiredLevel, RequiredLevel.admin);
      expect(p.runner.identity, 'root');
      expect(p.hostWrites, contains(HostWriteRow.rootBackups));
      expect(p.protected, isNull);
      expect(argvs(p).last.first, isNot('restorecon'));

      host.enforcing = true;
      final relabelled = (await plan(
        const FileTarget('/etc/app.conf'),
        'a=2\n',
        _sha('a=1\n'),
      )).plan!;
      expect(argvs(relabelled).last, EditCommands.restorecon('/etc/app.conf'));
      expect((relabelled.steps.last as ShellStep).elevated, isTrue);
    });

    test('sudo rules are validated by visudo and need the typed '
        'confirmation', () async {
      adminOn();
      host.files['/etc/sudoers.d/deploy'] = (
        uid: 0,
        mode: '440',
        text: 'deploy ALL=(ALL) ALL\n',
        rootOnly: true,
      );

      final p = (await plan(
        const FileTarget('/etc/sudoers.d/deploy'),
        'deploy ALL=(ALL) NOPASSWD: /usr/bin/docker\n',
        _sha('deploy ALL=(ALL) ALL\n'),
      )).plan!;
      final temp = (p.steps[1] as ShellStep).argv.last;

      expect(argvs(p)[2], ['visudo', '-c', '-f', temp]);
      expect(p.protected, ProtectedReason.builtIn);
      expect(p.tier, ConfirmationTier.typedPhrase);
    });

    test('a target that changed since the read, a bad path and a file only '
        'root may read without admin mode are refused', () async {
      host.files['/etc/app.conf'] = (
        uid: 0,
        mode: '644',
        text: 'a=1\n',
        rootOnly: false,
      );
      host.files['/etc/secret.conf'] = (
        uid: 0,
        mode: '600',
        text: 'k=v\n',
        rootOnly: true,
      );

      expect(
        (await plan(
          const FileTarget('/etc/app.conf'),
          'b',
          _sha('old'),
        )).refusal,
        ActionRefusalReason.targetChanged,
      );
      expect(
        (await plan(
          const FileTarget('etc/app.conf'),
          'b',
          _sha('a=1\n'),
        )).refusal,
        ActionRefusalReason.invalidTarget,
      );
      expect(
        (await plan(
          const FileTarget('/etc/secret.conf'),
          'b',
          _sha('k=v\n'),
        )).refusal,
        ActionRefusalReason.adminRequired,
      );
    });

    test('a crontab overwrite backs the table up and swaps it only while '
        'its hash holds', () async {
      host.crontabs['deploy'] = '0 3 * * * /usr/local/bin/backup\n';
      const next = '0 4 * * * /usr/local/bin/backup\n';

      final p = (await plan(
        const CrontabTarget(),
        next,
        _sha('0 3 * * * /usr/local/bin/backup\n'),
      )).plan!;

      expect(p.kind, OperationKind.crontabOverwrite);
      expect(p.tier, ConfirmationTier.typedPhrase);
      expect(p.targetName, 'crontab:deploy');
      expect(argvs(p), [
        EditCommands.crontabBackup(_home, indexName: 'crontab:deploy'),
        EditCommands.crontabWriteIfHash(
          _sha('0 3 * * * /usr/local/bin/backup\n'),
        ),
      ]);
      expect(utf8.decode((p.steps.last as ShellStep).input!), next);
      expect(p.requiredLevel, RequiredLevel.login);

      adminOn();
      final other = (await plan(
        const CrontabTarget(user: 'www-data'),
        next,
        _sha(''),
      )).plan!;
      expect(other.requiredLevel, RequiredLevel.admin);
      expect(other.targetName, 'crontab:www-data');
      expect(
        argvs(other).first,
        EditCommands.crontabBackup(
          kRootBackupsDir,
          indexName: 'crontab:www-data',
          user: 'www-data',
        ),
      );
    });
  });

  group('stack files (STK-07, M25b)', () {
    const compose = '/srv/web/compose.yaml';
    const override = '/srv/web/compose.override.yaml';
    const dotEnv = '/srv/web/.env';
    const socket = '/run/docker.sock';
    const web = ComposeProject(
      name: 'web',
      services: [],
      ownership: Ownership([]),
      workingDir: '/srv/web',
      configFiles: [compose, override],
    );

    StackEditLookup lookup({
      ComposeProject? project = web,
      StackFileFailure? failure,
    }) =>
        (name, path) async => (
          project: failure == null ? project : null,
          socketPath: failure == null ? socket : null,
          failure: failure,
        );

    void serve(String path, String text) => host.files[path] = (
      uid: 1000,
      mode: '644',
      text: text,
      rootOnly: false,
    );

    Future<PlanAttempt> plan(String path, StackEditLookup? stacks) => planEdit(
      EditFile(
        _server,
        target: StackFileTarget(project: 'web', path: path),
        text: 'services: {}\n',
        baseSha256: _sha('services:\n'),
      ),
      context(),
      random: Random(1),
      stacks: stacks,
    );

    test("a verified project's file reads as a file does", () async {
      serve(compose, 'services:\n');
      final read = await readEditable(
        const StackFileTarget(project: 'web', path: compose),
        context(),
        stacks: lookup(),
      );
      expect((read as EditContent).text, 'services:\n');
    });

    test('an unverified project, a stranger file and no Docker endpoint '
        'read nothing', () async {
      serve(compose, 'services:\n');
      Future<EditReadResult> read(StackEditLookup? stacks) => readEditable(
        const StackFileTarget(project: 'web', path: compose),
        context(),
        stacks: stacks,
      );

      expect(
        (await read(lookup(failure: StackFileFailure.notVerified))
                as EditReadFailed)
            .failure,
        EditReadFailure.stackUnverified,
      );
      expect(
        (await read(lookup(failure: StackFileFailure.notStackFile))
                as EditReadFailed)
            .failure,
        EditReadFailure.invalidTarget,
      );
      expect(
        (await read(null) as EditReadFailed).failure,
        EditReadFailure.failed,
      );
      expect(host.commands, isEmpty, reason: 'nothing was read');
    });

    test('the candidate is checked by compose config -q in the file\'s '
        'place before the swap', () async {
      serve(override, 'services:\n');
      final p = (await plan(override, lookup())).plan!;
      final temp = _stepRunning(p, 'klabautermann-write').argv.last;
      final check = _stepRunning(p, 'config');

      expect(check.argv, [
        ...composeConfig(
          socketPath: socket,
          project: 'web',
          projectDirectory: '/srv/web',
          configFiles: [compose, temp],
          quiet: true,
        ).argv,
      ]);
      expect(check.discardOutput, isTrue);
      final checked = p.steps.indexOf(check);
      expect(
        (p.steps[checked + 1] as ShellStep).argv,
        EditCommands.replaceIfHash(override, temp, _sha('services:\n')),
      );
      expect(p.targetName, override);
    });

    test("the working directory's .env is checked as the env file when "
        'the project records none', () async {
      serve(dotEnv, 'services:\n');
      final p = (await plan(dotEnv, lookup())).plan!;
      final temp = _stepRunning(p, 'klabautermann-write').argv.last;
      final check = _stepRunning(p, 'config').argv;

      expect(check, containsAllInOrder(['--env-file', temp]));
      expect(check, containsAllInOrder(['-f', compose, '-f', override]));
    });

    test('an unverified project is refused before anything is read, and '
        'no lookup means no engine to plan with', () async {
      serve(compose, 'services:\n');
      expect(
        (await plan(
          compose,
          lookup(failure: StackFileFailure.notVerified),
        )).refusal,
        ActionRefusalReason.stackUnverified,
      );
      expect(host.commands, isEmpty);
      expect(
        (await plan(compose, null)).refusal,
        ActionRefusalReason.engineUnavailable,
      );
    });
  });
}

/// [plan]'s first shell step whose argv holds [word], wherever steps
/// before it, such as the manifest's, put it.
ShellStep _stepRunning(OperationPlan plan, String word) => plan.steps
    .whereType<ShellStep>()
    .firstWhere((step) => step.argv.contains(word));
