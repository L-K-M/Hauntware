// LogService against scripted processes (03 §7.6, §10.1): the test plays
// each host command's output and exit and reads the events the service
// sends.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/log_service.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:seance_core/seance_core.dart'
    show RemoteExit, SshLinkClosed, SshLinkClosedReason, quoteShellWord;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

/// The command line of [argv], given as one string split at spaces.
String _command(String argv) =>
    HostCommands.commandLine(argv.split(' '), quote: quoteShellWord);

LogStreamSpec _spec(LogSource source, {int window = 500, String? after}) =>
    LogStreamSpec(
      serverId: 'srv-1',
      source: source,
      window: window,
      follow: false,
      afterCursor: after,
    );

const _filled = LogStreamEnded(LogStreamEndReason.windowFilled);
const _oldest = LogStreamEnded(LogStreamEndReason.oldestReached);
const _failed = LogStreamEnded(LogStreamEndReason.failed);
const _kernel = KernelLogSource();
const _journal = JournalLogSource();

String _cursor(int n) => 's=ab12;i=${n.toRadixString(16)}';

DateTime _at(int n) => DateTime.utc(2026, 10, 15, 12).add(Duration(minutes: n));

/// Journal entries [from] down to [to] as `journalctl -o json -r` prints
/// them: a higher number is newer.
String _entries(int from, int to) => [
  for (var n = from; n >= to; n--)
    '${jsonEncode({'__CURSOR': _cursor(n), '__REALTIME_TIMESTAMP': '${_at(n).microsecondsSinceEpoch}', 'PRIORITY': '6', 'MESSAGE': 'entry $n'})}\n',
].join();

/// A `dmesg --json --decode` ring of records 1 to [count], oldest first,
/// laid out as util-linux prints it: one member per line.
String _ring([int count = 5]) {
  final records = [
    for (var n = 1; n <= count; n++)
      [
        for (final (key, value) in [
          ('fac', 'kern'),
          ('pri', n.isEven ? 'warn' : 'info'),
          ('time', n * 1.5),
          ('msg', 'ring $n'),
        ])
          '         "$key": ${jsonEncode(value)}',
      ].join(',\n'),
  ];
  return '{\n   "dmesg": [\n      {\n'
      '${records.join('\n      },{\n')}\n      }\n   ]\n}\n';
}

/// Plays [text] on [process] in 64-byte chunks, as a channel delivers it.
void _emitChunks(ScriptedProcess process, String text) {
  for (var i = 0; i < text.length; i += 64) {
    process.emitText(text.substring(i, (i + 64).clamp(0, text.length)));
  }
}

