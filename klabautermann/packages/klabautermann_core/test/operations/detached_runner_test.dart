// The detached runner's selection and launch (03 §7.17, M4 E17a): each
// row of the runner table and its refusals, the preview's logout warning,
// operation ids, the launch over the link or through elevation, and the
// sudo rules an elevated row needs (D66).
import 'dart:convert';
import 'dart:math';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/operations/detached_runner.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        DetachedRunner,
        OperationCommands,
        kOpIdLength,
        kRootOpsDir,
        validateOpId;
import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandException,
        RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _id = '0123456789abcdef';
const _userDir = '/home/deploy/.local/state/klabautermann/ops';

HostProfile _profile({
  bool? systemd = true,
  bool? linger,
  String? runtimeDir = '/run/user/1000',
  String? killUserProcesses,
  int uid = 1000,
}) => HostProfile(
  uid: uid,
  user: 'deploy',
  systemdDir: systemd,
  lingerEnabled: linger,
  xdgRuntimeDir: runtimeDir,
  killUserProcesses: killUserProcesses,
);

/// Answers each command with the first of [answers] whose key it
/// contains, otherwise success, and records it.
final class _Link extends TestLinkBase {
  _Link(this.answers);

  final Map<String, RemoteCommandResult> answers;
  final commands = <String>[];
  final stdins = <List<int>?>[];
  Object? failure;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    stdins.add(stdin);
    if (failure case final error?) throw error;
    for (final MapEntry(:key, :value) in answers.entries) {
      if (command.contains(key)) return value;
    }
    return const RemoteCommandResult(exitCode: 0);
  }
}

RemoteCommandResult _out(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout);

