// Privileged edits on the GitHub-hosted Ubuntu runner (M5 plan M20b;
// SAF-12, SAF-14, JOB-06; 03 §8.5, §8.11, D67): the engine in admin mode
// as runner_vm.sh's password-sudo account. A root file edited through the
// elevation prelude keeps its owner, mode, ACL entry and extended
// attribute, and is backed up under /var/lib/klabautermann/backups, 0700,
// with the root manifest, which a later connect verifies only once admin
// mode is on; a unit file whose candidate `systemd-analyze verify`
// rejects is not replaced; a root file changed between plan and run stays
// as changed; and another account's crontab is replaced through
// `crontab -u <user> -`.
//
// Each test seeds the files it edits as root and removes them, the root
// backups and the root manifest again; runner_vm.sh removes the backups
// and the manifest too should a run end part-way. It starts the leg and
// runs these one at a time; without it they skip.
@Tags(['runner-vm'])
@Timeout(Duration(minutes: 4))
library;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        FootprintKind,
        kEditTempInfix,
        kRootBackupsDir,
        kRootManifestPath,
        kVerifyAsUnitSystemd;
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/fixture.dart';
import 'support/runner_vm.dart';

/// The directory the root file lives in, which each test makes and
/// removes.
const _editDir = '/etc/klabautermann-vm-edit';
const _rootFile = '$_editDir/app.conf';

/// The unit file the verify test edits, beside runner_vm.sh's own.
const _unitFile = '/etc/systemd/system/klabautermann-vm-edit.service';

/// The extended attribute the root file carries.
const _xattr = 'user.klabautermann';

/// Covers the footprint's reads after a connect or admin mode turning on.
const _footprintWait = Duration(seconds: 30);

