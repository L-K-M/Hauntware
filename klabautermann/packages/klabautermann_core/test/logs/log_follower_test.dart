// LogFollower over a scripted link and a fake clock (03 §7.6, §10.1;
// LOG-02, LOG-22): its commands, its ring and rate, how it resumes, and
// that it ends once.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/log_follower.dart';
import 'package:klabautermann_core/src/logs/log_service.dart'
    show kLogWindowMax;
import 'package:klabautermann_host/klabautermann_host.dart'
    show HostCommands, JournalBoot;
import 'package:seance_core/seance_core.dart'
    show RemoteExit, SshLinkClosed, SshLinkClosedReason, quoteShellWord;
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/scripted_link.dart';

/// The journal entry [n] as `journalctl -o json` prints it.
String _entry(int n, {DateTime? at, String? cursor}) =>
    '${jsonEncode({'__CURSOR': cursor ?? 's=$n', if (at != null) '__REALTIME_TIMESTAMP': '${at.microsecondsSinceEpoch}', 'MESSAGE': 'entry $n'})}\n';

String _entries(int from, int to) =>
    [for (var n = from; n <= to; n++) _entry(n)].join();

LogStreamSpec _spec(LogSource source, {int window = 500, String? after}) =>
    LogStreamSpec(
      serverId: 'srv-1',
      source: source,
      window: window,
      follow: true,
      afterCursor: after,
    );

/// The command line that runs [argv].
String _cmd(List<String> argv) =>
    HostCommands.commandLine(argv, quote: quoteShellWord);

const _journal = ['journalctl', '-o', 'json', '--no-pager'];

