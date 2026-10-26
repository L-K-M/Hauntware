// HostQueries against a link whose one-shot runs the test answers (03
// §7.6): each query runs its validated command and answers once, with
// the parsed rows or why it read none.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/host_queries.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult, quoteShellWord;
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

  test('a kernel read that printed something else fails', () async {
    link = _RunLink((_) => _ok('sh: uname: not found\n'));
    final payload =
        (await ask(const KernelsQuery())).payload as HostQueryFailed;
    expect(payload.failure, HostQueryFailure.failed);
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