void main() {
  group('selection', () {
    DetachedRunner? runner(
      HostProfile profile, {
      RequiredLevel level = RequiredLevel.login,
      bool admin = false,
      bool sudoCoversRunners = true,
    }) => selectDetachedRunner(
      profile: profile,
      level: level,
      adminMode: admin,
      sudoCoversRunners: sudoCoversRunners,
    ).runner;

    test('root work runs as root, in admin mode only', () {
      expect(
        runner(_profile(), level: RequiredLevel.admin, admin: true),
        DetachedRunner.rootSystemd,
      );
      expect(
        runner(
          _profile(systemd: false),
          level: RequiredLevel.admin,
          admin: true,
        ),
        DetachedRunner.rootSetsid,
      );
      expect(
        selectDetachedRunner(
          profile: _profile(),
          level: RequiredLevel.admin,
          adminMode: false,
        ).refusal,
        DetachedRefusal.adminRequired,
      );
      expect(
        selectDetachedRunner(
          profile: _profile(),
          level: RequiredLevel.admin,
          adminMode: true,
          sudoCoversRunners: false,
        ).refusal,
        DetachedRefusal.sudoRightMissing,
        reason: 'a docker-scoped rule does not cover systemd-run',
      );
    });

    test('login work runs as the login user, admin mode only asking the '
        'system manager to start it', () {
      expect(runner(_profile(), admin: true), DetachedRunner.loginSystemdUid);
      expect(runner(_profile(linger: true)), DetachedRunner.loginSystemdUser);
      expect(runner(_profile(linger: false)), DetachedRunner.loginSetsid);
      expect(
        runner(_profile(linger: true, runtimeDir: null)),
        DetachedRunner.loginSetsid,
        reason: 'no user manager to reach',
      );
      expect(
        runner(_profile(systemd: false, linger: true), admin: true),
        DetachedRunner.loginSetsid,
      );
      expect(
        runner(_profile(linger: true), admin: true, sudoCoversRunners: false),
        DetachedRunner.loginSystemdUser,
        reason: 'placed as with admin mode off',
      );
      expect(
        runner(_profile(uid: 0, linger: false), admin: true),
        DetachedRunner.loginSetsid,
        reason: 'a root login never gets systemd-run --uid=0',
      );
    });

    test('unknown facts enable nothing, and setsid under '
        'KillUserProcesses warns', () {
      expect(
        runner(_profile(systemd: null, linger: null), admin: true),
        DetachedRunner.loginSetsid,
      );
      final warned = selectDetachedRunner(
        profile: _profile(killUserProcesses: 'yes'),
        level: RequiredLevel.login,
        adminMode: false,
      );
      expect(warned.runner, DetachedRunner.loginSetsid);
      expect(warned.mayDieAtLogout, isTrue);
      expect(
        selectDetachedRunner(
          profile: _profile(killUserProcesses: 'yes', linger: true),
          level: RequiredLevel.login,
          adminMode: false,
        ).mayDieAtLogout,
        isFalse,
      );
    });
  });

  test('operation ids are lowercase hex the record parser accepts', () {
    final id = newOpId(Random(7));
    expect(id, hasLength(kOpIdLength));
    expect(validateOpId(id), isNull);
    expect(newOpId(), isNot(newOpId()));
  });

  group('launch', () {
    Future<LaunchResult> launch(
      _Link link,
      DetachedRunner runner, {
      AdminSession? session,
    }) => launchDetached(
      link: link,
      runner: runner,
      uid: 1000,
      argv: const ['docker', 'compose', 'pull'],
      id: _id,
      session: session,
    );

    test('a login row resolves the user directory, then launches; setsid '
        'reports the wrapper\'s PID', () async {
      final link = _Link({
        'XDG_STATE_HOME': _out('$_userDir\n'),
        'klabautermann-launch': _out('4242\n'),
      });
      final started = await launch(link, DetachedRunner.loginSetsid);
      expect(started.failure, isNull);
      expect(started.dir, _userDir);
      expect(started.pid, 4242);
      expect(link.commands, hasLength(2));
      expect(link.commands.last, contains(_userDir));
      expect(link.commands.last, contains("'docker' 'compose' 'pull'"));
    });

    test('the systemd user row names its unit and reports no PID', () async {
      final link = _Link({'XDG_STATE_HOME': _out('$_userDir\n')});
      final started = await launch(link, DetachedRunner.loginSystemdUser);
      expect(started.failure, isNull);
      expect(started.pid, isNull);
      expect(link.commands.last, contains("'systemd-run' '--user'"));
      expect(link.commands.last, contains('klabautermann-op-$_id.service'));
    });

    test(
      'a root row records in the root directory, through elevation',
      () async {
        final link = _Link({});
        final session = AdminSession.test(
          ElevatedExecutor(link, const ElevationProbe(isRoot: true)),
          null,
        );
        final started = await launch(
          link,
          DetachedRunner.rootSystemd,
          session: session,
        );
        expect(started.failure, isNull);
        expect(started.dir, kRootOpsDir);
        expect(link.commands.single, contains(kRootOpsDir));
        expect(
          (await launch(_Link({}), DetachedRunner.rootSystemd)).failure,
          LaunchFailure.elevationRefused,
          reason: 'no admin session',
        );
      },
    );

    test('a failed launcher, an unresolved directory and a failed link '
        'are typed', () async {
      final refused = _Link({
        'XDG_STATE_HOME': _out('$_userDir\n'),
        'systemd-run': const RemoteCommandResult(exitCode: 1),
      });
      final notStarted = await launch(refused, DetachedRunner.loginSystemdUser);
      expect(notStarted.failure, LaunchFailure.failed);
      expect(notStarted.exitCode, 1);
      final relative = _Link({'XDG_STATE_HOME': _out('ops\n')});
      expect(
        (await launch(relative, DetachedRunner.loginSetsid)).failure,
        LaunchFailure.noDirectory,
      );
      final broken = _Link({})
        ..failure = const RemoteCommandException('channel closed');
      expect(
        (await launch(broken, DetachedRunner.loginSetsid)).failure,
        LaunchFailure.transport,
      );
    });
  });

  group('sudo rules (D66)', () {
    const sudo = 'Sudo version 1.9.16p2';
    const scoped =
        'User deploy may run the following commands on host:\n'
        '    (root) NOPASSWD: /usr/bin/docker\n';
    const everything =
        'User deploy may run the following commands on host:\n'
        '    (ALL : ALL) ALL\n';
    final withSudo = HostProfile(
      uid: 1000,
      user: 'deploy',
      sudoVersionLine: sudo,
    );

    AdminSession session(_Link link, String? password) => AdminSession.test(
      ElevatedExecutor(link, const ElevationProbe(sudoVersionLine: sudo)),
      password,
    );

    test('each elevated row names the program its launch elevates', () {
      for (final runner in DetachedRunner.values) {
        final program = elevatedProgram(runner);
        if (!runner.elevated) {
          expect(program, isNull, reason: '$runner');
          continue;
        }
        final launch = OperationCommands.detachedLaunch(
          runner,
          dir: runner.runsAsRoot ? kRootOpsDir : _userDir,
          id: _id,
          uid: 1000,
          argv: const ['true'],
        );
        expect(launch.first, program, reason: '$runner');
      }
    });

    test('the listing decides, read with the password on stdin', () async {
      final link = _Link({'sudo': _out(scoped)});
      expect(
        await sudoAllowsProgram(
          link: link,
          session: session(link, 'hunter2'),
          profile: withSudo,
          program: 'systemd-run',
        ),
        isFalse,
      );
      expect(link.commands.single, "LC_ALL=C sudo -S -p '' -l");
      expect(utf8.decode(link.stdins.single!), 'hunter2\n');

      final open = _Link({'sudo': _out(everything)});
      expect(
        await sudoAllowsProgram(
          link: open,
          session: session(open, null),
          profile: withSudo,
          program: 'sh',
        ),
        isTrue,
      );
      expect(
        open.commands.single,
        'LC_ALL=C sudo -n -l',
        reason: 'no password',
      );
    });

    test('an unreadable listing, a failed link, a root login and no '
        'sudo refuse nothing', () async {
      final refused = _Link({
        'sudo': const RemoteCommandResult(
          exitCode: 1,
          stderr: 'sudo: a password is required\n',
        ),
      });
      expect(
        await sudoAllowsProgram(
          link: refused,
          session: session(refused, null),
          profile: withSudo,
          program: 'systemd-run',
        ),
        isTrue,
      );
      final broken = _Link({})
        ..failure = const RemoteCommandException('channel closed');
      expect(
        await sudoAllowsProgram(
          link: broken,
          session: session(broken, null),
          profile: withSudo,
          program: 'systemd-run',
        ),
        isTrue,
        reason: 'a link that fails reads no listing',
      );

      for (final profile in [
        HostProfile(uid: 0, user: 'root', sudoVersionLine: sudo),
        HostProfile(uid: 1000, user: 'deploy'),
      ]) {
        final link = _Link({'sudo': _out(scoped)});
        expect(
          await sudoAllowsProgram(
            link: link,
            session: session(link, null),
            profile: profile,
            program: 'systemd-run',
          ),
          isTrue,
        );
        expect(link.commands, isEmpty);
      }
    });
  });
}
