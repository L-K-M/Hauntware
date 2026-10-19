// The engine on the GitHub-hosted Ubuntu runner, a systemd host (03
// §11.3, K28a): units, timers and OnCalendar next runs, a journal follow
// resumed after its cursor across a forced reconnect and run without a
// pager, unit logs, the kernel log, LOG-04 for an account outside
// systemd-journal, and journal paging by cursor, over real SSH as
// throwaway accounts whose login shell is /bin/sh, dash. runner_vm.sh
// starts the leg's sshd and runs these one at a time; without it they
// skip.
@Tags(['runner-vm'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io' show pid;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        HostCommands,
        ParseContext,
        TimerListFormat,
        parseOnCalendar,
        parseTimerDetail,
        timerCalendarCommands;
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/runner_vm.dart';

/// systemd's first release with JSON unit and timer lists (03 §6.4).
const _systemdJson = 246;

/// Covers the redial after the forced reconnect: the close, the
/// supervisor's backoff and a handshake that waited on the paused sshd.
const _redialWait = Duration(seconds: 90);

/// Covers journald writing what `logger` sent before a read finds it.
const _journalWait = Duration(seconds: 20);

final _marker = RegExp(r'^marker (\d+)$');

/// The fields a `journalctl -u` match reads (journalctl(1), systemd 255).
const _unitFields = [
  '_SYSTEMD_UNIT',
  'UNIT',
  'OBJECT_SYSTEMD_UNIT',
  'COREDUMP_UNIT',
];

void main() {
  final vm = RunnerVm.fromEnvironment();
  if (vm == null) {
    test('the runner-VM suite', () {}, skip: runnerVmSkipReason);
    return;
  }

  /// Whether journald keeps the journal on disk, where it gives each
  /// account its own file, and whether only privileged accounts may read
  /// the kernel ring buffer.
  late bool persistentJournal;
  late bool dmesgRestricted;

  setUpAll(() async {
    // systemd under dash: /bin/sh, which the engine's commands run under,
    // and both accounts' login shell, which reads each command line.
    expect(
      await vm.ssh(vm.limitedUser, 'readlink -f /bin/sh'),
      '/usr/bin/dash\n',
    );
    for (final user in [vm.limitedUser, vm.journalUser]) {
      final entry = await vm.ssh(user, r'getent passwd "$(id -un)"');
      expect(entry.trim().split(':').last, '/bin/sh', reason: user);
    }
    persistentJournal =
        (await vm.ssh(
          vm.limitedUser,
          r'[ -d "/var/log/journal/$(cat /etc/machine-id)" ] && echo yes || '
          'echo no',
        )).trim() ==
        'yes';
    dmesgRestricted =
        (await vm.ssh(
          vm.limitedUser,
          'cat /proc/sys/kernel/dmesg_restrict',
        )).trim() ==
        '1';
  });

  test('the probe and the units list read systemd under dash', () async {
    final engine = await vm.engine('units');
    expect(await engine.connect(limitedServer, vm.hostKeys), [vm.endpoint]);
    await engine.subscribe(limitedServer, {SampleStream.units});

    final profile = await _profile(engine, limitedServer);
    engine.note('= ${profile.systemctlVersionLine}');
    expect(profile.user, vm.limitedUser);
    expect(profile.systemdVersion, isNotNull);
    expect(profile.systemdVersion, greaterThanOrEqualTo(_systemdJson));

    final sample = await engine.firstSample(limitedServer, SampleStream.units);
    expect(sample.result, isA<UnitsResult>());
    final units = (sample.result as UnitsResult).units;
    expect(units.format, UnitListFormat.json);
    for (final name in ['systemd-journald.service', 'systemd-logind.service']) {
      expect(
        units.units,
        contains(
          isA<SystemdUnit>()
              .having((u) => u.unit, 'unit', name)
              .having((u) => u.load, 'load', 'loaded')
              .having((u) => u.active, 'active', 'active'),
        ),
      );
    }
  });

  test('timers list the next run that systemd-analyze predicts for the '
      'OnCalendar expression', () async {
    final engine = await vm.engine('timers');
    await engine.connect(limitedServer, vm.hostKeys);
    await engine.subscribe(limitedServer, {SampleStream.timers});
    final profile = await _profile(engine, limitedServer);

    final sample = await engine.firstSample(limitedServer, SampleStream.timers);
    expect(sample.result, isA<TimersResult>());
    final timers = (sample.result as TimersResult).timers;
    expect(timers.format, TimerListFormat.json);
    final timer = timers.timers.singleWhere((t) => t.unit == vm.timer);
    expect(
      timer.activates,
      vm.timer.replaceFirst(RegExp(r'\.timer$'), '.service'),
    );
    final next = timer.nextUtc;
    expect(next, isNotNull);

    // The on-demand timer_detail read (D57), as the slow sampler's
    // fragment runs it (`_kTimerDetailFragment` in klabautermann_host).
    final detailText = await vm.ssh(
      vm.limitedUser,
      HostCommands.commandLine([
        'systemctl',
        'show',
        '-p',
        'TimersCalendar',
        '-p',
        'TimersMonotonic',
        '-p',
        'RandomizedDelayUSec',
        '--',
        vm.timer,
      ], quote: quoteShellWord),
    );
    engine.note('= timer_detail:\n$detailText');
    final detail = parseTimerDetail(detailText, ParseContext.standard);
    expect(detail.warnings, isEmpty);
    expect(detail.value.calendar, [vm.calendar]);
    expect(detail.value.randomizedDelay, Duration.zero);

    // The calendar read the Jobs tab issues for that expression (7.7).
    final reads = timerCalendarCommands(
      detail.value,
      runCount: 3,
      systemdMajor: profile.systemdVersion,
    );
    expect(reads.keys, [vm.calendar]);
    final calendarText = await vm.ssh(
      vm.limitedUser,
      HostCommands.commandLine(reads[vm.calendar]!, quote: quoteShellWord),
    );
    // After the read: the timer can come due while systemd-analyze runs.
    final readAt = DateTime.now().toUtc();
    engine.note('= systemd-analyze calendar:\n$calendarText');
    final calendar = parseOnCalendar(calendarText);
    expect(calendar.warnings, isEmpty);
    expect(calendar.value.normalizedForm, vm.calendar);
    final elapses = [for (final e in calendar.value.elapses) e.atUtc];
    expect(elapses, hasLength(3));
    expect(elapses, everyElement(isNotNull));
    final runs = elapses.nonNulls.toList();
    for (var i = 1; i < runs.length; i++) {
      expect(runs[i].isAfter(runs[i - 1]), isTrue, reason: '$runs');
    }
    // PID 1 and systemd-analyze evaluate the zone-less expression in the
    // same system zone, so the timer's next run is the first prediction,
    // unless it came due between the sample and the read.
    if (runs.first != next) {
      expect(next!.isAfter(readAt), isFalse, reason: 'next $next, $runs');
    }

    final row = TimerJobEntry(
      timer: timer,
    ).withDetail(detail.value, calendars: {vm.calendar: calendar.value});
    expect(row.triggers, [
      isA<CalendarSchedule>()
          .having((s) => s.normalized, 'normalized', vm.calendar)
          .having((s) => s.elapses, 'elapses', hasLength(3)),
    ]);
  });

  test('a journal follow runs without a pager and resumes after its cursor '
      'across a forced reconnect', () async {
    final engine = await vm.engine('follow reconnect');
    await engine.connect(journalServer, vm.hostKeys);
    final tag = 'klab-follow-$pid';
    const id = 'follow';
    engine.send(
      OpenLogStream(
        streamId: id,
        spec: LogStreamSpec(
          serverId: journalServer,
          source: JournalLogSource(identifier: tag),
          window: 0,
          follow: true,
        ),
      ),
    );
    await engine.until<LogStreamState>(
      (e) => e.streamId == id && e.status == const LogStreamRunning(),
    );

    await _untilFollowing(vm, engine, tag, id);
    await vm.logMarkers(vm.journalUser, tag, [1, 2, 3, 4, 5]);
    await _untilMarkers(engine, id, 5);
    final first = await _journalctl(vm, vm.journalUser);
    engine.note('= first run: ${first.argv.join(' ')}');
    _expectNoPager(first);
    expect(first.argv, containsAllInOrder(['-n', '0', '-f']));
    expect(first.argv.where((a) => a.startsWith('--after-cursor=')), isEmpty);
    final cursor = _records(engine, id).whereType<JournalRecord>().last.cursor;
    expect(cursor, isNotNull);

    // Hold new connections in the listen queue, then drop the engine's:
    // the follow must wait, and records written meanwhile must arrive
    // once it resumes.
    final mark = engine.seen.length;
    engine.note('! pause sshd');
    await vm.pauseSshd();
    var paused = true;
    addTearDown(() async {
      if (paused) await vm.resumeSshd();
    });
    final serving = await vm.connectionProcesses(vm.journalUser);
    expect(serving, isNotEmpty);
    engine.note('! SIGKILL connection processes $serving');
    await vm.sudo(['kill', '-KILL', for (final p in serving) '$p']);

    await _seenOrNext<LinkState>(
      engine,
      mark,
      (e) => e.serverId == journalServer && e.status is LinkClosed,
    );
    final waiting = await _seenOrNext<LogStreamState>(
      engine,
      mark,
      (e) =>
          e.streamId == id &&
          e.status == const LogStreamWaiting(LogStreamWaitReason.link),
    );
    final waited = engine.seen.indexOf(waiting);
    await vm.logMarkers(vm.journalUser, tag, [6, 7, 8, 9, 10], viaSudo: true);

    engine.note('! resume sshd');
    await vm.resumeSshd();
    paused = false;
    await _seenOrNext<LinkState>(
      engine,
      waited,
      (e) => e.serverId == journalServer && e.status == const LinkReady(),
      _redialWait,
    );
    await _seenOrNext<LogStreamState>(
      engine,
      waited,
      (e) => e.streamId == id && e.status is LogStreamRunning,
    );
    await vm.logMarkers(vm.journalUser, tag, [11, 12, 13, 14, 15]);
    await _untilMarkers(engine, id, 15);

    final resumed = await _journalctl(vm, vm.journalUser);
    engine.note('= resumed run: ${resumed.argv.join(' ')}');
    _expectNoPager(resumed);
    expect(resumed.argv, containsAll(['--after-cursor=$cursor', '--no-tail']));

    engine.send(const CloseStream(id));
    await engine.until<LogStreamState>(
      (e) =>
          e.streamId == id &&
          e.status == const LogStreamEnded(LogStreamEndReason.closed),
    );
    // Nothing lost, nothing twice, nothing dropped, and no gap reported.
    expect(_markers(_records(engine, id)), [for (var n = 1; n <= 15; n++) n]);
    expect([
      for (final e in engine.seen)
        if (e is LogBatch && e.streamId == id) e.dropped,
    ], everyElement(0));
    final statuses = [
      for (final e in engine.seen.skip(mark))
        if (e is LogStreamState && e.streamId == id) e.status,
    ];
    expect(
      statuses,
      containsAllInOrder([
        const LogStreamWaiting(LogStreamWaitReason.link),
        const LogStreamRunning(),
      ]),
    );
    expect(
      statuses,
      everyElement(
        isNot(const LogStreamRunning(continuity: LogContinuity.gap)),
      ),
    );
  });

  test('unit logs show a system unit to the systemd-journal account and '
      'silently nothing to the other (LOG-04)', () async {
    final engine = await vm.engine('unit logs');
    await engine.connect(limitedServer, vm.hostKeys);
    await engine.connect(journalServer, vm.hostKeys);
    await engine.subscribe(limitedServer, {SampleStream.identity});
    await engine.subscribe(journalServer, {SampleStream.identity});

    final limited = await _profile(engine, limitedServer);
    final journal = await _profile(engine, journalServer);
    expect(limited.groups.toSet().intersection(journalGroups), isEmpty);
    expect(journal.groups, contains('systemd-journal'));
    expect(evaluateAccess(limited).journalLimited, isTrue);
    expect(evaluateAccess(journal).journalLimited, isFalse);

    // Every SSH sign-in adds logind records, these tests' included.
    const unit = 'systemd-logind.service';
    final shown = await _window(
      engine,
      journalServer,
      'unit-journal',
      const JournalLogSource(unit: unit),
      50,
    );
    // `-u` also matches PID 1's records about the unit (`UNIT=`) and
    // the like (journalctl(1)), whose own unit is init.scope.
    expect(
      shown.records,
      contains(isA<JournalRecord>().having((r) => r.unit, 'unit', unit)),
    );
    expect(
      shown.records,
      everyElement(
        isA<JournalRecord>().having(
          (r) => _unitFields.map((key) => r.fields[key]),
          'unit fields',
          contains(unit),
        ),
      ),
    );
    expect(
      shown.end.reason,
      anyOf(LogStreamEndReason.windowFilled, LogStreamEndReason.oldestReached),
    );

    final hidden = await _window(
      engine,
      limitedServer,
      'unit-limited',
      const JournalLogSource(unit: unit),
      50,
    );
    expect(hidden.records, isEmpty);
    // With a journal on disk the account reads its own file, which holds
    // no such record; with one in memory it can open no file at all, and
    // journalctl says so.
    expect(
      hidden.end.reason,
      persistentJournal
          ? LogStreamEndReason.oldestReached
          : anyOf(LogStreamEndReason.oldestReached, LogStreamEndReason.denied),
    );

    // What the account does see is its own, from the file journald keeps
    // for it on disk; a journal kept in memory gives it nothing at all.
    final tag = 'klab-own-$pid';
    await vm.logMarkers(vm.limitedUser, tag, [1]);
    engine.note('= journal on disk: $persistentJournal');
    final own = await _windowUntil(
      engine,
      limitedServer,
      'own',
      JournalLogSource(identifier: tag),
      (records) => records.isNotEmpty,
      persistentJournal ? _journalWait : const Duration(seconds: 3),
    );
    expect(_markers(own.records), persistentJournal ? [1] : isEmpty);
  });

  test('the kernel log reads the journal for the systemd-journal account '
      'and falls back to dmesg for the other', () async {
    final engine = await vm.engine('kernel log');
    await engine.connect(journalServer, vm.hostKeys);
    await engine.connect(limitedServer, vm.hostKeys);

    final journal = await _window(
      engine,
      journalServer,
      'kernel-journal',
      const KernelLogSource(),
      50,
    );
    expect(journal.readers, [LogReader.primary]);
    expect(journal.records, isNotEmpty);
    expect(
      journal.records,
      everyElement(
        isA<JournalRecord>().having(
          (r) => r.fields['_TRANSPORT'],
          '_TRANSPORT',
          'kernel',
        ),
      ),
    );

    // Kernel entries are never the account's own, so journalctl -k gives
    // it none and the engine reads dmesg, which kernel.dmesg_restrict
    // refuses to unprivileged accounts.
    final limited = await _window(
      engine,
      limitedServer,
      'kernel-limited',
      const KernelLogSource(),
      50,
    );
    engine.note('= kernel.dmesg_restrict: $dmesgRestricted');
    expect(limited.readers, [LogReader.primary, LogReader.fallback]);
    if (dmesgRestricted) {
      expect(limited.records, isEmpty);
      expect(limited.end.reason, LogStreamEndReason.denied);
    } else {
      expect(limited.records, isNotEmpty);
      expect(limited.records, everyElement(isA<KernelRecord>()));
    }
  });

  test('journal pages continue after the last cursor without overlap or '
      'gap', () async {
    final engine = await vm.engine('paging');
    await engine.connect(journalServer, vm.hostKeys);
    final tag = 'klab-paging-$pid';
    final source = JournalLogSource(identifier: tag);
    await vm.logMarkers(vm.journalUser, tag, [for (var n = 1; n <= 12; n++) n]);
    final all = await _windowUntil(
      engine,
      journalServer,
      'all',
      source,
      (records) => records.length >= 12,
      _journalWait,
    );
    expect(_markers(all.records), [for (var n = 12; n >= 1; n--) n]);

    // LOG-01's older pages: -r -n <window> --after-cursor=<last cursor>.
    final pages = <List<int>>[];
    final ends = <LogStreamEndReason>[];
    String? after;
    for (var page = 0; page < 3; page++) {
      final read = await _window(
        engine,
        journalServer,
        'page-$page',
        source,
        5,
        afterCursor: after,
      );
      pages.add(_markers(read.records));
      ends.add(read.end.reason);
      after = (read.records.last as JournalRecord).cursor;
    }
    expect(pages, [
      [12, 11, 10, 9, 8],
      [7, 6, 5, 4, 3],
      [2, 1],
    ]);
    expect(ends, [
      LogStreamEndReason.windowFilled,
      LogStreamEndReason.windowFilled,
      LogStreamEndReason.oldestReached,
    ]);
  });
}

/// [serverId]'s probe result: the first read so far, or else the next.
Future<HostProfile> _profile(FixtureEngine engine, String serverId) async {
  for (final event in engine.seen) {
    if (event is HostProfileChanged && event.serverId == serverId) {
      return event.profile;
    }
  }
  final changed = await engine.until<HostProfileChanged>(
    (e) => e.serverId == serverId,
  );
  return changed.profile;
}

/// The first event of type [T] from the [mark]th on that [test] accepts,
/// read already or still to come, so a wait does not depend on the order
/// in which two events of one change arrive.
Future<T> _seenOrNext<T extends EngineEvent>(
  FixtureEngine engine,
  int mark,
  bool Function(T event) test, [
  Duration timeout = const Duration(seconds: 30),
]) async {
  for (final event in engine.seen.skip(mark)) {
    if (event is T && test(event)) return event;
  }
  return engine.until<T>(test, timeout);
}

/// Every record of stream [streamId] read so far, in order.
List<LogRecord> _records(FixtureEngine engine, String streamId) => [
  for (final event in engine.seen)
    if (event is LogBatch && event.streamId == streamId) ...event.records,
];

/// The numbers of the `marker <n>` records among [records], in order.
List<int> _markers(Iterable<LogRecord> records) => [
  for (final record in records)
    if (record case JournalRecord(:final message?))
      if (_marker.firstMatch(message) case final match?) int.parse(match[1]!),
];

/// Writes `ready` lines tagged [tag] as the journal account until stream
/// [streamId] delivers one. A follow from the tail (`-n 0`) shows what
/// arrives after the tail journalctl finds once it has opened the
/// journal, which on the runner can come a second after the stream
/// reports running; a marker written before then never shows.
Future<void> _untilFollowing(
  RunnerVm vm,
  FixtureEngine engine,
  String tag,
  String streamId,
) async {
  var following = false;
  final writer = () async {
    while (!following) {
      await vm.ssh(vm.journalUser, 'logger -t ${quoteShellWord(tag)} ready');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }();
  try {
    await engine.until<LogBatch>((b) => b.streamId == streamId, _journalWait);
  } finally {
    following = true;
    await writer;
  }
}

/// Reads until stream [streamId] has delivered [count] markers.
Future<void> _untilMarkers(
  FixtureEngine engine,
  String streamId,
  int count,
) async {
  while (_markers(_records(engine, streamId)).length < count) {
    await engine.until<LogBatch>((batch) => batch.streamId == streamId);
  }
}

typedef _Window = ({
  List<LogRecord> records,
  List<LogReader> readers,
  LogStreamEnded end,
});

/// Reads a window of [window] records of [source] on [serverId] as stream
/// [streamId]: its records, the readers its running states named, and its
/// end.
Future<_Window> _window(
  FixtureEngine engine,
  String serverId,
  String streamId,
  LogSource source,
  int window, {
  String? afterCursor,
}) async {
  final mark = engine.seen.length;
  engine.send(
    OpenLogStream(
      streamId: streamId,
      spec: LogStreamSpec(
        serverId: serverId,
        source: source,
        window: window,
        follow: false,
        afterCursor: afterCursor,
      ),
    ),
  );
  final ended = await engine.until<LogStreamState>(
    (e) => e.streamId == streamId && e.status is LogStreamEnded,
  );
  final events = engine.seen.skip(mark).toList();
  return (
    records: [
      for (final e in events)
        if (e is LogBatch && e.streamId == streamId) ...e.records,
    ],
    readers: [
      for (final e in events)
        if (e case LogStreamState(
          streamId: final id,
          status: LogStreamRunning(:final reader),
        ) when id == streamId)
          reader,
    ],
    end: ended.status as LogStreamEnded,
  );
}

/// Reads 500-record windows of [source], each as a new stream named after
/// [prefix], until one satisfies [done] or [wait] has passed, and returns
/// the last.
Future<_Window> _windowUntil(
  FixtureEngine engine,
  String serverId,
  String prefix,
  LogSource source,
  bool Function(List<LogRecord> records) done,
  Duration wait,
) async {
  final clock = Stopwatch()..start();
  for (var attempt = 0; ; attempt++) {
    final read = await _window(
      engine,
      serverId,
      '$prefix-$attempt',
      source,
      500,
    );
    if (done(read.records) || clock.elapsed > wait) return read;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

typedef _Process = ({
  List<String> argv,
  Map<String, String> environment,
  List<String> children,
  String stdout,
});

const _section = '--klab--';

/// The newest `journalctl` process of [user], read from `/proc` over the
/// side channel: what the engine really runs on the host.
Future<_Process> _journalctl(RunnerVm vm, String user) async {
  final out = await vm.ssh(user, '''
set -eu
p=\$(pgrep -n -u "\$(id -u)" -x journalctl)
tr '\\0' '\\n' </proc/"\$p"/cmdline
echo $_section
tr '\\0' '\\n' </proc/"\$p"/environ
echo $_section
pgrep -P "\$p" || true
echo $_section
readlink /proc/"\$p"/fd/1
''');
  final parts = out.split('$_section\n');
  expect(parts, hasLength(4), reason: out);
  List<String> lines(String part) =>
      part.split('\n').where((l) => l.isNotEmpty).toList();
  return (
    argv: lines(parts[0]),
    environment: {
      for (final line in lines(parts[1]))
        if (line.indexOf('=') case final eq when eq > 0)
          line.substring(0, eq): line.substring(eq + 1),
    },
    children: lines(parts[2]),
    stdout: parts[3].trim(),
  );
}

/// journalctl pages only when its output is a terminal and a pager is
/// set (journalctl(1)); the engine rules out both, on every host.
void _expectNoPager(_Process process) {
  expect(process.argv, containsAllInOrder(['journalctl', '-o', 'json']));
  expect(process.argv, contains('--no-pager'));
  expect(process.environment, containsPair('SYSTEMD_PAGER', ''));
  expect(process.environment, containsPair('LC_ALL', 'C'));
  expect(process.children, isEmpty, reason: 'no pager process');
  expect(process.stdout, isNot(startsWith('/dev/')), reason: 'no terminal');
}