Future<void> _until(bool Function() condition) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late ScriptedLink link;
  late List<EngineEvent> events;
  late LogService service;

  void start({
    int maxOutputBytes = kLogReadMaxOutputBytes,
    Duration deadline = kLogReadDeadline,
  }) {
    service = LogService(
      link: link,
      quote: quoteShellWord,
      emit: events.add,
      maxOutputBytes: maxOutputBytes,
      deadline: deadline,
    );
    addTearDown(service.close);
  }

  setUp(() {
    link = ScriptedLink();
    events = [];
    start();
  });

  List<LogStreamStatus> statuses(String id) => [
    for (final e in events)
      if (e case LogStreamState(:final streamId, :final status))
        if (streamId == id) status,
  ];

  List<LogRecord> records(String id) => [
    for (final e in events)
      if (e case LogBatch(:final streamId, :final records))
        if (streamId == id) ...records,
  ];

  List<String?> cursors(String id) => [
    for (final r in records(id)) (r as JournalRecord).cursor,
  ];

  List<String> texts(String id) => [
    for (final r in records(id))
      switch (r) {
        KernelRecord(:final message) => message,
        FileRecord(:final text) => text,
        JournalRecord(:final message) => message ?? '<null>',
        ContainerRecord(:final text) => text,
      },
  ];

  Future<LogStreamEnded> ended(String id) async {
    await _until(() => statuses(id).lastOrNull is LogStreamEnded);
    return statuses(id).last as LogStreamEnded;
  }

  /// Opens [id] on [spec]; completes with the first command's process.
  Future<ScriptedProcess> open(String id, LogStreamSpec spec) {
    final index = link.processes.length;
    service.open(id, spec);
    return link.process(index);
  }

  /// Plays [stdout], [stderr] and [exit] on [process].
  Future<LogStreamEnded> play(
    String id,
    Future<ScriptedProcess> process, {
    String stdout = '',
    String stderr = '',
    int exit = 0,
  }) async {
    (await process)
      ..emitText(stdout)
      ..emitStderr(utf8.encode(stderr))
      ..end(RemoteExit(exitCode: exit));
    return ended(id);
  }

  /// Opens [id] and plays one command's output and exit.
  Future<LogStreamEnded> read(
    String id,
    LogStreamSpec spec, {
    String stdout = '',
    String stderr = '',
    int exit = 0,
  }) => play(id, open(id, spec), stdout: stdout, stderr: stderr, exit: exit);

  /// Opens the kernel log [id], whose journal read finds nothing, and
  /// completes with the dmesg fallback's process.
  Future<ScriptedProcess> fallBackProcess(String id, {int window = 500}) async {
    final journal = link.processes.length;
    (await open(id, _spec(_kernel, window: window))).end();
    return link.process(journal + 1);
  }

  Future<LogStreamEnded> fallBack(
    String id, {
    int window = 500,
    String stdout = '',
    String stderr = '',
    int exit = 0,
  }) => play(
    id,
    fallBackProcess(id, window: window),
    stdout: stdout,
    stderr: stderr,
    exit: exit,
  );

  group('journal windows', () {
    test('read the newest records, newest first', () async {
      final spec = _spec(_journal, window: 3);
      expect(await read('a', spec, stdout: _entries(9, 7)), _filled);
      expect(link.commands, [
        _command('journalctl -o json --no-pager -n 3 -r'),
      ]);
      expect(statuses('a'), [const LogStreamRunning(), _filled]);
      expect(cursors('a'), [_cursor(9), _cursor(8), _cursor(7)]);
      expect((records('a').first as JournalRecord).at, _at(9));
    });

    test('page by cursor across windows to the oldest record', () async {
      // The journal holds entries 1 to 5; each page reads on from the
      // last cursor of the one before.
      final pages = [_entries(5, 4), _entries(3, 2), _entries(1, 1)];
      final ends = <LogStreamEnded>[];
      String? after;
      for (final (i, page) in pages.indexed) {
        final spec = _spec(_journal, window: 2, after: after);
        ends.add(await read('p$i', spec, stdout: page));
        after = cursors('p$i').last;
      }
      expect(link.commands.first, isNot(contains('--after-cursor')));
      expect(link.commands[1], contains("'--after-cursor=${_cursor(4)}'"));
      expect(link.commands[2], contains("'--after-cursor=${_cursor(2)}'"));
      expect(
        [for (var i = 0; i < 3; i++) ...cursors('p$i')],
        [for (var n = 5; n >= 1; n--) _cursor(n)],
      );
      expect(ends, [_filled, _filled, _oldest]);
    });

    test('the filters reach journalctl; since stays off after a cursor', () {
      final since = DateTime.utc(2026, 10, 15);
      final until = DateTime.utc(2026, 10, 16);
      final source = JournalLogSource(
        unit: 'nginx.service',
        identifier: 'sshd',
        priority: LogPriority.warning,
        currentBootOnly: true,
        since: since,
        until: until,
      );
      service
        ..open('a', _spec(source))
        ..open('b', _spec(source, after: _cursor(4)));
      String seconds(DateTime t) => '@${t.millisecondsSinceEpoch ~/ 1000}';
      const filters = "'-b' '-u' 'nginx.service' '-t' 'sshd' '-p' '4'";
      expect(link.commands, [
        endsWith(
          "$filters '--since=${seconds(since)}' "
          "'--until=${seconds(until)}' '-n' '500' '-r'",
        ),
        endsWith(
          "$filters '--until=${seconds(until)}' "
          "'--after-cursor=${_cursor(4)}' '-n' '500' '-r'",
        ),
      ]);
    });

    test('after a cursor the window ends at the first record older than '
        'since', () async {
      final spec = _spec(JournalLogSource(since: _at(5)), after: _cursor(9));
      expect(await read('a', spec, stdout: _entries(8, 3)), _oldest);
      expect(cursors('a'), [for (var n = 8; n >= 5; n--) _cursor(n)]);
    });

    test('unit logs are one 50-record window, newest first', () async {
      final spec = _spec(const JournalLogSource(unit: 'a.service'), window: 50);
      expect(await read('u', spec, stdout: _entries(50, 1)), _filled);
      expect(link.commands.single, endsWith("'-u' 'a.service' '-n' '50' '-r'"));
      expect(cursors('u'), [for (var n = 50; n >= 1; n--) _cursor(n)]);
    });

    test('a cut at maxOutputBytes keeps whole records and says the window '
        'filled', () async {
      start(maxOutputBytes: _entries(10, 8).length + 40);
      final p = await open('a', _spec(_journal, window: 10));
      // The process never ends: the read stops at the cap.
      _emitChunks(p, _entries(10, 1));
      expect(await ended('a'), _filled);
      expect(cursors('a'), [_cursor(10), _cursor(9), _cursor(8)]);
      await _until(() => p.closeCalls == 1);
    });

    test('an entry longer than the cap is dropped and fails the window, '
        'which has no cursor to read on from', () async {
      start(maxOutputBytes: 1024);
      final p = await open('a', _spec(_journal, window: 10));
      final huge = {for (var i = 0; i < 8; i++) 'F$i': 'x' * 1000};
      _emitChunks(p, '${jsonEncode(huge)}\n${_entries(10, 1)}');
      expect(await ended('a'), _failed);
      expect(events.whereType<LogBatch>().single.dropped, 1);
      expect(records('a'), isEmpty);
    });

    test('the default cap holds a full window of large entries', () async {
      // About 1.5 KiB each, 750 KiB in all: past SshLink.run's 256 KiB.
      final stdout = [
        for (var n = 500; n >= 1; n--)
          '${jsonEncode({'__CURSOR': _cursor(n), 'F': 'f' * 1450})}\n',
      ].join();
      expect(await read('a', _spec(_journal), stdout: stdout), _filled);
      expect(records('a'), hasLength(500));
    });

    test('a line that is not a JSON object is dropped and counted', () async {
      final stdout =
          '${_entries(3, 3)}{"MESSAGE": "cut\n[1]\n-- No entries --\n'
          '${_entries(1, 1)}';
      final spec = _spec(_journal, window: 4);
      expect(await read('a', spec, stdout: stdout), _filled);
      expect(events.whereType<LogBatch>().single.dropped, 2);
      expect(cursors('a'), [_cursor(3), _cursor(1)]);
    });

    test('a host printing more than the window is cut at it', () async {
      final spec = _spec(_journal, window: 2);
      expect(await read('a', spec, stdout: _entries(9, 1)), _filled);
      expect(cursors('a'), [_cursor(9), _cursor(8)]);
    });
  });

  group('kernel log', () {
    test('reads journalctl -k -b and keeps its records', () async {
      final spec = _spec(_kernel, window: 2);
      expect(await read('k', spec, stdout: _entries(2, 1)), _filled);
      expect(link.commands, [
        _command('journalctl -o json --no-pager -k -b -n 2 -r'),
      ]);
      expect(records('k'), everyElement(isA<JournalRecord>()));
      expect(statuses('k'), [const LogStreamRunning(), _filled]);
    });

    test('falls back to dmesg when the journal has no kernel record, and '
        'says so', () async {
      expect(await fallBack('k', stdout: _ring()), _oldest);
      expect(link.commands.last, _command('dmesg --json --decode'));
      expect(statuses('k').take(2), [
        const LogStreamRunning(),
        const LogStreamRunning(reader: LogReader.fallback),
      ]);
      expect(texts('k'), [for (var n = 5; n >= 1; n--) 'ring $n']);
      final kernel = records('k').cast<KernelRecord>();
      expect(kernel.map((r) => r.priority).take(2), [
        LogPriority.info,
        LogPriority.warning,
      ]);
      expect(kernel.first.sinceBoot, const Duration(milliseconds: 7500));
    });

    test('a ring longer than the window gives its newest records', () async {
      expect(await fallBack('k', window: 3, stdout: _ring()), _filled);
      expect(texts('k'), ['ring 5', 'ring 4', 'ring 3']);
    });

    test('a ring past maxOutputBytes keeps its newest whole records', () async {
      final ring = _ring(9);
      // The kept tail starts inside record 6.
      start(maxOutputBytes: ring.length - ring.indexOf('"msg": "ring 6"'));
      final dmesg = await fallBackProcess('k', window: 5);
      _emitChunks(dmesg, ring);
      dmesg.end();
      expect(await ended('k'), _filled);
      expect(texts('k'), ['ring 9', 'ring 8', 'ring 7']);
    });

    test('a cut that keeps no whole record counts the newest as '
        'dropped', () async {
      start(maxOutputBytes: 16);
      final dmesg = await fallBackProcess('k');
      dmesg
        ..emitText(
          '{\n   "dmesg": [\n      {\n         "pri": "info",\n'
          '         "msg": "${'x' * 40}"\n      }\n   ]\n}\n',
        )
        ..end();
      expect(await ended('k'), _filled);
      expect(records('k'), isEmpty);
      expect(events.whereType<LogBatch>().single.dropped, 1);
    });

    test("a missing journalctl falls back; dmesg's refusal ends it", () async {
      (await open('k', _spec(_kernel)))
        ..emitStderr(utf8.encode('sh: 1: exec: journalctl: not found\n'))
        ..end(const RemoteExit(exitCode: 127));
      const refusal =
          'dmesg: read kernel buffer failed: Operation not permitted';
      final end = await play(
        'k',
        link.process(1),
        stderr: '$refusal\n',
        exit: 1,
      );
      expect(
        end,
        const LogStreamEnded(LogStreamEndReason.denied, detail: refusal),
      );
      expect(records('k'), isEmpty);
    });

    test('a dmesg without --json reads as missing', () async {
      final end = await fallBack(
        'k',
        stderr: "dmesg: unrecognized option '--json'\n",
        exit: 1,
      );
      expect(end.reason, LogStreamEndReason.missing);
    });

    test('a signal or a lost link ends it as failed, without dmesg', () async {
      final killed = await open('s', _spec(_kernel));
      killed.end(const RemoteExit(exitSignal: 'KILL'));
      await _until(() => statuses('s').length == 2);
      expect(statuses('s'), [const LogStreamRunning(), _failed]);

      final p = await open('k', _spec(_kernel));
      p.emitStderr(utf8.encode('journal read interrupted\n'));
      link.state = const SshLinkClosed(SshLinkClosedReason.pingTimeout);
      p.end(const RemoteExit());
      await _until(() => statuses('k').length == 2);
      expect(statuses('k'), [
        const LogStreamRunning(),
        const LogStreamEnded(
          LogStreamEndReason.failed,
          detail: 'journal read interrupted',
        ),
      ]);

      const notice = 'insufficient permissions to read the kernel log';
      (await open('d', _spec(_kernel)))
        ..emitStderr(utf8.encode('$notice\n'))
        ..end(const RemoteExit(exitSignal: 'TERM'));
      await _until(() => statuses('d').length == 2);
      expect(statuses('d'), [
        const LogStreamRunning(),
        const LogStreamEnded(LogStreamEndReason.failed, detail: notice),
      ]);
      expect(link.commands, hasLength(3));
    });

    test('an empty page after a cursor is the oldest record', () async {
      expect(await read('k', _spec(_kernel, after: _cursor(1))), _oldest);
      expect(link.commands, [
        _command(
          'journalctl -o json --no-pager -k -b '
          '--after-cursor=${_cursor(1)} -n 500 -r',
        ),
      ]);
    });
  });

  group('file', () {
    const syslog = FileLogSource('/var/log/syslog');

    test('tail reads the last lines newest first, without breaks', () async {
      final spec = _spec(syslog, window: 3);
      expect(await read('f', spec, stdout: 'one\r\ntwo\nthree\n'), _filled);
      expect(link.commands.single, _command('tail -n 3 -- /var/log/syslog'));
      expect(texts('f'), ['three', 'two', 'one']);
    });

    test('a short file reaches its oldest line, an open one too', () async {
      expect(await read('f', _spec(syslog), stdout: 'one\ntwo'), _oldest);
      expect(texts('f'), ['two', 'one']);
    });

    test('a cut keeps the newest lines', () async {
      start(maxOutputBytes: 16);
      final p = await open('f', _spec(syslog, window: 9));
      for (var n = 1; n <= 9; n++) {
        p.emitText('line-$n\n');
      }
      p.end();
      expect(await ended('f'), _filled);
      expect(texts('f'), ['line-9', 'line-8']);
    });

    test('a cut that keeps no whole line counts the newest as '
        'dropped', () async {
      start(maxOutputBytes: 16);
      final p = await open('f', _spec(syslog, window: 9));
      p
        ..emitText('x' * 40)
        ..end();
      expect(await ended('f'), _filled);
      expect(records('f'), isEmpty);
      expect(events.whereType<LogBatch>().single.dropped, 1);
    });

    test('a missing file reads as missing, an unreadable one denied', () async {
      const tail = "tail: cannot open '/var/log/syslog' for reading";
      for (final (error, reason) in [
        ('No such file or directory', LogStreamEndReason.missing),
        ('Permission denied', LogStreamEndReason.denied),
      ]) {
        final stderr = '$tail: $error\n';
        final end = await read(error, _spec(syslog), stderr: stderr, exit: 1);
        expect(end, LogStreamEnded(reason, detail: '$tail: $error'));
      }
    });
  });

  group('refused specs', () {
    test('are invalid and run nothing', () {
      final specs = {
        'relative': _spec(const FileLogSource('var/log/syslog')),
        'dotdot': _spec(const FileLogSource('/var/log/../shadow')),
        'unit': _spec(const JournalLogSource(unit: 'bad unit;rm')),
        'empty': _spec(_journal, window: 0),
        'huge': _spec(_journal, window: kLogWindowMax + 1),
      };
      expect(specs.values.where(LogService.accepts), isEmpty);
      expect(LogService.accepts(_spec(_journal)), isTrue);
      specs.forEach(service.open);
      for (final id in specs.keys) {
        expect(statuses(id), [
          const LogStreamEnded(LogStreamEndReason.invalid),
        ]);
      }
      expect(link.commands, isEmpty);
    });

    test('a follow, a reused open id and an open after close throw', () async {
      final follow = LogStreamSpec(
        serverId: 'srv-1',
        source: _journal,
        window: 10,
        follow: true,
      );
      expect(() => service.open('a', follow), throwsArgumentError);
      service.open('a', _spec(_journal));
      expect(() => service.open('a', _spec(_journal)), throwsStateError);
      await service.close();
      expect(() => service.open('b', _spec(_journal)), throwsStateError);
    });
  });

  group('errors and lifecycle', () {
    test(
      'stderr reaches the detail with control characters stripped',
      () async {
        final end = await read(
          'a',
          _spec(_journal),
          stderr: '\x1b[1mFailed to seek to cursor\x07: Invalid argument\r\n',
          exit: 1,
        );
        expect(
          end,
          const LogStreamEnded(
            LogStreamEndReason.failed,
            detail: '[1mFailed to seek to cursor: Invalid argument',
          ),
        );
      },
    );

    test('pause closes the process without an event, and the id opens '
        'again', () async {
      final p = await open('a', _spec(_journal));
      service
        ..pause('a')
        ..pause('a');
      await _until(() => p.closeCalls == 1);
      expect(statuses('a'), [const LogStreamRunning()]);

      expect(await read('a', _spec(_journal), stdout: _entries(2, 1)), _oldest);
      expect(statuses('a'), [
        const LogStreamRunning(),
        const LogStreamRunning(),
        _oldest,
      ]);
    });

    test('the detail keeps the end of a long stderr', () async {
      final stderr = '${'warning: skipped\n' * 400}Failed to open journal\n';
      final end = await read('a', _spec(_journal), stderr: stderr, exit: 1);
      expect(end.detail, endsWith('skipped\nFailed to open journal'));
      expect(end.detail!.length, lessThanOrEqualTo(kLogReadStderrBytes));
    });

    test('a signal ends the read as failed', () async {
      final p = await open('a', _spec(_journal));
      p.end(const RemoteExit(exitSignal: 'KILL'));
      expect(await ended('a'), _failed);
    });

    test('a signal or a lost link is failed whatever stderr names', () async {
      const refusal =
          'Failed to open /var/log/journal/x/user-1001.journal: '
          'Permission denied';
      const failed = LogStreamEnded(LogStreamEndReason.failed, detail: refusal);
      for (final (id, exit) in [
        ('s', const RemoteExit(exitSignal: 'KILL')),
        ('l', const RemoteExit()),
      ]) {
        (await open(id, _spec(_journal)))
          ..emitStderr(utf8.encode('$refusal\n'))
          ..emitText(_entries(3, 1))
          ..end(exit);
        expect(await ended(id), failed, reason: id);
        expect(records(id), hasLength(3), reason: id);
      }
    });

    test('a deadline ends the read as failed and closes the process', () async {
      start(deadline: const Duration(milliseconds: 50));
      final p = await open('a', _spec(_journal));
      p.emitStderr(utf8.encode('still reading\n'));
      expect(
        await ended('a'),
        const LogStreamEnded(
          LogStreamEndReason.failed,
          detail: 'still reading',
        ),
      );
      expect(p.closeCalls, 1);
      expect(records('a'), isEmpty);
    });

    test(
      'closeStream ends the read as closed and closes the process',
      () async {
        final p = await open('a', _spec(_journal));
        service.closeStream('a');
        expect(statuses('a'), [
          const LogStreamRunning(),
          const LogStreamEnded(LogStreamEndReason.closed),
        ]);

        // What the host sends afterwards goes nowhere.
        p
          ..emitText(_entries(3, 1))
          ..end();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        service
          ..closeStream('a')
          ..closeStream('never-opened');
        expect(events, hasLength(2));
        expect(p.closeCalls, 1);
      },
    );

    test(
      'a read closed while its channel opens closes the late process',
      () async {
        final hold = link.holdNextStart = Completer<void>();
        service
          ..open('a', _spec(_journal))
          ..closeStream('a');
        final closed = service.close();
        hold.complete();
        await closed;
        expect(link.processes.single.closeCalls, 1);
        expect(
          statuses('a').last,
          const LogStreamEnded(LogStreamEndReason.closed),
        );
      },
    );

    test('a link that closes under the read ends it as failed', () async {
      final p = await open('a', _spec(_journal));
      link.state = const SshLinkClosed(SshLinkClosedReason.pingTimeout);
      p.end(const RemoteExit());
      expect(await ended('a'), _failed);

      // And a read whose channel cannot open on the closed link.
      link.startFailures.add(StateError('link closed'));
      service.open('b', _spec(_journal));
      expect(await ended('b'), _failed);
    });

    test(
      'close ends open reads as failed and waits for their processes',
      () async {
        final p = await open('a', _spec(_journal));
        final hold = p.holdClose = Completer<void>();
        var done = false;
        unawaited(service.close().then((_) => done = true));
        expect(statuses('a').last, _failed);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(done, isFalse);
        hold.complete();
        await _until(() => done);
      },
    );
  });

  group('hostile payloads (03 §6.5)', () {
    const marker = '\x1e0123456789abcdef0123456789abcdef E 1';
    final long = 'x' * 65536;

    test('journal values arrive whole, as journalctl encoded them', () async {
      final messages = <Object?>[
        marker,
        'two\nlines\x00nul',
        '\x1b[31mred\x1b[0m \x9b',
        long,
        [0x66, 0xff, 0x00, 0x0a, 0x6f],
        null,
      ];
      final stdout = [
        for (final (i, m) in messages.indexed)
          '${jsonEncode({'__CURSOR': _cursor(i), 'MESSAGE': m})}\n',
      ].join();
      await read('a', _spec(_journal), stdout: stdout);
      expect(texts('a'), [
        marker,
        'two\nlines\x00nul',
        '\x1b[31mred\x1b[0m \x9b',
        long,
        'f�\x00\no',
        '<null>',
      ]);
    });

    test('a deeply nested journal value still ends the read', () async {
      final deep = '${'{"a":' * 20000}1${'}' * 20000}';
      final stdout = '{"__CURSOR":"${_cursor(1)}","MESSAGE":$deep}\n';
      expect(await read('a', _spec(_journal), stdout: stdout), _oldest);
      expect(texts('a'), ['<null>']);
    });

    test('dmesg records arrive whole, a malformed one skipped', () async {
      const brackets = r'} ] { [ " \ },{';
      await fallBack(
        'k',
        stdout:
            '{"dmesg": [${jsonEncode({'msg': marker})}, {"msg": 7}, '
            '${jsonEncode({'msg': brackets})}, '
            '${jsonEncode({'msg': 'nul\x00 $long'})}]}',
      );
      expect(texts('k'), ['nul\x00 $long', brackets, marker]);
    });

    test('file lines arrive as bytes decoded leniently', () async {
      (await open('f', _spec(const FileLogSource('/var/log/app.log'))))
        ..emit([0x61, 0x00, 0xff, 0x62, 0x0a])
        ..emitText('$marker\n\x1b[2Kcleared\n$long\n')
        ..end();
      await ended('f');
      expect(texts('f'), [long, '\x1b[2Kcleared', marker, 'a\x00�b']);
    });
  });
}