void main() {
  final vm = RunnerVm.fromEnvironment();
  if (vm == null) {
    test('the runner-VM edit suite', () {}, skip: runnerVmSkipReason);
    return;
  }

  var reads = 0;

  Future<String> root(String script) => vm.sudo(['sh', '-c', script]);

  /// Removes the root backups and manifest an edit writes, before and
  /// after each test, so each starts with none.
  Future<void> clearRootFootprint() =>
      vm.sudo(['rm', '-rf', '--', kRootBackupsDir, '/etc/klabautermann']);

  setUp(() async {
    await clearRootFootprint();
    addTearDown(clearRootFootprint);
  });

  /// An engine connected as the password-sudo account with management on
  /// and its probe answered; admin mode on unless [admin] is false.
  Future<FixtureEngine> start(String name, {bool admin = true}) async {
    final engine = await vm.engine(name);
    manage(engine, [sudoServer]);
    await engine.connect(sudoServer, vm.hostKeys);
    await engine.subscribe(sudoServer, {SampleStream.identity});
    await hostProfile(engine, sudoServer);
    if (admin) {
      final (state, _) = await turnOnAdmin(engine, sudoServer, [
        await vm.sudoPassword(),
      ]);
      expect(state.phase, AdminModePhase.on);
    }
    return engine;
  }

  Future<EditContent> read(FixtureEngine engine, EditTarget target) async {
    final requestId = 'vm-edit-read-${reads++}';
    engine.send(
      ReadEditable(serverId: sudoServer, requestId: requestId, target: target),
    );
    final answer = await engine.until<EditRead>(
      (e) => e.requestId == requestId,
      actionWait,
    );
    return answer.result as EditContent;
  }

  EditFile edit(EditTarget target, EditContent read, String text) =>
      EditFile(sudoServer, target: target, text: text, baseSha256: read.sha256);

  /// The temp files an edit left in [directory].
  Future<String> leftovers(String directory) =>
      root('ls -A -- "$directory" | grep -F -- "$kEditTempInfix" || true');

  /// Seeds the root file: root:adm 0640, readable by the sudo account
  /// through an ACL entry, with an extended attribute (D67's case).
  Future<void> seedRootFile() async {
    addTearDown(() => vm.sudo(['rm', '-rf', '--', _editDir]));
    await root(
      'install -d -m 0755 "$_editDir" && '
      'printf "setting=seeded\\n" > "$_rootFile" && '
      'chown root:adm "$_rootFile" && chmod 0640 "$_rootFile" && '
      'setfacl -m "u:${vm.sudoUser}:r" "$_rootFile" && '
      'setfattr -n $_xattr -v fixture "$_rootFile"',
    );
  }

  test('an admin-mode edit of a root file keeps its owner, mode, ACL and '
      'xattr and backs it up as root, with the manifest a later connect '
      'verifies only in admin mode (D67, SAF-12, SAF-14)', () async {
    await seedRootFile();
    final engine = await start('vm-edit-root');
    const target = FileTarget(_rootFile);

    final content = await read(engine, target);
    expect(content.text, 'setting=seeded\n');
    expect(content.privileged, isTrue);

    final planned = await plan(
      engine,
      edit(target, content, 'setting=edited\n'),
    );
    final preview = planned.preview;
    expect(preview.requiredLevel, RequiredLevel.admin);
    expect(preview.runner.identity, 'root');
    expect(
      preview.steps,
      everyElement(
        isA<ShellStep>().having((s) => s.elevated, 'elevated', true),
      ),
    );
    expect(
      preview.hostWrites,
      containsAll([HostWriteRow.rootBackups, HostWriteRow.footprintManifest]),
    );
    expectSucceeded(await run(engine, planned));

    expect(await root('cat -- "$_rootFile"'), 'setting=edited\n');
    expect(
      (await root('stat -c "%U:%G %a" -- "$_rootFile"')).trim(),
      'root:adm 640',
    );
    expect(
      await root('getfacl -c -- "$_rootFile"'),
      contains('user:${vm.sudoUser}:r--'),
    );
    expect(
      await root('getfattr -n $_xattr --only-values -- "$_rootFile"'),
      'fixture',
    );
    expect(await leftovers(_editDir), isEmpty);

    // The backup: root's directory, 0700, holding the seeded text, and
    // the manifest that lists it.
    expect((await root('stat -c %a -- "$kRootBackupsDir"')).trim(), '700');
    final index = await root('cat -- "$kRootBackupsDir/index"');
    expect(index, contains('\t$_rootFile\n'));
    final hash = index.trim().split('\t')[1];
    expect(await root('cat -- "$kRootBackupsDir"/$hash-*'), 'setting=seeded\n');
    expect(
      await root('cat -- "$kRootManifestPath"'),
      contains(kRootBackupsDir),
    );

    // A new connect reads root's part only once admin mode is on.
    final later = await start('vm-edit-footprint', admin: false);
    // The connect's own verification may have come with the probe.
    final unchecked =
        later.seen.whereType<FootprintState>().firstOrNull ??
        await later.until<FootprintState>(
          (e) => e.serverId == sudoServer,
          _footprintWait,
        );
    expect(unchecked.rootUnchecked, isTrue);
    expect(
      unchecked.files.where((f) => f.scope == FootprintScope.root),
      isEmpty,
    );
    await turnOnAdmin(later, sudoServer, [await vm.sudoPassword()]);
    final checked = await later.until<FootprintState>(
      (e) => e.serverId == sudoServer && !e.rootUnchecked,
      _footprintWait,
    );
    expect(
      checked.files.where(
        (f) =>
            f.scope == FootprintScope.root &&
            f.row.kind == FootprintKind.backupDirectory,
      ),
      [
        isA<FootprintFile>()
            .having((f) => f.row.path, 'path', kRootBackupsDir)
            .having((f) => f.present, 'present', isTrue),
      ],
    );
    expect(checked.backups.where((b) => b.scope == FootprintScope.root), [
      isA<FootprintBackup>()
          .having((b) => b.entry.source, 'source', _rootFile)
          .having((b) => b.status, 'status', FootprintBackupStatus.intact),
    ]);
  });

  test('a unit file whose candidate systemd-analyze verify rejects is not '
      'replaced; one it accepts is (03 §8.5)', () async {
    const seeded = '[Service]\nType=oneshot\nExecStart=/bin/true\n';
    addTearDown(() => vm.sudo(['rm', '-f', '--', _unitFile]));
    await root(
      'printf "%s" "$seeded" > "$_unitFile" && chmod 0644 "$_unitFile"',
    );
    final engine = await start('vm-edit-unit');
    final profile = await hostProfile(engine, sudoServer);
    expect(
      profile.systemdVersion,
      greaterThanOrEqualTo(kVerifyAsUnitSystemd),
      reason: 'the runner image reads FILE:UNIT',
    );
    const target = FileTarget(_unitFile);

    final content = await read(engine, target);
    final rejected = await plan(
      engine,
      edit(target, content, '[Service]\nExecStart=relative-command\n'),
    );
    final verify = rejected.preview.steps.indexWhere(
      (s) => s is ShellStep && s.argv.first == 'systemd-analyze',
    );
    expect(verify, isNonNegative);
    expect(rejected.preview.warnings, isEmpty);
    expect(
      await run(engine, rejected),
      isA<ActionFinished>()
          .having((f) => f.outcome, 'outcome', ActionOutcome.failed)
          .having((f) => f.failedStep, 'failedStep', verify),
    );
    expect(await root('cat -- "$_unitFile"'), seeded);
    expect(await leftovers('/etc/systemd/system'), isEmpty);

    const accepted = '[Service]\nType=oneshot\nExecStart=/bin/echo edited\n';
    final current = await read(engine, target);
    expectSucceeded(
      await run(engine, await plan(engine, edit(target, current, accepted))),
    );
    expect(await root('cat -- "$_unitFile"'), accepted);
  });

  test('a root file changed between plan and run stays as changed '
      '(SAF-12)', () async {
    await seedRootFile();
    final engine = await start('vm-edit-conflict');
    const target = FileTarget(_rootFile);

    final content = await read(engine, target);
    final planned = await plan(
      engine,
      edit(target, content, 'setting=from-the-editor\n'),
    );
    await root('printf "other=1\\n" >> "$_rootFile"');

    expect(
      await run(engine, planned),
      isA<ActionFinished>()
          .having((f) => f.outcome, 'outcome', ActionOutcome.failed)
          .having(
            (f) => f.revalidation,
            'revalidation',
            RevalidationFailure.contentChanged,
          ),
    );
    expect(await root('cat -- "$_rootFile"'), 'setting=seeded\nother=1\n');
    expect(await leftovers(_editDir), isEmpty);
  });

  test("another account's crontab is replaced through crontab -u in admin "
      'mode, and backed up as root (JOB-06)', () async {
    final user = vm.limitedUser;
    final original = await root('crontab -u "$user" -l');
    addTearDown(
      () => vm.sudo([
        'sh',
        '-c',
        'printf "%s" "\$1" | crontab -u "\$2" -',
        'sh',
        original,
        user,
      ]),
    );
    final engine = await start('vm-edit-crontab');
    final target = CrontabTarget(user: user);

    final content = await read(engine, target);
    expect(content.text, original);
    expect(content.privileged, isTrue);

    final edited = '# edited by the runner-VM suite\n$original';
    final planned = await plan(engine, edit(target, content, edited));
    expect(planned.preview.targetName, 'crontab:$user');
    expect(planned.preview.requiredLevel, RequiredLevel.admin);
    expect(
      planned.preview.steps,
      everyElement(
        isA<ShellStep>().having((s) => s.elevated, 'elevated', true),
      ),
    );
    expectSucceeded(await run(engine, planned));

    expect(await root('crontab -u "$user" -l'), edited);
    expect(
      await root('cat -- "$kRootBackupsDir/index"'),
      contains('\tcrontab:$user\n'),
    );
  });
}
