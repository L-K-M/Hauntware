// `procs` parser tests (03 §7.2, D48): the trimmed rows with comm
// carrying spaces and `)`, the `meta` block's total and selection, the
// `head|tr` cmdline dump with its forged-header rules, and the `ps -eo` /
// BusyBox `ps w` fallbacks.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

/// One row as the fragment writes it (D48): pid, state, ppid, utime,
/// stime, starttime, uid, RSS in kB, then comm verbatim.
String _row(
  int pid,
  String comm, {
  String state = 'S',
  int ppid = 0,
  int utime = 0,
  int stime = 0,
  int start = 1000,
  Object uid = 0,
  Object rss = 100,
}) => '$pid $state $ppid $utime $stime $start $uid $rss $comm';

void main() {
  test('stat fields count after the last ) so comm may hold spaces and )', () {
    final raw = [
      '== meta ==',
      'total=1',
      'selection=all',
      '== rows ==',
      _row(
        4242,
        'a silly) name with spaces',
        ppid: 7,
        utime: 11,
        stime: 12,
        start: 999,
        uid: 1000,
        rss: 2048,
      ),
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
    expect(p.startTicks, 999);
    expect(p.uid, 1000);
    expect(p.rssKb, 2048);
    expect(p.argv, ['/usr/bin/thing', '--flag']);
    expect(p.hasCommandLine, isTrue);
    expect(r.value.argvSource, ProcsArgvSource.cmdline);
    expect(r.value.totalProcesses, 1);
    expect(r.value.selection, ProcsSelection.all);
    expect(r.value.truncated, isFalse);
    expect(r.warnings, isEmpty);
  });

  test('a kept subset reports the total it was taken from', () {
    final raw = [
      '== meta ==',
      'total=2083',
      'selection=cpu_rss',
      '== rows ==',
      _row(1, 'init'),
      _row(2, 'kthreadd', uid: '-', rss: '-'),
      '== cmdline ==',
      '== ps ==',
      'PID PPID USER STAT RSS COMMAND',
      '1 0 root S 1234 /sbin/init',
      '4321 1 root S 5678 /usr/sbin/crond -f',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.selection, ProcsSelection.cpuAndMemory);
    expect(r.value.totalProcesses, 2083);
    expect(r.value.truncated, isTrue);
    // A ps row the host left out does not come back.
    expect(r.value.processes.map((p) => p.pid), [1, 2]);
    final k = r.value.processes[1];
    expect(k.uid, isNull);
    expect(k.rssKb, isNull);
  });

  test('a row with a malformed field or too few fields is skipped', () {
    final raw = [
      '== meta ==',
      'total=3',
      'selection=all',
      '== rows ==',
      '5 S 1 x 0 7 0 0 bad utime',
      '6 S 1 0 0 7 0',
      _row(7, ' leading space'),
      '== cmdline ==',
    ].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.processes.single.comm, ' leading space');
    expect(r.warnings.where((w) => w.startsWith('procs row')), hasLength(2));
  });

  test('pid order and unknown selections parse as their meta says', () {
    ParseResult<ProcsSnapshot> parse(int total, String selection) => parseProcs(
      [
        '== meta ==',
        'total=$total',
        'selection=$selection',
        '== rows ==',
        _row(1, 'init'),
      ].join('\n'),
      _ctx,
    );

    final pid = parse(900, 'pid').value;
    expect(pid.selection, ProcsSelection.pidOrder);
    expect(pid.truncated, isTrue);
    final unknown = parse(1, 'new');
    expect(unknown.value.selection, isNull);
    expect(unknown.value.truncated, isFalse);
    expect(unknown.warnings, contains('procs: meta block lacks the selection'));
  });

  test('a missing meta block warns and leaves the total unknown', () {
    final r = parseProcs(['== rows ==', _row(1, 'init')].join('\n'), _ctx);
    expect(r.value.totalProcesses, isNull);
    expect(r.value.selection, isNull);
    expect(r.value.truncated, isFalse);
    expect(r.warnings, contains('procs: missing meta block'));
  });

  test('an empty cmdline is a real empty argument vector', () {
    final raw = [
      '== rows ==',
      _row(2, 'kthreadd'),
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
      '== rows ==',
      _row(10, 'foo'),
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
      '== rows ==',
      _row(9, 'nine'),
      _row(10, 'ten'),
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

  test('headers for pids outside the rows are skipped', () {
    final raw = [
      '== rows ==',
      _row(1, 'init'),
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
      '== rows ==',
      _row(1, 'init', ppid: 0, rss: '-'),
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
    // A ps row missing from the rows is still listed.
    final extra = r.value.processes.firstWhere((p) => p.pid == 4321);
    expect(extra.argsJoined, '/usr/sbin/crond -f');
    expect(extra.rssKb, 5678);
  });

  test('the BusyBox ps w fallback keeps the whole command column', () {
    final raw = [
      '== rows ==',
      _row(1, 'init'),
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
    final raw = ['== rows ==', _row(1, 'init'), '== cmdline =='].join('\n');

    final r = parseProcs(raw, _ctx);
    expect(r.value.argvSource, ProcsArgvSource.none);
    expect(r.value.processes, hasLength(1));
    expect(r.value.processes.single.hasCommandLine, isFalse);
    expect(r.warnings, isNotEmpty);
  });

  test('the timeout-absent marker is surfaced as a warning', () {
    final raw = [
      kTimeoutAbsentMarker,
      '== rows ==',
      _row(1, 'init'),
    ].join('\n');
    final r = parseProcs(raw, _ctx);
    expect(r.value.timeoutAbsent, isTrue);
    expect(r.warnings, contains(contains('timeout')));
  });
}
