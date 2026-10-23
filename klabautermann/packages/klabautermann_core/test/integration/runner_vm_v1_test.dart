// The v1 host rows on the GitHub-hosted Ubuntu runner (M5 plan M28;
// SVC-05 to SVC-10, LOG-06, LOG-08, LOG-09, JOB-04, JOB-08, JOB-19): unit
// enable, disable, mask, unmask and reset-failed through elevation, with
// the protected ssh.service behind its typed name; the linger account's
// own service and timer run through `systemctl --user`; a unit's file and
// resources; the journal's current boot and a `-g` search; a rotated
// `.gz` under /var/log listed and read; anacron's jobs where the image
// has anacron; and a cron line run now, the login user's own and another
// account's through elevation.
//
// Each test seeds what it acts on and removes it again; runner_vm.sh
// removes the system unit and the rotated log too should a run end
// part-way, and the linger account's units go with the account. It
// starts the leg and runs these one at a time; without it they skip.
@Tags(['runner-vm'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/fixture.dart';
import 'support/runner_vm.dart';

/// The system unit the verb test enables, masks and fails.
const _v1Service = 'klabautermann-vm-v1.service';
const _unitDir = '/etc/systemd/system';

/// The rotated log the LOG-08 test lists and reads.
const _rotatedLog = '/var/log/klabautermann-vm.log.1.gz';

/// The linger account's own units, in its `systemctl --user` directory.
const _userService = 'klabautermann-vm-user.service';
const _userTimer = 'klabautermann-vm-user.timer';

/// What the user service appends a line to, in the linger account's home.
const _userMarker = 'klabautermann-vm-user.ran';

/// Covers journald writing the markers before a read finds them.
const _journalWait = Duration(seconds: 20);

void main() {
  final vm = RunnerVm.fromEnvironment();
  if (vm == null) {
    test('the runner-VM v1 host suite', () {}, skip: runnerVmSkipReason);
    return;
  }

  var queries = 0;

  Future<String> root(String script) => vm.sudo(['sh', '-c', script]);

  /// An engine with management on for the accounts the suite uses,
  /// connected to [servers] with their probes answered.
  Future<FixtureEngine> managed(String name, List<String> servers) async {
    final engine = await vm.engine(name);
    manage(engine, [sudoServer, journalServer, lingerServer]);
    for (final server in servers) {
      await engine.connect(server, vm.hostKeys);
      await engine.subscribe(server, {SampleStream.identity});
      await hostProfile(engine, server);
    }
    return engine;
  }

  Future<String> show(String unit, String property) async =>
      (await root('systemctl show -P $property -- $unit')).trim();

  Future<UnitPayload> unitQuery(
    FixtureEngine engine,
    String serverId,
    UnitQuerySpec query,
  ) async {
    final requestId = 'v1-unit-${queries++}';
    engine.send(
      UnitQuery(serverId: serverId, requestId: requestId, query: query),
    );
    return (await engine.until<UnitQueryResult>(
      (e) => e.requestId == requestId,
      actionWait,
    )).payload;
  }

  Future<HostPayload> hostQuery(
    FixtureEngine engine,
    String serverId,
    HostQuerySpec query,
  ) async {
    final queryId = 'v1-host-${queries++}';
    engine.send(HostQuery(serverId: serverId, queryId: queryId, query: query));
    return (await engine.until<HostResult>(
      (e) => e.queryId == queryId,
      actionWait,
    )).payload;
  }

  /// A window of [source] on [serverId]: its records and how it ended.
  Future<(List<LogRecord>, LogStreamEnded)> window(
    FixtureEngine engine,
    String serverId,
    LogSource source, {
    int size = 500,
  }) async {
    final streamId = 'v1-log-${queries++}';
    final mark = engine.seen.length;
    engine.send(
      OpenLogStream(
        streamId: streamId,
        spec: LogStreamSpec(
          serverId: serverId,
          source: source,
          window: size,
          follow: false,
        ),
      ),
    );
    final ended = await engine.until<LogStreamState>(
      (e) => e.streamId == streamId && e.status is LogStreamEnded,
    );
    return (
      [
        for (final e in engine.seen.skip(mark))
          if (e is LogBatch && e.streamId == streamId) ...e.records,
      ],
      ended.status as LogStreamEnded,
    );
  }

  group('units (SVC-05, SVC-06)', () {
    setUp(() async {
      addTearDown(
        () => root(
          'systemctl unmask -- $_v1Service; '
          'systemctl disable -- $_v1Service; '
          'rm -f -- $_unitDir/$_v1Service; '
          'systemctl daemon-reload; '
          'systemctl reset-failed -- $_v1Service 2>/dev/null; true',
        ),
      );
      await root(
        "printf '%s\\n' '[Unit]' 'Description=Klabautermann runner-VM v1' "
        "'[Service]' 'Type=oneshot' 'ExecStart=/bin/false' "
        "'[Install]' 'WantedBy=multi-user.target' "
        '> $_unitDir/$_v1Service && systemctl daemon-reload',
      );
    });

    test('enable, disable, mask, unmask and reset-failed run as root in '
        'admin mode', () async {
      final engine = await managed('v1-verbs', [sudoServer]);
      await turnOnAdmin(engine, sudoServer, [await vm.sudoPassword()]);

      Future<void> act(SystemctlVerb verb) async {
        final planned = await plan(
          engine,
          UnitAction(sudoServer, unit: _v1Service, verb: verb),
        );
        final step = planned.preview.steps.single as ShellStep;
        expect(step.argv, containsAllInOrder([verb.wireName, _v1Service]));
        expect(step.elevated, isTrue);
        expect(planned.preview.requiredLevel, RequiredLevel.admin);
        expectSucceeded(await run(engine, planned));
      }

      await act(SystemctlVerb.enable);
      expect(await show(_v1Service, 'UnitFileState'), 'enabled');
      await act(SystemctlVerb.disable);
      expect(await show(_v1Service, 'UnitFileState'), 'disabled');
      await act(SystemctlVerb.mask);
      expect(await show(_v1Service, 'UnitFileState'), 'masked');
      await act(SystemctlVerb.unmask);
      expect(await show(_v1Service, 'UnitFileState'), 'disabled');

      // ExecStart=/bin/false leaves the unit failed; reset-failed clears it.
      await root('systemctl start -- $_v1Service || true');
      expect(await show(_v1Service, 'ActiveState'), 'failed');
      await act(SystemctlVerb.resetFailed);
      expect(await show(_v1Service, 'ActiveState'), 'inactive');
    });

    test('disabling or masking the protected ssh.service needs its typed '
        'name', () async {
      final engine = await managed('v1-protected', [sudoServer]);
      await turnOnAdmin(engine, sudoServer, [await vm.sudoPassword()]);

      for (final verb in [SystemctlVerb.disable, SystemctlVerb.mask]) {
        final planned = await plan(
          engine,
          UnitAction(sudoServer, unit: 'ssh.service', verb: verb),
        );
        expect(planned.preview.protected, ProtectedReason.sessionPath);
        expect(planned.preview.requiredTier, ConfirmationTier.typedPhrase);
        // Never confirmed: the runner's own sshd stays as it is.
        final refused =
            await run(
                  engine,
                  planned,
                  confirmation: const ActionConfirmation(
                    tier: ConfirmationTier.acknowledge,
                  ),
                )
                as ActionRefused;
        expect(refused.reason, ActionRefusalReason.confirmationMismatch);
      }
      expect(await show('ssh.service', 'UnitFileState'), isNot('masked'));
    });
  });

  test("the linger account's own service and timer run through systemctl "
      '--user, never sudo (SVC-09, JOB-08)', () async {
    final user = vm.lingerUser;
    await root(
      'home=\$(getent passwd $user | cut -d : -f 6) && '
      'install -d -o $user -g $user "\$home/.config" '
      '"\$home/.config/systemd" "\$home/.config/systemd/user" && '
      "printf '%s\\n' '[Service]' 'Type=oneshot' "
      "'ExecStart=/bin/sh -c \"echo ran >> %h/$_userMarker\"' "
      '> "\$home/.config/systemd/user/$_userService" && '
      "printf '%s\\n' '[Timer]' 'OnCalendar=*-01-01 04:05:06' "
      "'Unit=$_userService' "
      '> "\$home/.config/systemd/user/$_userTimer" && '
      'chown $user:$user "\$home/.config/systemd/user/$_userService" '
      '"\$home/.config/systemd/user/$_userTimer"',
    );
    await vm.ssh(user, 'systemctl --user daemon-reload');
    final engine = await managed('v1-user', [lingerServer]);

    final started = await plan(
      engine,
      const UnitAction(
        lingerServer,
        unit: _userService,
        verb: SystemctlVerb.start,
        scope: UnitScope.user,
      ),
    );
    final step = started.preview.steps.single as ShellStep;
    expect(step.argv, contains('--user'));
    expect(step.elevated, isFalse);
    expect(started.preview.requiredLevel, RequiredLevel.login);
    expectSucceeded(await run(engine, started));

    final timer = await plan(
      engine,
      const StartTimer(lingerServer, timer: _userTimer, scope: UnitScope.user),
    );
    expect((timer.preview.steps.single as ShellStep).elevated, isFalse);
    expectSucceeded(await run(engine, timer));

    expect(
      (await vm.ssh(user, 'cat -- "\$HOME/$_userMarker"')).trim().split('\n'),
      ['ran', 'ran'],
    );

    final file = await unitQuery(
      engine,
      lingerServer,
      const UnitFileQuery(_userService, scope: UnitScope.user),
    );
    expect(
      (file as UnitFilePayload).text.map((v) => v.display).join('\n'),
      contains(_userMarker),
    );
  });

  test("a unit's file and resources read as the login user (SVC-07, "
      'SVC-08)', () async {
    final engine = await managed('v1-reads', [sudoServer]);

    final file = await unitQuery(
      engine,
      sudoServer,
      UnitFileQuery(vm.testService),
    );
    final text = (file as UnitFilePayload).text.map((v) => v.display);
    expect(text.join('\n'), contains('ExecStart=/bin/sleep infinity'));
    expect(text.join('\n'), contains('# $_unitDir/${vm.testService}'));

    final resources = await unitQuery(
      engine,
      sudoServer,
      UnitResourcesQuery(vm.testService),
    );
    final read = (resources as UnitResourcesPayload).resources;
    expect(read.mainPid, int.parse(await show(vm.testService, 'MainPID')));
    expect(read.tasks, greaterThanOrEqualTo(1));
    expect(read.activeSince, isNotNull);
  });

  test("the journal lists this boot, and -g matches only the records it "
      'names (LOG-06, LOG-09)', () async {
    final engine = await managed('v1-journal', [journalServer]);

    // The current boot, last at offset 0; an image that kept its build's
    // journal lists that boot before it.
    final boots = await hostQuery(engine, journalServer, const BootsQuery());
    final current = (boots as JournalBoots).boots.last;
    expect(current.offset, 0);
    expect(
      current.id,
      (await root(
        'cat /proc/sys/kernel/random/boot_id',
      )).trim().replaceAll('-', ''),
    );

    final tag = 'klabautermann-v1-$pid';
    await vm.logMarkers(vm.journalUser, tag, [1, 2, 3]);
    final source = JournalLogSource(identifier: tag, grep: 'marker 2');
    var (records, end) = await window(engine, journalServer, source);
    final deadline = DateTime.now().add(_journalWait);
    while (records.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      (records, end) = await window(engine, journalServer, source);
    }
    expect(
      [for (final r in records) (r as JournalRecord).message],
      ['marker 2'],
    );
    expect(end.reason, isNot(LogStreamEndReason.searchUnsupported));
  });

  test('a rotated .gz under /var/log is listed and read through zcat '
      '(LOG-08)', () async {
    addTearDown(() => vm.sudo(['rm', '-f', '--', _rotatedLog]));
    await root(
      "printf 'rotated one\\nrotated two\\n' | gzip -c > $_rotatedLog && "
      'chmod 0644 $_rotatedLog',
    );
    final engine = await managed('v1-rotated', [sudoServer]);

    final listed = await hostQuery(engine, sudoServer, const VarLogQuery());
    final entry = (listed as VarLogFiles).files.singleWhere(
      (f) => f.path == _rotatedLog,
    );
    expect(entry.readable, isTrue);
    expect(entry.compression, LogCompression.gzip);

    final (records, _) = await window(
      engine,
      sudoServer,
      const FileLogSource(_rotatedLog, compressed: true),
      size: 10,
    );
    expect(
      [for (final r in records) (r as FileRecord).text],
      ['rotated one', 'rotated two'],
    );
  });

  test("anacron's jobs are read where the image has anacron, and its "
      'absence is said otherwise (JOB-04)', () async {
    final engine = await managed('v1-anacron', [sudoServer]);
    final requestId = 'v1-anacron';
    engine.send(
      JobHistoryQuery(
        serverId: sudoServer,
        requestId: requestId,
        query: const AnacronQuery(),
      ),
    );
    final payload = (await engine.until<JobHistoryResult>(
      (e) => e.requestId == requestId,
      actionWait,
    )).payload;

    final installed = File('/etc/anacrontab').existsSync();
    if (!installed) {
      expect(
        payload,
        isA<JobHistoryFailed>().having(
          (f) => f.failure,
          'failure',
          JobHistoryFailure.notInstalled,
        ),
      );
      return;
    }
    final identifiers = RegExp(r'^\s*[0-9@a-z]+\s+\d+\s+(\S+)', multiLine: true)
        .allMatches(File('/etc/anacrontab').readAsStringSync())
        .map((m) => m[1]!)
        .toSet();
    expect(
      (payload as AnacronPayload).jobs.map((j) => j.identifier).toSet(),
      identifiers,
    );
  });

  group('run a cron line now (JOB-19)', () {
    /// Replaces [user]'s crontab with [line] and puts the original back
    /// after the test.
    Future<void> seedCrontab(String user, String line) async {
      final original = await root('crontab -u $user -l');
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
      await vm.sudo([
        'sh',
        '-c',
        'printf "%s\\n" "\$1" | crontab -u "\$2" -',
        'sh',
        line,
        user,
      ]);
    }

    test("the login user's own line runs over the link", () async {
      const line = '5 4 1 1 * echo own-line-ran; id -un';
      await seedCrontab(vm.sudoUser, line);
      final engine = await managed('v1-cron-own', [sudoServer]);

      final planned = await plan(
        engine,
        const RunCronJob(sudoServer, source: kOwnCrontabSource, raw: line),
      );
      expect(planned.preview.requiredLevel, RequiredLevel.login);
      expect((planned.preview.steps.single as ShellStep).elevated, isFalse);
      final finished = await run(engine, planned) as ActionFinished;
      expectSucceeded(finished);
      expect(finished.output?.stdout, 'own-line-ran\n${vm.sudoUser}\n');
    });

    test("another account's line runs as that account through "
        'elevation', () async {
      const line = '5 4 1 1 * id -un';
      final other = vm.limitedUser;
      await seedCrontab(other, line);
      final engine = await managed('v1-cron-other', [sudoServer]);
      final intent = RunCronJob(
        sudoServer,
        source: userCrontabSource(other),
        raw: line,
      );

      expect(
        await planAnswer(engine, intent),
        isA<ActionRefused>().having(
          (r) => r.reason,
          'reason',
          ActionRefusalReason.adminRequired,
        ),
      );

      await turnOnAdmin(engine, sudoServer, [await vm.sudoPassword()]);
      final planned = await plan(engine, intent);
      expect(planned.preview.requiredLevel, RequiredLevel.admin);
      expect(planned.preview.runner.identity, other);
      expect((planned.preview.steps.single as ShellStep).elevated, isTrue);
      final finished = await run(engine, planned) as ActionFinished;
      expectSucceeded(finished);
      expect(finished.output?.stdout, '$other\n');
    });
  });
}