/// A token the secret redactor knows by its shape.
const _token = 'ghp_A1b2C3d4E5f6G7h8I9j0K1';
void main() {
  late ScriptedLink link;
  late FakeClock clock;
  late List<EngineEvent> events;
  late List<Duration> batchTimes;
  late List<Future<void>> closing;
  late int lost;
  late int ended;

  setUp(() {
    link = ScriptedLink();
    clock = FakeClock();
    events = [];
    batchTimes = [];
    closing = [];
    lost = 0;
    ended = 0;
  });

  LogFollower follower(LogStreamSpec spec) => LogFollower(
    streamId: 'follow-1',
    spec: spec,
    emit: (event) {
      events.add(event);
      if (event is LogBatch) batchTimes.add(clock.elapsed);
    },
    onLost: () => lost++,
    onEnded: () => ended++,
    track: closing.add,
    elapsed: () => clock.elapsed,
    quote: quoteShellWord,
    startTimer: clock.startTimer,
  );

  List<LogBatch> batches() => events.whereType<LogBatch>().toList();

  List<String?> messages() => [
    for (final batch in batches())
      for (final record in batch.records) (record as JournalRecord).message,
  ];

  List<LogStreamStatus> ends() => [
    for (final event in events)
      if (event case LogStreamState(:final status)) status,
  ];

  group('commands', () {
    test('a journal follow reads its window, then follows, and leaves '
        'the time range to the engine', () async {
      final f = follower(
        _spec(
          JournalLogSource(
            unit: 'nginx.service',
            priority: LogPriority.warning,
            since: DateTime.utc(2026, 10, 15),
          ),
        ),
      );
      expect(f.run(link), LogContinuity.complete);
      expect(
        link.commands.single,
        _cmd([
          ..._journal,
          ...['-u', 'nginx.service', '-p', '4', '-n', '500', '-f'],
        ]),
      );

      // journalctl up to 253 would print the oldest records in range;
      // the engine skips the ones older than it instead.
      (await link.process(0)).emitText(
        _entry(1, at: DateTime.utc(2026, 10, 14)) +
            _entry(2, at: DateTime.utc(2026, 10, 15, 1)),
      );
      await clock.elapse(Duration.zero);
      expect(messages(), ['entry 2']);
      expect(batches().single.dropped, 0);
    });

    test('the kernel log follows journalctl -k -b; after the app\'s cursor '
        'it prints every record after it', () {
      follower(_spec(const KernelLogSource(), window: 0)).run(link);
      follower(_spec(const KernelLogSource(), after: 's=9')).run(link);
      expect(link.commands, [
        _cmd([..._journal, '-k', '-b', '-n', '0', '-f']),
        _cmd([
          ..._journal,
          '-k',
          '-b',
          '--after-cursor=s=9',
          '--no-tail',
          '-f',
        ]),
      ]);
    });

    test('a file follows tail -F', () {
      follower(_spec(const FileLogSource('/var/log/syslog'))).run(link);
      expect(
        link.commands.single,
        _cmd([
          ...['tail', '-n', '500', '-F', '--', '/var/log/syslog'],
        ]),
      );
    });

    test('a journal follow passes its pattern as -g', () {
      follower(_spec(const JournalLogSource(grep: 'oom'))).run(link);
      expect(
        link.commands.single,
        _cmd([..._journal, '-n', '500', '-f', '-g', 'oom']),
      );
    });

    test('refuses a past boot and a compressed file, which never grow', () {
      for (final source in [
        const JournalLogSource(boot: JournalBoot.offset(-1)),
        const KernelLogSource(boot: JournalBoot.offset(-1)),
        const FileLogSource('/var/log/syslog.2.gz', compressed: true),
      ]) {
        expect(LogFollower.accepts(_spec(source)), isFalse, reason: '$source');
      }
    });

    test('refuses a window above 500 and what 8.8 refuses', () {
      expect(LogFollower.accepts(_spec(const JournalLogSource())), isTrue);
      for (final spec in [
        _spec(const JournalLogSource(), window: kLogWindowMax + 1),
        _spec(const FileLogSource('var/log/syslog')),
        _spec(const JournalLogSource(unit: 'a; reboot')),
      ]) {
        expect(LogFollower.accepts(spec), isFalse, reason: '${spec.source}');
      }
    });
  });

  group('ring and rate', () {
    test('a batch goes at most every 50 ms and takes every line held, '
        'oldest first', () async {
      follower(_spec(const JournalLogSource())).run(link);
      final p = await link.process(0);

      p.emitText(_entries(1, 3));
      await clock.elapse(Duration.zero);
      expect(batches(), hasLength(1));

      p.emitText(_entries(4, 6));
      await clock.elapse(const Duration(milliseconds: 49));
      expect(batches(), hasLength(1));
      p.emitText(_entries(7, 7));
      await clock.elapse(const Duration(milliseconds: 1));
      expect(batches(), hasLength(2));
      expect(messages(), [for (var n = 1; n <= 7; n++) 'entry $n']);
    });

    test("a redacted file's lines pass the secret redactor", () async {
      follower(
        _spec(
          const FileLogSource(
            '/home/u/x/klabautermann/ops/a.log',
            redacted: true,
          ),
        ),
      ).run(link);
      final p = await link.process(0);
      p.emitText('login $_token ok\n');
      await clock.elapse(const Duration(milliseconds: 100));
      final text = (batches().single.records.single as FileRecord).text;
      expect(text, isNot(contains(_token)));
      expect(text, startsWith('login '));
    });

    test('1,000 lines/s with a 10 s stall: at most 20 batches in any '
        'second, at most 50 ms of lines held while it keeps up, the ring\'s '
        'cap during the stall, and every line sent or counted', () async {
      follower(_spec(const FileLogSource('/var/log/app.log'))).run(link);
      final p = await link.process(0);

      var line = 0;
      String lines(int count) => [
        for (var i = 0; i < count; i++) 'line ${line++} ${'x' * 80}\n',
      ].join();

      // 10 lines every 10 ms, in two chunks that split a line.
      Future<void> steady(Duration span) async {
        for (var tick = 0; tick < span.inMilliseconds ~/ 10; tick++) {
          final text = lines(10);
          final cut = tick % 7 + 1;
          p
            ..emitText(text.substring(0, cut))
            ..emitText(text.substring(cut));
          await clock.elapse(const Duration(milliseconds: 10));
        }
      }

      await steady(const Duration(seconds: 10));
      final beforeStall = batches().length;
      // The engine falls 10 s behind: the lines arrive with no beat
      // between them.
      p.emitText(lines(10000));
      await clock.elapse(const Duration(seconds: 10));
      await steady(const Duration(seconds: 5));
      await clock.elapse(const Duration(milliseconds: 50));

      var sent = 0;
      var dropped = 0;
      var last = -1;
      for (final (i, batch) in batches().indexed) {
        final cap = i == beforeStall ? kFollowRingLines : 50;
        expect(batch.records.length, lessThanOrEqualTo(cap), reason: '$i');
        dropped += batch.dropped;
        for (final record in batch.records) {
          final n = int.parse((record as FileRecord).text.split(' ')[1]);
          expect(n, greaterThan(last));
          last = n;
          sent++;
        }
      }
      expect(dropped, 10000 - kFollowRingLines);
      expect(sent + dropped, line);
      expect(batches()[beforeStall].dropped, dropped);
      for (var i = 0; i + 20 < batchTimes.length; i++) {
        expect(
          batchTimes[i + 20] - batchTimes[i],
          greaterThanOrEqualTo(const Duration(seconds: 1)),
        );
      }
    });

    test('a burst over the ring drops the oldest lines and counts them in '
        'the next batch, by lines and by bytes', () async {
      follower(_spec(const FileLogSource('/var/log/app.log'))).run(link);
      final p = await link.process(0);

      p.emitText([for (var n = 0; n < 12000; n++) '$n\n'].join());
      await clock.elapse(Duration.zero);
      final batch = batches().single;
      expect(batch.dropped, 12000 - kFollowRingLines);
      expect(batch.records, hasLength(kFollowRingLines));
      expect((batch.records.first as FileRecord).text, '7000');
      expect((batch.records.last as FileRecord).text, '11999');

      // 80 lines of 64 KiB with their line breaks; 4 MiB holds 64.
      final long = 'y' * (64 * 1024 - 1);
      p.emitText([for (var n = 0; n < 80; n++) '$long\n'].join());
      await clock.elapse(const Duration(milliseconds: 50));
      expect(batches().last.dropped, 16);
      expect(batches().last.records, hasLength(64));
    });

    test('a journal entry over the line cap and a line that is no JSON '
        'are dropped; a file line keeps its first bytes', () async {
      follower(_spec(const JournalLogSource())).run(link);
      final p = await link.process(0);
      p
        ..emitText('{"MESSAGE":"${'z' * kFollowLineMaxBytes}"}\n')
        ..emitText('not json\n')
        ..emitText(_entry(1));
      await clock.elapse(Duration.zero);
      expect(batches().single.dropped, 2);
      expect(messages(), ['entry 1']);

      events.clear();
      final files = ScriptedLink();
      follower(_spec(const FileLogSource('/var/log/app.log'))).run(files);
      (await files.process(
        0,
      )).emitText('${'w' * (kFollowLineMaxBytes + 9)}\r\nnext\n');
      await clock.elapse(Duration.zero);
      final records = batches().single.records.cast<FileRecord>();
      expect(records.map((r) => r.text.length), [kFollowLineMaxBytes, 4]);
    });
  });

  group('resume', () {
    test('a journal follow resumes after the newest cursor received, held '
        'lines included, and sends those first', () async {
      final f = follower(_spec(const JournalLogSource(unit: 'a.service')));
      f.run(link);
      final first = await link.process(0);
      first.emitText(_entries(1, 2));
      await clock.elapse(Duration.zero);

      // 10 ms after a batch, entries 3 and 4 wait for the next.
      first.emitText(_entries(3, 4));
      await clock.elapse(const Duration(milliseconds: 10));
      expect(f.pause(), isTrue);
      await pumpEventQueue();
      expect(first.closeCalls, 1);
      expect(messages(), ['entry 1', 'entry 2']);
      await clock.elapse(const Duration(seconds: 5));
      expect(batches(), hasLength(1), reason: 'no timer while paused');

      expect(f.run(link), LogContinuity.complete);
      expect(
        link.commands[1],
        _cmd([
          ..._journal,
          ...['-u', 'a.service', '--after-cursor=s=4', '--no-tail', '-f'],
        ]),
      );
      (await link.process(1)).emitText(_entries(5, 5));
      await clock.elapse(Duration.zero);
      expect(messages(), [for (var n = 1; n <= 5; n++) 'entry $n']);
    });

    test('a pause sends what is held when the rate allows', () async {
      final f = follower(_spec(const JournalLogSource()));
      f.run(link);
      (await link.process(0)).emitText(_entries(1, 1));
      await pumpEventQueue();
      expect(f.pause(), isTrue);
      expect(messages(), ['entry 1']);
    });

    test('a cursor the validator refuses is never resumed after', () async {
      final f = follower(_spec(const JournalLogSource()));
      f.run(link);
      (await link.process(
        0,
      )).emitText(_entry(1) + _entry(2, cursor: r's=1;$(reboot)'));
      await clock.elapse(Duration.zero);
      f
        ..pause()
        ..run(link);
      expect(
        link.commands[1],
        _cmd([
          ..._journal,
          ...['--after-cursor=s=1', '--no-tail', '-f'],
        ]),
      );
    });

    test('a file restarts with only new lines and says lines may be '
        'missing; before any line it reads its window again', () async {
      final f = follower(_spec(const FileLogSource('/var/log/app.log')));
      f.run(link);
      expect(f.pause(), isTrue);
      expect(f.run(link), LogContinuity.complete);
      (await link.process(1)).emitText('one\n');
      await clock.elapse(Duration.zero);
      f.pause();
      expect(f.run(link), LogContinuity.gap);

      const path = '/var/log/app.log';
      expect(link.commands.skip(1), [
        _cmd(['tail', '-n', '500', '-F', '--', path]),
        _cmd(['tail', '-n', '0', '-F', '--', path]),
      ]);
    });
  });

  group('ends', () {
    test('an exit sends the held lines as the rate allows, then the end '
        'with the host\'s words; even exit 0 fails', () async {
      final f = follower(_spec(const JournalLogSource()));
      f.run(link);
      final p = await link.process(0);
      p.emitText(_entries(1, 1));
      await clock.elapse(Duration.zero);
      p
        ..emitText(_entries(2, 2))
        ..emitStderr(utf8.encode('journalctl: unrecognized option\n'))
        ..end(const RemoteExit(exitCode: 1));
      await pumpEventQueue();
      expect(ends(), isEmpty, reason: 'entry 2 waits for the beat');
      expect(f.pause(), isFalse, reason: 'ending');

      await clock.elapse(const Duration(milliseconds: 50));
      expect(messages(), ['entry 1', 'entry 2']);
      expect(ends(), [
        const LogStreamEnded(
          LogStreamEndReason.missing,
          detail: 'journalctl: unrecognized option',
        ),
      ]);
      expect(ended, 1);

      events.clear();
      follower(_spec(const KernelLogSource())).run(link);
      (await link.process(1)).end();
      await pumpEventQueue();
      expect(ends(), [const LogStreamEnded(LogStreamEndReason.failed)]);
    });

    test('a file tail -F cannot open ends as denied before its first line, '
        'and retries after one', () async {
      follower(_spec(const FileLogSource('/var/log/auth.log'))).run(link);
      final p = await link.process(0);
      p
        ..emitStderr(utf8.encode("tail: cannot open '/var/log/auth.log' "))
        ..emitStderr(utf8.encode('for reading: Permission denied\n'));
      await pumpEventQueue();
      expect(ends(), [
        const LogStreamEnded(
          LogStreamEndReason.denied,
          detail:
              "tail: cannot open '/var/log/auth.log' for reading: "
              'Permission denied',
        ),
      ]);
      expect(p.closeCalls, 1);

      events.clear();
      follower(_spec(const FileLogSource('/var/log/app.log'))).run(link);
      final q = await link.process(1);
      q.emitText('one\n');
      await pumpEventQueue();
      q.emitStderr(
        utf8.encode(
          "tail: '/var/log/app.log' has become inaccessible: "
          'No such file or directory\n',
        ),
      );
      await clock.elapse(Duration.zero);
      expect(ends(), isEmpty);
      expect(q.closeCalls, 0);
    });

    test('a rotation of a still empty file keeps the follow; only the '
        'first open ends it, BusyBox\'s words included', () async {
      const path = '/var/log/nginx/error.log';
      follower(_spec(const FileLogSource(path))).run(link);
      final p = await link.process(0);
      // GNU tail 9.4 as logrotate's create renames the file and makes a
      // new one a moment later; BusyBox prints the same first line.
      p.emitStderr(
        utf8.encode(
          "tail: '$path' has become inaccessible: No such file or directory\n"
          "tail: '$path' has appeared;  following new file\n",
        ),
      );
      await pumpEventQueue();
      expect(ends(), isEmpty);
      expect(p.closeCalls, 0);
      p.emitText('after rotation\n');
      await clock.elapse(Duration.zero);
      final records = batches().single.records.cast<FileRecord>();
      expect(records.map((r) => r.text), ['after rotation']);

      events.clear();
      follower(_spec(const FileLogSource('/var/log/app.log'))).run(link);
      (await link.process(1)).emitStderr(
        utf8.encode(
          "tail: can't open '/var/log/app.log': No such file or directory\n",
        ),
      );
      await pumpEventQueue();
      expect(ends(), [
        const LogStreamEnded(
          LogStreamEndReason.missing,
          detail:
              "tail: can't open '/var/log/app.log': No such file or directory",
        ),
      ]);
    });

    test('a resumed file follow whose open fails ends as its first run '
        'would, though the stream had lines', () async {
      const path = '/var/log/app.log';
      final f = follower(_spec(const FileLogSource(path)));
      f.run(link);
      (await link.process(0)).emitText('one\n');
      await clock.elapse(Duration.zero);
      f.pause();
      expect(f.run(link), LogContinuity.gap);

      // GNU tail 9.4 after the file was deleted while paused.
      const words =
          "tail: cannot open '$path' for reading: No such file or directory";
      final p = await link.process(1);
      p.emitStderr(utf8.encode('$words\n'));
      await pumpEventQueue();
      expect(ends(), [
        const LogStreamEnded(LogStreamEndReason.missing, detail: words),
      ]);
      expect(p.closeCalls, 1);
    });

    test('a journal follow keeps running when stderr names a refusal, as '
        'journalctl warns of a file it cannot read', () async {
      follower(_spec(const JournalLogSource())).run(link);
      final p = await link.process(0);
      p.emitStderr(
        utf8.encode(
          'Error was encountered while opening journal file or directory '
          '/var/log/journal/m/user-1000.journal, ignoring file: '
          'Permission denied\n',
        ),
      );
      await pumpEventQueue();
      p.emitText(_entries(1, 1));
      await clock.elapse(Duration.zero);
      expect(ends(), isEmpty);
      expect(p.closeCalls, 0);
      expect(messages(), ['entry 1']);
    });

    test('a file line loses its CR, and a last line without a line break '
        'goes out before the end', () async {
      follower(_spec(const FileLogSource('/var/log/app.log'))).run(link);
      (await link.process(0))
        ..emitText('one\r\nlast')
        ..end(const RemoteExit(exitCode: 1));
      await clock.elapse(Duration.zero);
      final records = batches().single.records.cast<FileRecord>();
      expect(records.map((r) => r.text), ['one', 'last']);
      expect(ends(), [const LogStreamEnded(LogStreamEndReason.failed)]);
    });

    test('end discards held lines, closes the process and ends once', () async {
      final f = follower(_spec(const JournalLogSource()));
      f.run(link);
      final p = await link.process(0);
      p.emitText(_entries(1, 1));
      await pumpEventQueue();
      f
        ..end(const LogStreamEnded(LogStreamEndReason.closed))
        ..end(const LogStreamEnded(LogStreamEndReason.failed));
      await clock.elapse(const Duration(seconds: 1));
      expect(events, hasLength(1));
      expect(ends(), [const LogStreamEnded(LogStreamEndReason.closed)]);
      expect(ended, 1);
      await Future.wait(closing);
      expect(p.closeCalls, 1);
    });

    test('an end while the channel opens closes the late process', () async {
      final hold = link.holdNextStart = Completer<void>();
      follower(_spec(const JournalLogSource()))
        ..run(link)
        ..end(const LogStreamEnded(LogStreamEndReason.closed));
      hold.complete();
      await Future.wait(closing);
      expect((await link.process(0)).closeCalls, 1);
    });
  });

  group('a lost process', () {
    test('on a closed link waits for the next one, without an end', () async {
      final f = follower(_spec(const JournalLogSource()));
      f.run(link);
      final p = await link.process(0);
      link.state = const SshLinkClosed(SshLinkClosedReason.linkLost);
      p.end(const RemoteExit());
      await pumpEventQueue();
      expect(lost, 1);
      expect(ends(), isEmpty);

      final next = ScriptedLink();
      f.run(next);
      expect(next.commands, hasLength(1));
    });

    test('on a live link runs once more, and fails when lost there again '
        'without a line between', () async {
      final f = follower(_spec(const JournalLogSource()));
      f.run(link);
      (await link.process(0)).end(const RemoteExit());
      await pumpEventQueue();
      expect(lost, 1);

      f.run(link);
      final again = await link.process(1);
      again.emitText(_entries(1, 1));
      await pumpEventQueue();
      again.end(const RemoteExit());
      await pumpEventQueue();
      expect(lost, 2, reason: 'a line arrived between the losses');

      // Lost at once again, as a refused channel: failed, once the held
      // entry went.
      link.startFailures.add(StateError('channel refused'));
      f.run(link);
      await clock.elapse(const Duration(milliseconds: 50));
      expect(lost, 2);
      expect(messages(), ['entry 1']);
      expect(ends(), [const LogStreamEnded(LogStreamEndReason.failed)]);
    });

    test('drops its partial last line, which the resume sends whole, so '
        'no entry both arrives and counts as dropped', () async {
      final f = follower(_spec(const JournalLogSource()));
      f.run(link);
      final p = await link.process(0);
      p.emitText(_entry(1));
      await clock.elapse(Duration.zero);
      p
        ..emitText(_entry(2).substring(0, 20))
        ..end(const RemoteExit());
      await clock.elapse(const Duration(milliseconds: 50));
      expect(lost, 1);

      f.run(link);
      expect(
        link.commands[1],
        _cmd([..._journal, '--after-cursor=s=1', '--no-tail', '-f']),
      );
      (await link.process(1)).emitText(_entry(2));
      await clock.elapse(const Duration(milliseconds: 50));
      expect(messages(), ['entry 1', 'entry 2']);
      expect(batches().map((batch) => batch.dropped), [0, 0]);
    });
  });
}
