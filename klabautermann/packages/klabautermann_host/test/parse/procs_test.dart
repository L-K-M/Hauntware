// `procs` parser tests (03 §7.2): fields of `/proc/<pid>/stat` counted
// after the last `)`, comm carrying spaces and `)`, the `status` subset,
// the `head|tr` cmdline dump with its forged-header rules, and the
// `ps -eo` / BusyBox `ps w` fallbacks.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

/// One `/proc/<pid>/stat` row as the fragment writes it: the collected
/// path pid, a space, then the raw file line. `comm` sits between the
/// first `(` and the last `)`; the fields after it start at field 3.
String _stat(
  int pid,
  String comm, {
  String state = 'S',
  int ppid = 0,
  int utime = 0,
  int stime = 0,
  int threads = 1,
  int start = 1000,
}) =>
    '$pid $pid ($comm) $state $ppid 1 1 0 -1 4194560 0 0 0 0 '
    '$utime $stime 0 0 20 0 $threads 0 $start';

/// The `status` rows the fragment collects for one pid.
String _status(
  int pid, {
  String name = 'x',
  int uid = 0,
  int rss = 100,
  int threads = 1,
}) =>
    '$pid Name:\t$name\n'
    '$pid Uid:\t$uid\t$uid\t$uid\t$uid\n'
    '$pid Gid:\t0\t0\t0\t0\n'
    '$pid VmRSS:\t   $rss kB\n'
    '$pid Threads:\t$threads';

void main() {
  test('stat fields count after the last ) so comm may hold spaces and )', () {
    final raw = [
      '== stat ==',
      _stat(
        4242,
        'a silly) name with spaces',
        ppid: 7,
        utime: 11,
        stime: 12,
        threads: 3,
        start: 999,
      ),
      '== status ==',
      _status(4242, name: 'a silly name', uid: 1000, rss: 2048, threads: 3),
      '== cmdline ==',
      '==> 4242/cmdline <==',
      '/usr/bin/thing\x1f--flag\x1f',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.processes, hasLength(1));
    final p = r.value.processes.single;
    expect(p.pid, 4242);
    expect(p.comm, 'a silly) name with spaces');
    expect(p.state, 'S');
    expect(p.ppid, 7);
    expect(p.utime, 11);
    expect(p.stime, 12);
    expect(p.jiffies, 23);
    expect(p.threads, 3);
    expect(p.startTicks, 999);
    expect(p.uid, 1000);
    expect(p.name, 'a silly name');
    expect(p.rssKb, 2048);
    expect(p.argv, ['/usr/bin/thing', '--flag']);
    expect(p.hasCommandLine, isTrue);
    expect(r.value.argvSource, ProcsArgvSource.cmdline);
  });

  test('an empty cmdline is a real empty argument vector', () {
    final raw = [
      '== stat ==',
      _stat(2, 'kthreadd'),
      '== status ==',
      _status(2, name: 'kthreadd'),
      '== cmdline ==',
      '==> 2/cmdline <==',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    final p = r.value.processes.single;
    expect(p.argv, isEmpty);
    expect(p.hasCommandLine, isTrue);
  });

  test('a repeated header marks it and the interrupted entry unavailable', () {
    final raw = [
      '== stat ==',
      _stat(10, 'foo'),
      '== status ==',
      _status(10),
      '== cmdline ==',
      '==> 10/cmdline <==',
      '/usr/bin/foo\x1farg1',
      '==> 10/cmdline <==',
      'arg2\x1f',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.forgedHeaders, 1);
    expect(r.value.processes.single.argv, isNull);
    expect(r.value.processes.single.hasCommandLine, isFalse);
    expect(r.warnings, contains(contains('forged')));
  });

  test('an out-of-order header is forged under the LC_ALL=C glob order', () {
    // Real glob order is byte order, so `10` precedes `9`; `9` then `10`
    // is a forgery (03 §7.2).
    final raw = [
      '== stat ==',
      _stat(9, 'nine'),
      _stat(10, 'ten'),
      '== status ==',
      _status(9),
      _status(10),
      '== cmdline ==',
      '==> 9/cmdline <==',
      '/sbin/nine\x1f',
      '==> 10/cmdline <==',
      '/sbin/ten\x1f',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.forgedHeaders, 1);
    for (final p in r.value.processes) {
      expect(p.argv, isNull, reason: 'pid ${p.pid}');
    }
  });

  test('headers for pids outside the stat pass are skipped', () {
    final raw = [
      '== stat ==',
      _stat(1, 'init'),
      '== status ==',
      _status(1),
      '== cmdline ==',
      '==> 1/cmdline <==',
      '/sbin/init\x1f',
      '==> 999/cmdline <==',
      '/gone\x1f',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.skippedPids, 1);
    expect(r.value.processes.single.pid, 1);
    expect(r.value.processes.single.argv, ['/sbin/init']);
  });

  test('the ps -eo fallback parses positional rows', () {
    final raw = [
      '== stat ==',
      _stat(1, 'init', ppid: 0),
      '== status ==',
      _status(1, name: 'init', rss: 1234),
      '== cmdline ==',
      '== ps ==',
      'PID PPID USER STAT RSS COMMAND',
      '1 0 root S 1234 /sbin/init --system',
      '4321 1 root S 5678 /usr/sbin/crond -f',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.argvSource, ProcsArgvSource.ps);
    final one = r.value.processes.firstWhere((p) => p.pid == 1);
    expect(one.ppid, 0);
    expect(one.userName, 'root');
    expect(one.state, 'S');
    expect(one.rssKb, 1234);
    expect(one.argsJoined, '/sbin/init --system');
    expect(one.argv, isNull);
    // A ps row missing from the stat pass is still listed.
    final extra = r.value.processes.firstWhere((p) => p.pid == 4321);
    expect(extra.argsJoined, '/usr/sbin/crond -f');
    expect(extra.rssKb, 5678);
  });

  test('the BusyBox ps w fallback keeps the whole command column', () {
    final raw = [
      '== stat ==',
      _stat(1, 'init'),
      '== status ==',
      _status(1, name: 'init'),
      '== cmdline ==',
      '== ps_w ==',
      'PID USER TIME COMMAND',
      '1 root 0:00 init',
      '4321 root 0:00 /usr/sbin/crond -f',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.argvSource, ProcsArgvSource.psW);
    expect(
      r.value.processes.firstWhere((p) => p.pid == 4321).argsJoined,
      '/usr/sbin/crond -f',
    );
  });

  test('a missing argv source warns and keeps the stat rows', () {
    final raw = [
      '== stat ==',
      _stat(1, 'init'),
      '== status ==',
      _status(1),
      '== cmdline ==',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.argvSource, ProcsArgvSource.none);
    expect(r.value.processes, hasLength(1));
    expect(r.value.processes.single.hasCommandLine, isFalse);
    expect(r.warnings, isNotEmpty);
  });

  test('the timeout-absent marker is surfaced as a warning', () {
    final raw = [
      kTimeoutAbsentMarker,
      '== stat ==',
      _stat(1, 'init'),
    ].join('\n');
    final r = parseProcs(raw, _ctx);
    expect(r.value.timeoutAbsent, isTrue);
    expect(r.warnings, contains(contains('timeout')));
  });
}
