// HostQueries against a link whose one-shot runs the test answers (03
// §7.6): each query runs its validated command and answers once, with
// the parsed rows or why it read none.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/host_queries.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show
        RemoteCommandException,
        RemoteCommandResult,
        SecretRedactor,
        quoteShellWord;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _boot = '0123456789abcdef0123456789abcdef';

/// Answers each run with [answer]'s result, or throws what it throws.
final class _RunLink extends TestLinkBase {
  _RunLink(this.answer);

  final RemoteCommandResult Function(String command) answer;
  final commands = <String>[];

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    return answer(command);
  }
}

RemoteCommandResult _ok(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout, stderr: '');

void main() {
  late List<EngineEvent> events;
  _RunLink? link;
  int? systemd;

  HostQueries queries() => HostQueries(
    linkFor: (_) => link,
    systemdVersionOf: (_) => systemd,
    emit: events.add,
  );

  Future<HostResult> ask(HostQuerySpec query) async {
    await queries().query(
      HostQuery(serverId: 'srv-1', queryId: 'q-1', query: query),
    );
    final result = events.single as HostResult;
    expect((result.serverId, result.queryId), ('srv-1', 'q-1'));
    return result;
  }

  setUp(() {
    events = [];
    link = null;
    systemd = null;
  });

  test('the files under /var/log come back sorted, with warnings', () async {
    link = _RunLink(
      (_) => _ok(
        '1 120 1760000000 /var/log/syslog\n'
        '0 4096 1760000000 /var/log/auth.log.2.gz\n'
        'garbage\n',
      ),
    );

    final result = await ask(const VarLogQuery());

    expect(
      link!.commands.single,
      HostCommands.commandLine(HostCommands.logFiles(), quote: quoteShellWord),
    );
    final files = (result.payload as VarLogFiles).files;
    expect(files.map((f) => f.path), [
      '/var/log/auth.log.2.gz',
      '/var/log/syslog',
    ]);
    expect(files.first.readable, isFalse);
    expect(files.first.compression, LogCompression.gzip);
    expect(result.warnings, ['log files: row skipped']);
  });

  test('boots read as JSON from systemd 251, as text before and when the '
      'version is unknown', () async {
    final json =
        '[{"index":0,"boot_id":"$_boot",'
        '"first_entry":1760000000000000,"last_entry":1760003600000000}]';
    const text =
        '  0 $_boot Thu 2025-10-09 08:53:20 UTC Thu 2025-10-09 09:53:20 UTC\n';
    link = _RunLink((command) => _ok(command.contains("'json'") ? json : text));

    for (final version in [251, 250, null]) {
      events.clear();
      systemd = version;
      final boots =
          ((await ask(const BootsQuery())).payload as JournalBoots).boots;
      expect(boots.single.id, _boot, reason: '$version');
      expect(boots.single.offset, 0);
      expect(boots.single.firstEntry, isNotNull, reason: '$version');
    }
    expect(link!.commands.map((c) => c.contains("'json'")), [
      true,
      false,
      false,
    ]);
  });

  group('process detail (PRC-04, PRC-05)', () {
    const read =
        '== cwd\n/srv/app\n== status\nThreads:\t3\n'
        '== cgroup\n0::/system.slice/app.service\n== limits\n'
        '== fds\n12\n== environ\nHOME=/srv\nDB_PASSWORD=hunter2\n';

    test('answers the details with each environment value masked by '
        'key', () async {
      link = _RunLink((_) => _ok(read));
      final payload =
          (await ask(
                const ProcessDetailQuery(pid: 42, startTicks: 900),
              )).payload
              as ProcessDetails;
      expect(payload.detail.cwd, '/srv/app');
      expect(payload.detail.attribution.unit, 'app.service');
      expect(payload.detail.environment, isNull);
      final env = {for (final e in payload.environment!) e.name: e.value};
      expect(env['HOME']!.isMasked, isFalse);
      expect(env['DB_PASSWORD']!.display, MaskedValue.maskToken);
      expect(env['DB_PASSWORD']!.reveal(), 'hunter2');
      expect(
        link!.commands.single,
        HostCommands.commandLine(
          HostCommands.processDetail(42, 900),
          quote: quoteShellWord,
        ),
      );
    });

    test('a process that ended or whose PID was reused says so', () async {
      final ends = <ProcessEnd>[];
      for (final code in [kGuardedKillGone, kProcessDetailReused]) {
        events.clear();
        link = _RunLink(
          (_) => RemoteCommandResult(exitCode: code, stdout: '', stderr: ''),
        );
        final payload = (await ask(
          const ProcessDetailQuery(pid: 42, startTicks: 900),
        )).payload;
        ends.add((payload as ProcessEnded).end);
      }
      expect(ends, [ProcessEnd.gone, ProcessEnd.reused]);

      events.clear();
      link = _RunLink((_) => _ok(read));
      final invalid = (await ask(
        const ProcessDetailQuery(pid: 0, startTicks: 1),
      )).payload;
      expect((invalid as HostQueryFailed).failure, HostQueryFailure.failed);
      expect(link!.commands, isEmpty);
    });
  });

  test('the out-of-memory read answers the kills', () async {
    link = _RunLink(
      (_) => _ok(
        '$kOomVmstatMarker 1\n$kOomSourceMarker journal\n'
        '1729912345.123460 h kernel: Out of memory: Killed process 4321 '
        '(stress) total-vm:2kB, anon-rss:1kB\n$kOomReadMarker 800\n',
      ),
    );
    final read = ((await ask(const OomKillsQuery())).payload as OomKills).read;
    expect(read.killsSinceBoot, 1);
    expect(read.kills.single.command, 'stress');
    expect(
      link!.commands.single,
      HostCommands.commandLine(HostCommands.oomKills(), quote: quoteShellWord),
    );

    events.clear();
    link = _RunLink((_) => _ok('sh: awk: not found\n'));
    final failed =
        (await ask(const OomKillsQuery())).payload as HostQueryFailed;
    expect(failed.failure, HostQueryFailure.failed);
  });

  test('boot ends key by boot ID, and the kernels say whether a reboot '
      'loads a newer one', () async {
    link = _RunLink(
      (command) => _ok(
        command.contains('list-boots')
            ? '$_boot unclean\n'
            : '6.1.0-9-amd64\n$kKernelsMarker\n6.1.0-13-amd64\n'
                  '6.1.0-9-amd64\n',
      ),
    );

    final ends = (await ask(const BootEndsQuery())).payload as BootEnds;
    expect(ends.ends, {_boot: BootEnd.unclean});
    expect(
      link!.commands.single,
      HostCommands.commandLine(HostCommands.bootEnds(), quote: quoteShellWord),
    );

    events.clear();
    final kernels = (await ask(const KernelsQuery())).payload as Kernels;
    expect(kernels.check.state, KernelCheckState.newerInstalled);
    expect(kernels.check.newest, '6.1.0-13-amd64');
  });

  test('the mounts read answers findmnt\'s JSON too', () async {
    link = _RunLink(
      (_) => _ok(
        '$kMountsFindmntMarker\n'
        '{"filesystems": [{"target": "/", "source": "/dev/sda1", '
        '"fstype": "ext4", "options": "ro,relatime"}]}\n'
        '$kMountsSwapsMarker\nFilename Type Size Used Priority\n'
        '/dev/sda3 partition 4096 0 -2\n',
      ),
    );
    final read = ((await ask(const MountsQuery())).payload as Mounts).read;
    expect(read.mountAt('/')!.readOnly, isTrue);
    expect(read.swaps.single.kind, SwapKind.partition);
  });

  test('the mounts read answers each mount and swap device', () async {
    link = _RunLink(
      (_) => _ok(
        '$kMountsProcMarker\n/dev/sda1 / ext4 ro,relatime 0 0\n'
        '$kMountsSwapsMarker\nFilename Type Size Used Priority\n'
        '/swapfile file 1024 0 -2\n',
      ),
    );
    final read = ((await ask(const MountsQuery())).payload as Mounts).read;
    expect(read.mountAt('/')!.readOnly, isTrue);
    expect(read.swaps.single.sizeBytes, 1024 * 1024);
    expect(
      link!.commands.single,
      HostCommands.commandLine(HostCommands.mounts(), quote: quoteShellWord),
    );

    events.clear();
    link = _RunLink((_) => _ok('sh: cat: not found\n'));
    final failed = (await ask(const MountsQuery())).payload as HostQueryFailed;
    expect(failed.failure, HostQueryFailure.failed);
  });

  test('a kernel read that printed something else fails', () async {
    link = _RunLink((_) => _ok('sh: uname: not found\n'));
    final payload =
        (await ask(const KernelsQuery())).payload as HostQueryFailed;
    expect(payload.failure, HostQueryFailure.failed);
  });

  test('a diagnostic bundle comes from the samplers, and reads as no '
      'link where nothing samples the server', () async {
    link = _RunLink((_) => fail('the bundle runs no command'));
    const bundle = DiagnosticBundle([
      DiagnosticSection(collector: 'core', status: 'ok', text: 'cpu 1'),
    ]);
    final asked = <String>[];
    await HostQueries(
      linkFor: (_) => link,
      systemdVersionOf: (_) => null,
      emit: events.add,
      readDiagnostics: (serverId) async {
        asked.add(serverId);
        return bundle;
      },
    ).query(
      const HostQuery(
        serverId: 'srv-1',
        queryId: 'q-1',
        query: DiagnosticBundleQuery(),
      ),
    );
    expect(asked, ['srv-1']);
    expect((events.single as HostResult).payload, same(bundle));

    events.clear();
    final failed = (await ask(const DiagnosticBundleQuery())).payload;
    expect((failed as HostQueryFailed).failure, HostQueryFailure.noLink);
  });

  group('a diagnostic bundle crosses with its command lines masked by '
      "8.9's argument rules (UIA-01)", () {
    Future<DiagnosticBundle> read(DiagnosticBundle raw) async {
      link = _RunLink((_) => fail('the bundle runs no command'));
      await HostQueries(
        linkFor: (_) => link,
        systemdVersionOf: (_) => null,
        emit: events.add,
        readDiagnostics: (_) async => raw,
      ).query(
        const HostQuery(
          serverId: 'srv-1',
          queryId: 'q-1',
          query: DiagnosticBundleQuery(),
        ),
      );
      return (events.single as HostResult).payload as DiagnosticBundle;
    }

    /// The bundle's text as the export sheet's redactor leaves it.
    String exported(DiagnosticBundle bundle) => [
      for (final section in bundle.sections)
        ...section.text.split('\n').map(SecretRedactor().redact),
    ].join('\n');

    String cmdline(int pid, List<String> argv) =>
        '==> $pid/cmdline <==\n${argv.map((a) => '$a\x1f').join()}\n';

    test('procs: each /proc cmdline record, read as its arguments', () async {
      final procs = [
        '== meta ==\ntotal=7\nselection=all\n== rows ==',
        '1234 S 1 0 0 0 100 0 2048 mysql',
        '== cmdline ==',
        cmdline(1234, ['mysql', '-uroot', '-phunter2', 'db']),
        cmdline(1235, ['curl', '-u', 'admin:hunter2', 'https://x']),
        cmdline(1236, ['redis-cli', '-a', 'hunter2']),
        cmdline(1237, ['app', '--password', 'hunter2']),
        cmdline(1238, ['app', '--password=hunter2']),
        cmdline(1239, ['psql', 'postgres://bob:hunter2@db/x']),
        cmdline(1240, ['sshpass', '-p', 'hunter2', 'ssh', '-p', '22', 'h']),
        cmdline(1241, ['docker', 'login', '-p', 'hunter2', 'reg']),
        // An argument that holds a newline stays one argument.
        cmdline(1242, ['sh', '-c', 'true\nPGPASSWORD=hunter2 pg_dump']),
        cmdline(1243, ['app', '--password', 'hun\nter2', 'x']),
      ].join('\n');
      final bundle = await read(
        DiagnosticBundle(
          [
            const DiagnosticSection(
              collector: 'core',
              status: 'ok',
              text: 'cpu 1',
            ),
            DiagnosticSection(collector: 'procs', status: 'ok', text: procs),
          ],
          missing: const ['gpu'],
        ),
      );

      expect(bundle.missing, ['gpu']);
      expect(bundle.sections.first.text, 'cpu 1');
      final section = bundle.sections.last;
      expect((section.collector, section.status), ('procs', 'ok'));
      expect(
        section.text,
        [
          '== meta ==\ntotal=7\nselection=all\n== rows ==',
          '1234 S 1 0 0 0 100 0 2048 mysql',
          '== cmdline ==',
          cmdline(1234, ['mysql', '-uroot', '-p********', 'db']),
          cmdline(1235, ['curl', '-u', 'admin:********', 'https://x']),
          cmdline(1236, ['redis-cli', '-a', '********']),
          cmdline(1237, ['app', '--password', '********']),
          cmdline(1238, ['app', '--password=********']),
          cmdline(1239, ['psql', 'postgres://bob:********@db/x']),
          cmdline(1240, ['sshpass', '-p', '********', 'ssh', '-p', '22', 'h']),
          cmdline(1241, ['docker', 'login', '-p', '********', 'reg']),
          cmdline(1242, ['sh', '-c', 'true\nPGPASSWORD=******** pg_dump']),
          cmdline(1243, ['app', '--password', '********', 'x']),
        ].join('\n'),
      );
      expect(exported(bundle), isNot(contains('hunter2')));
      expect(exported(bundle), isNot(contains('ter2')));
    });

    test('procs: the rows of a ps fallback, and a reply without record '
        'headers', () async {
      for (final marker in ['== ps ==', '== ps_w ==']) {
        events.clear();
        final bundle = await read(
          DiagnosticBundle([
            DiagnosticSection(
              collector: 'procs',
              status: 'ok',
              text:
                  '== meta ==\ntotal=2\n== rows ==\n== cmdline ==\n$marker\n'
                  '  PID  PPID USER     STAT   RSS COMMAND\n'
                  ' 1234     1 root     S     2048 mysql -uroot -phunter2 db\n'
                  ' 1235     1 root     S     2048 curl -u admin:hunter2 '
                  'https://x\n'
                  ' 1236     1 root     S     2048 redis-cli -a hunter2\n'
                  ' 1237     1 root     S     2048 app --password hunter2',
            ),
          ]),
        );
        expect(
          bundle.sections.single.text,
          '== meta ==\ntotal=2\n== rows ==\n== cmdline ==\n$marker\n'
          '  PID  PPID USER     STAT   RSS COMMAND\n'
          ' 1234     1 root     S     2048 mysql -uroot -p******** db\n'
          ' 1235     1 root     S     2048 curl -u admin:******** '
          'https://x\n'
          ' 1236     1 root     S     2048 redis-cli -a ********\n'
          ' 1237     1 root     S     2048 app --password ********',
        );
      }

      // `head` prints no header for a single file, and a host may send
      // anything: a first word is never trusted to be a program.
      events.clear();
      final bundle = await read(
        const DiagnosticBundle([
          DiagnosticSection(
            collector: 'procs',
            status: 'ok',
            text: '== cmdline ==\nPGPASSWORD=hunter2\x1fpg_dump\x1f',
          ),
          DiagnosticSection(
            collector: 'procs',
            status: 'error',
            text: 'mysql -phunter2',
          ),
        ]),
      );
      expect(
        bundle.sections.first.text,
        '== cmdline ==\nPGPASSWORD=********\x1fpg_dump\x1f',
      );
      expect(bundle.sections.last.text, 'mysql -p********');

      // Arguments are read at their separators wherever they stand.
      events.clear();
      final odd = await read(
        const DiagnosticBundle([
          DiagnosticSection(
            collector: 'procs',
            status: 'ok',
            text: '== cmdline ==\n== ps ==\nmysql\x1f-phunter2\x1f',
          ),
          DiagnosticSection(
            collector: 'procs',
            status: 'ok',
            text: 'mysql\x1f-phunter2\x1f',
          ),
          DiagnosticSection(
            collector: 'cron',
            status: 'ok',
            text: 'mysql\x1f-phunter2\x1f',
          ),
        ]),
      );
      expect(
        [for (final section in odd.sections) section.text],
        [
          '== cmdline ==\n== ps ==\nmysql\x1f-p********\x1f',
          'mysql\x1f-p********\x1f',
          'mysql\x1f-p********\x1f',
        ],
      );
    });

    test('procs: a ps block that does not follow the cmdline line at '
        'once is never masked less', () async {
      const rows =
          ' 1234     1 root     S     2048 mysql -uroot -phunter2 db\n'
          ' 1236     1 root     S     2048 redis-cli -a hunter2\n'
          ' 1237     1 root     S     2048 app --password hunter2\n'
          ' 1238     1 root     S     2048 docker login -p hunter2 reg\n'
          ' 1239     1 root     S     2048 sh -c "true" PGPASSWORD=hunter2';
      const masked =
          ' 1234     1 root     S     2048 mysql -uroot -p******** db\n'
          ' 1236     1 root     S     2048 redis-cli -a ********\n'
          ' 1237     1 root     S     2048 app --password ********\n'
          ' 1238     1 root     S     2048 docker login -p ******** reg\n'
          ' 1239     1 root     S     2048 sh -c "true" PGPASSWORD=********';

      // Blank lines between the two: still rows, masked row by row.
      for (final between in ['\n', '\n \n\t\n']) {
        events.clear();
        final bundle = await read(
          DiagnosticBundle([
            DiagnosticSection(
              collector: 'procs',
              status: 'ok',
              text: '== cmdline ==\n$between== ps ==\n$rows',
            ),
          ]),
        );
        expect(
          bundle.sections.single.text,
          '== cmdline ==\n$between== ps ==\n$masked',
        );
      }

      // Anything else between them, or a ps line inside a record: read
      // as records, whose arguments may span lines. Nothing shows.
      for (final text in [
        '== cmdline ==\nnote\n== ps ==\n$rows',
        '== cmdline ==\n==> 1/cmdline <==\nsh\x1f-c\x1fa\n== ps ==\nb\x1f\n\n'
            '==> 2/cmdline <==\napp\x1f--password\x1fhun\nter2\x1f\n$rows',
        '== cmdline ==\n== ps ==x\n$rows',
        '== ps ==\n== cmdline ==\n\n$rows',
      ]) {
        events.clear();
        final shown = (await read(
          DiagnosticBundle([
            DiagnosticSection(collector: 'procs', status: 'ok', text: text),
          ]),
        )).sections.single.text;
        expect(shown, isNot(contains('hunter2')), reason: text);
        expect(shown, isNot(contains('ter2')), reason: text);
      }
    });

    test('cron: every line of every crontab', () async {
      final bundle = await read(
        const DiagnosticBundle([
          DiagnosticSection(
            collector: 'cron',
            status: 'ok',
            text:
                '== crontab_meta ==\nrc=0\n== crontab ==\n'
                'DB_PASSWORD=hunter2\n'
                '0 3 * * * mysqldump -phunter2 db | gzip\n'
                '*/5 * * * * sshpass -p hunter2 ssh h\n'
                '@daily PGPASSWORD=hunter2 pg_dump\n'
                '== etc_crontab ==\n'
                '17 * * * * root docker login -p hunter2 reg\n'
                '== cron_d ==\n'
                'backup\t0 4 * * * root app --password=hunter2\n'
                'backup\t0 5 * * * root curl -u admin:hunter2 https://x\n'
                '== cron_dirs ==\ndaily logrotate',
          ),
        ]),
      );

      expect(
        bundle.sections.single.text,
        '== crontab_meta ==\nrc=0\n== crontab ==\n'
        'DB_PASSWORD=********\n'
        '0 3 * * * mysqldump -p******** db | gzip\n'
        '*/5 * * * * sshpass -p ******** ssh h\n'
        '@daily PGPASSWORD=******** pg_dump\n'
        '== etc_crontab ==\n'
        '17 * * * * root docker login -p ******** reg\n'
        '== cron_d ==\n'
        'backup\t0 4 * * * root app --password=********\n'
        'backup\t0 5 * * * root curl -u admin:******** https://x\n'
        '== cron_dirs ==\ndaily logrotate',
      );
      expect(exported(bundle), isNot(contains('hunter2')));
    });

    test('a bundle of any shape is answered, never thrown on', () async {
      for (final text in [
        '',
        '\n',
        '== cmdline ==',
        '== cmdline ==\n',
        '== cmdline ==\n== ps ==',
        '==> <==\n\x1f\x1f\n==> 1/cmdline <==',
        '\x1f' * 70000,
        'a ' * 70000,
      ]) {
        events.clear();
        final bundle = await read(
          DiagnosticBundle([
            DiagnosticSection(collector: 'procs', status: 'ok', text: text),
            DiagnosticSection(collector: 'cron', status: 'ok', text: text),
          ]),
        );
        expect(bundle.sections, hasLength(2));
        expect(
          bundle.sections.first.text.split('\n').length,
          text.split('\n').length,
        );
      }
    });
  });

  test('the listening ports read runs its command and parses', () async {
    link = _RunLink(
      (_) => _ok(
        '$kPortsToolMarker ss\n'
        'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))\n'
        '$kPortsCgroupMarker 812\n0::/system.slice/ssh.service\n',
      ),
    );
    final read =
        ((await ask(const ListeningPortsQuery())).payload as ListeningPorts)
            .read;
    expect(read.sockets.single.port, 22);
    expect(read.owners[812]!.unit, 'ssh.service');
    expect(
      link!.commands.single,
      HostCommands.commandLine(
        HostCommands.listeningPorts(),
        quote: quoteShellWord,
      ),
    );

    events.clear();
    link = _RunLink((_) => _ok('sh: syntax error\n'));
    final failed =
        (await ask(const ListeningPortsQuery())).payload as HostQueryFailed;
    expect(failed.failure, HostQueryFailure.failed);
  });

  test('the processor read runs its command and parses', () async {
    link = _RunLink(
      (_) => _ok(
        '$kCpuNprocMarker\n2\n$kCpuLscpuMarker\n$kCpuInfoMarker\n'
        'processor\t: 0\nprocessor\t: 1\n',
      ),
    );
    final read =
        (await ask(const CpuTopologyQuery())).payload as CpuTopologyRead;
    expect(read.topology.usableCpus, 2);
    expect(read.topology.logicalCpus, 2);
    expect(
      link!.commands.single,
      HostCommands.commandLine(
        HostCommands.cpuTopology(),
        quote: quoteShellWord,
      ),
    );
  });

  test('the interface read runs its command and parses', () async {
    link = _RunLink(
      (_) => _ok(
        '$kNetLinksMarker\neth0/operstate:up\neth0/mtu:1500\n'
        '$kNetPhysicalMarker\neth0\n$kNetAddrMarker\n'
        '$kNetTcpMarker\n01 4\n$kNetSockstatMarker\nsockets: used 9\n',
      ),
    );
    final read =
        ((await ask(const InterfacesQuery())).payload as NetInterfaces).read;
    expect(read.interfaces.single.name, 'eth0');
    expect(read.interfaces.single.physical, isTrue);
    expect(read.sockets.tcp, {TcpState.established: 4});
    expect(
      link!.commands.single,
      HostCommands.commandLine(
        HostCommands.interfaces(),
        quote: quoteShellWord,
      ),
    );
  });

  test('a processor read that printed something else fails', () async {
    link = _RunLink((_) => _ok('sh: nproc: not found\n'));
    final payload =
        (await ask(const CpuTopologyQuery())).payload as HostQueryFailed;
    expect(payload.failure, HostQueryFailure.failed);
  });

  test('an interface read that printed something else fails', () async {
    link = _RunLink((_) => _ok('sh: grep: not found\n'));
    final payload =
        (await ask(const InterfacesQuery())).payload as HostQueryFailed;
    expect(payload.failure, HostQueryFailure.failed);
  });

  test('a server without a ready link is answered at once', () async {
    final payload = (await ask(const BootsQuery())).payload as HostQueryFailed;
    expect(payload.failure, HostQueryFailure.noLink);
  });

  test(
    'a refusal, a missing tool and a lost link answer as failures',
    () async {
      final answers = <RemoteCommandResult Function()>[
        () => const RemoteCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Failed to open journal: Permission denied\n',
        ),
        () => const RemoteCommandResult(
          exitCode: 127,
          stdout: '',
          stderr: 'sh: 1: exec: journalctl: not found\n',
        ),
        () => throw const RemoteCommandException('The link closed.'),
      ];
      final failures = <(HostQueryFailure, String?)>[];
      for (final answer in answers) {
        events.clear();
        link = _RunLink((_) => answer());
        final payload =
            (await ask(const BootsQuery())).payload as HostQueryFailed;
        failures.add((payload.failure, payload.detail));
      }
      expect(failures.map((f) => f.$1), [
        HostQueryFailure.denied,
        HostQueryFailure.missing,
        HostQueryFailure.failed,
      ]);
      expect(failures.first.$2, contains('Permission denied'));
      expect(failures.last.$2, contains('The link closed.'));
    },
  );
}
