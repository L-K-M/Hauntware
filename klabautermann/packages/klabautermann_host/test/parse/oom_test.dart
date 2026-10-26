import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// [HostCommands.oomKills]' output with [count] in `/proc/vmstat`, [source]
/// and [lines] from the kernel log, of [read] lines read.
String _out(
  List<String> lines, {
  String count = '2',
  String source = 'journal',
  int read = 900,
}) => [
  '$kOomVmstatMarker $count',
  '$kOomSourceMarker $source',
  ...lines,
  '$kOomReadMarker $read',
  '',
].join('\n');

void main() {
  test('journal kills carry their time, memory and cgroup', () {
    final read = parseOomKills(
      _out([
        '1729912345.123456 web-1 kernel: oom-kill:constraint=CONSTRAINT_NONE,'
            'nodemask=(null),cpuset=/,mems_allowed=0,global_oom,'
            'task_memcg=/user.slice/user-1000.slice/session-3.scope,'
            'task=stress,pid=4321,uid=1000',
        '1729912345.123460 web-1 kernel: Out of memory: Killed process 4321 '
            '(stress) total-vm:2105092kB, anon-rss:1904640kB, file-rss:4kB, '
            'shmem-rss:0kB, UID:1000 pgtables:3772kB oom_score_adj:0',
        '1729912400.000001 web-1 kernel: Memory cgroup out of memory: Killed '
            'process 777 (java) total-vm:900kB, anon-rss:512kB, file-rss:0kB',
      ]),
    )!;

    expect(read.killsSinceBoot, 2);
    expect(read.source, OomLogSource.journal);
    expect(read.logRead, isTrue);
    final [stress, java] = read.kills;
    expect(stress.pid, 4321);
    expect(stress.command, 'stress');
    expect(stress.at, DateTime.utc(2024, 10, 26, 3, 12, 25, 123, 460));
    expect(stress.sinceBoot, isNull);
    expect(stress.anonRssKb, 1904640);
    expect(stress.cgroupLimit, isFalse);
    expect(stress.cgroup, '/user.slice/user-1000.slice/session-3.scope');
    expect(java.cgroupLimit, isTrue);
    expect(java.cgroup, isNull);
    expect(java.anonRssKb, 512);
  });

  test('dmesg kills carry the time since boot', () {
    final read = parseOomKills(
      _out(source: 'dmesg', [
        '[ 8123.456789] Out of memory: Killed process 99 (a b) total-vm:1kB',
      ]),
    )!;
    final kill = read.kills.single;
    expect(read.source, OomLogSource.dmesg);
    expect(kill.command, 'a b');
    expect(kill.at, isNull);
    expect(kill.sinceBoot, const Duration(seconds: 8123));
    expect(kill.anonRssKb, isNull);
  });

  test('an unreadable log and an old kernel read as such, not as zero', () {
    final read = parseOomKills(_out(const [], count: '', read: 0))!;
    expect(read.killsSinceBoot, isNull);
    expect(read.logRead, isFalse);
    expect(read.kills, isEmpty);
  });

  test('anything else is not the read', () {
    expect(parseOomKills(''), isNull);
    expect(parseOomKills('sh: awk: not found\n'), isNull);
    expect(parseOomKills(_out(const [], source: 'syslog')), isNull);
    expect(
      parseOomKills('$kOomVmstatMarker 1\n$kOomSourceMarker dmesg\n'),
      isNull,
    );
  });
}
