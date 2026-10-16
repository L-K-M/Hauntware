// LogStreamRouter over scripted links (03 §5.2, §7.6, §10.1): when each
// window runs, what it waits for, and that every stream ends once.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/log_service.dart';
import 'package:klabautermann_core/src/logs/log_stream_router.dart';
import 'package:seance_core/seance_core.dart'
    show
        RemoteExit,
        SshLink,
        SshLinkClosed,
        SshLinkClosedReason,
        SshLinkSeen,
        quoteShellWord;
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/scripted_link.dart';

const _running = LogStreamRunning();
const _failed = LogStreamEnded(LogStreamEndReason.failed);
const _closed = LogStreamEnded(LogStreamEndReason.closed);
const _oldest = LogStreamEnded(LogStreamEndReason.oldestReached);
const _forLink = LogStreamWaiting(LogStreamWaitReason.link);
const _forChannel = LogStreamWaiting(LogStreamWaitReason.channel);
const _forForeground = LogStreamWaiting(LogStreamWaitReason.background);

/// [count] journal entries as `journalctl -o json -r` prints them.
String _entries(int count) => [
  for (var n = count; n >= 1; n--)
    '${jsonEncode({'__CURSOR': 'c$n', 'MESSAGE': 'entry $n'})}\n',
].join();

/// Journal entries [from] to [to] as `journalctl -f -o json` prints them.
String _follow(int from, int to) => [
  for (var n = from; n <= to; n++)
    '${jsonEncode({'__CURSOR': 's=$n', 'MESSAGE': 'entry $n'})}\n',
].join();

Future<void> _until(bool Function() condition) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late ScriptedLink link;
  late Map<String, SshLink?> links;
  late List<EngineEvent> events;
  late FakeClock clock;
  late LogStreamRouter router;
  late List<LogService> services;

  void start() {
    services = [];
    router = LogStreamRouter(
      linkFor: (serverId) => links[serverId],
      emit: events.add,
      openService: (link, emit) {
        final service = LogService(
          link: link,
          quote: quoteShellWord,
          emit: emit,
          startTimer: clock.startTimer,
        );
        services.add(service);
        return service;
      },
      startTimer: clock.startTimer,
      elapsed: () => clock.elapsed,
    )..retain({'srv-1', 'srv-2'});
    addTearDown(router.close);
  }

  setUp(() {
    link = ScriptedLink();
    links = {'srv-1': link, 'srv-2': ScriptedLink()};
    events = [];
    clock = FakeClock();
    start();
  });

  String? open(
    String id, {
    String serverId = 'srv-1',
    int window = 10,
    bool follow = false,
    LogSource source = const JournalLogSource(),
  }) => router.open(
    OpenLogStream(
      streamId: id,
      spec: LogStreamSpec(
        serverId: serverId,
        source: source,
        window: window,
        follow: follow,
      ),
    ),
  );

  List<LogStreamStatus> statuses(String id) => [
    for (final e in events)
      if (e case LogStreamState(:final streamId, :final status))
        if (streamId == id) status,
  ];

  int ends(String id) => statuses(id).whereType<LogStreamEnded>().length;

  /// Whether [service] is closed: a closed one refuses every open, and an
  /// open one ends this refused spec at once without running anything.
  bool closed(LogService service) {
    try {
      service.open(
        'probe',
        LogStreamSpec(
          serverId: 'srv-1',
          source: const JournalLogSource(),
          window: 0,
          follow: false,
        ),
      );
      return false;
    } on StateError {
      return true;
    }
  }

  /// Ends [link]'s [index]th process with [count] entries.
  Future<void> play(ScriptedLink link, int index, [int count = 2]) async {
    (await link.process(index))
      ..emitText(_entries(count))
      ..end();
  }

  test('a window on a ready link runs at once and ends once', () async {
    expect(open('a'), isNull);
    expect(statuses('a'), [_running]);

    await play(link, 0);
    await _until(() => ends('a') == 1);
    expect(statuses('a'), [_running, _oldest]);
    expect(events.whereType<LogBatch>().single.records, hasLength(2));
  });

  test('without a link a window waits for one, then runs on it', () async {
    links['srv-1'] = null;
    expect(open('a'), isNull);
    router.update('srv-1');
    expect(statuses('a'), [_forLink]);
    expect(link.commands, isEmpty);

    links['srv-1'] = link;
    router.update('srv-1');
    expect(statuses('a'), [_forLink, _running]);
    expect(link.commands, hasLength(1));
  });

  group('channel shares (03 §5.2)', () {
    test('two windows run at once a server; the third waits for a '
        'channel and takes the first slot that frees', () async {
      for (final id in ['a', 'b', 'c']) {
        open(id);
      }
      open('d', serverId: 'srv-2');
      expect(statuses('b'), [_running]);
      expect(statuses('c'), [_forChannel]);
      expect(statuses('d'), [_running], reason: 'its own server');
      expect(link.commands, hasLength(2));

      await play(link, 0);
      await _until(() => statuses('c').length == 2);
      expect(statuses('c'), [_forChannel, _running]);
      expect(link.commands, hasLength(3));
    });

    test('a learned session limit below 4 holds back no window, a short '
        'action', () {
      link.seen = const SshLinkSeen(learnedSessionLimit: 2);
      open('a');
      open('b');
      expect(statuses('a'), [_running]);
      expect(statuses('b'), [_running]);
    });

    test('a deadline frees its slot, as every end does', () async {
      for (final id in ['a', 'b', 'c']) {
        open(id);
      }
      await link.process(1);

      await clock.elapse(kLogReadDeadline);
      expect(statuses('a'), [_running, _failed]);
      expect(statuses('b'), [_running, _failed]);
      expect(statuses('c'), [_forChannel, _running]);
    });
  });

  group('CloseStream', () {
    test('ends a waiting window as closed without running it, and a '
        'running one with its process', () async {
      for (final id in ['a', 'b', 'c']) {
        open(id);
      }
      router.closeStream('c');
      router.closeStream('c');
      expect(statuses('c'), [_forChannel, _closed]);

      router.closeStream('a');
      router.closeStream('a');
      expect(statuses('a'), [_running, _closed]);
      final first = await link.process(0);
      await _until(() => first.closeCalls == 1);

      // a's slot is free.
      open('d');
      expect(statuses('d'), [_running]);
      expect(link.commands, hasLength(3));
    });
  });

  group('link changes', () {
    test('a lost link ends running windows as failed, once; waiting ones '
        'wait for the next link and run on it', () async {
      for (final id in ['a', 'b', 'c']) {
        open(id);
      }
      final processes = [await link.process(0), await link.process(1)];

      links['srv-1'] = null;
      router.update('srv-1');
      expect(statuses('a'), [_running, _failed]);
      expect(statuses('b'), [_running, _failed]);
      expect(statuses('c'), [_forChannel, _forLink]);
      // The lost link ends the processes too, which sends nothing more.
      for (final p in processes) {
        p.end(const RemoteExit());
      }
      await pumpEventQueue();
      expect([ends('a'), ends('b')], [1, 1]);
      expect(processes.map((p) => p.closeCalls), [1, 1]);

      final next = ScriptedLink();
      links['srv-1'] = next;
      router.update('srv-1');
      expect(statuses('c'), [_forChannel, _forLink, _running]);
      expect(next.commands, hasLength(1));
    });

    test('a replaced link ends what ran on the old one and runs the '
        'waiting windows on the new one', () async {
      for (final id in ['a', 'b', 'c']) {
        open(id);
      }
      final next = ScriptedLink();
      links['srv-1'] = next;
      router.update('srv-1');
      expect(statuses('a'), [_running, _failed]);
      expect(statuses('c'), [_forChannel, _running]);
      expect(next.commands, hasLength(1));
    });
  });

  test('the background pauses every window, closing running processes, '
      'and the foreground starts them over', () async {
    for (final id in ['a', 'b', 'c']) {
      open(id);
    }
    final first = await link.process(0);

    router.activity = AppActivity.background;
    expect(statuses('a'), [_running, _forForeground]);
    expect(statuses('b'), [_running, _forForeground]);
    expect(statuses('c'), [_forChannel, _forForeground]);
    open('d');
    expect(statuses('d'), [_forForeground]);
    await _until(() => first.closeCalls == 1);
    expect(link.commands, hasLength(2));

    router.activity = AppActivity.foreground;
    expect(statuses('a'), [_running, _forForeground, _running]);
    expect(statuses('b').last, _running);
    expect(statuses('c').last, _forChannel);
    expect(statuses('d'), [_forForeground, _forChannel]);
    expect(link.commands, hasLength(4));

    await play(link, 2);
    await _until(() => ends('a') == 1);
    expect(statuses('a').last, _oldest);
    expect(statuses('c').last, _running);
  });

  test('a window opened in the background says so again when a later '
      'background pauses it', () {
    router.activity = AppActivity.background;
    open('a');
    router.activity = AppActivity.foreground;
    router.activity = AppActivity.background;
    expect(statuses('a'), [_forForeground, _running, _forForeground]);
  });

  test('Disconnect, fleet removal and close end every window as failed, '
      'once', () async {
    final ways = <String, void Function()>{
      'disconnect': () => router.disconnect('srv-1'),
      'fleet removal': () => router.retain({'srv-2'}),
      'close': () => unawaited(router.close()),
    };
    for (final MapEntry(key: way, value: end) in ways.entries) {
      link = ScriptedLink();
      links['srv-1'] = link;
      events = [];
      start();
      for (final id in ['a', 'b', 'c']) {
        open(id);
      }
      final first = await link.process(0);

      end();
      // The app's CloseStream crossing the end changes nothing.
      router.closeStream('c');
      for (final id in ['a', 'b', 'c']) {
        expect(statuses(id).last, _failed, reason: '$way $id');
        expect(ends(id), 1, reason: '$way $id');
      }
      await _until(() => first.closeCalls == 1);
      first.end();
      await pumpEventQueue();
      expect(ends('a'), 1, reason: way);
    }
  });

  group('a server left without streams', () {
    test('closes its service once its last window ends', () async {
      open('a');
      await play(link, 0);
      await _until(() => ends('a') == 1);
      expect(closed(services.single), isTrue);

      open('b');
      expect(services, hasLength(2), reason: 'a new service');
    });

    test('closes its service once CloseStream ends its last stream while '
        'it waits', () {
      open('a');
      router.activity = AppActivity.background;
      router.closeStream('a');
      expect(closed(services.single), isTrue);

      open('b');
      router.activity = AppActivity.foreground;
      expect(statuses('b'), [_forForeground, _running]);
      expect(services, hasLength(2), reason: 'a new service');
    });
  });

  test('close completes once the processes have closed', () async {
    open('a');
    final first = await link.process(0);
    final hold = first.holdClose = Completer<void>();

    var done = false;
    unawaited(router.close().then((_) => done = true));
    await pumpEventQueue();
    expect(first.closeCalls, 1);
    expect(done, isFalse);

    hold.complete();
    await _until(() => done);
  });

  group('opens', () {
    test('a reused id, a server outside the fleet and a server at its cap '
        'are rejected without a state', () {
      links['srv-1'] = null;
      expect(open('a'), isNull);
      router.closeStream('a');
      expect(open('a'), contains('used before'));
      expect(open('a', follow: true), contains('used before'));
      expect(open('x', serverId: 'gone'), contains('no fleet server'));

      for (var i = 0; i < kLogStreamsPerServerMax; i++) {
        expect(open('w$i'), isNull);
      }
      expect(open('over'), contains('holds'));
      expect(open('other', serverId: 'srv-2'), isNull);

      expect(statuses('a'), [_forLink, _closed]);
      for (final id in ['x', 'over']) {
        expect(statuses(id), isEmpty, reason: id);
      }
    });

    test('a refused spec ends as invalid at once, link or none', () {
      links['srv-1'] = null;
      expect(open('a', window: 0), isNull);
      expect(open('b', window: kLogWindowMax + 1), isNull);
      expect(statuses('a'), [const LogStreamEnded(LogStreamEndReason.invalid)]);
      expect(statuses('b'), [const LogStreamEnded(LogStreamEndReason.invalid)]);
      expect(link.commands, isEmpty);
    });
  });

  group('follows (K26)', () {
    test('two follows run a server and a third waits for a channel; '
        'windows keep their own share, and a close frees a slot', () {
      for (final id in ['f1', 'f2', 'f3']) {
        open(id, follow: true);
      }
      open('w');
      expect(statuses('f2'), [_running]);
      expect(statuses('f3'), [_forChannel]);
      expect(statuses('w'), [_running]);
      expect(link.commands, hasLength(3));

      router
        ..closeStream('f3')
        ..closeStream('f1')
        ..closeStream('f1');
      expect(statuses('f3'), [_forChannel, _closed]);
      expect(statuses('f1'), [_running, _closed]);
      open('f4', follow: true);
      expect(statuses('f4'), [_running]);
    });

    test('under a learned session limit below 4 a follow waits for a '
        'channel; windows still run', () {
      link.seen = const SshLinkSeen(learnedSessionLimit: 3);
      open('f', follow: true);
      open('w');
      expect(statuses('f'), [_forChannel]);
      expect(statuses('w'), [_running]);
    });

    test('at a learned session limit of 4 one follow runs and the next '
        'waits for a channel', () {
      link.seen = const SshLinkSeen(learnedSessionLimit: 4);
      open('f1', follow: true);
      open('f2', follow: true);
      expect(statuses('f1'), [_running]);
      expect(statuses('f2'), [_forChannel]);
    });

    test('a lost link pauses a follow, which resumes after its newest '
        'cursor on the next link and never ends', () async {
      open('f', follow: true);
      final p = await link.process(0);
      p.emitText(_follow(1, 2));
      await clock.elapse(Duration.zero);

      // The process goes before the supervisor reports the closed link.
      link.state = const SshLinkClosed(SshLinkClosedReason.linkLost);
      p.end(const RemoteExit());
      await pumpEventQueue();
      expect(statuses('f'), [_running, _forLink]);
      links['srv-1'] = null;
      router.update('srv-1');

      final next = ScriptedLink();
      links['srv-1'] = next;
      router.update('srv-1');
      expect(statuses('f'), [_running, _forLink, _running]);
      expect(next.commands.single, contains("'--after-cursor=s=2'"));
      expect(link.commands, hasLength(1));
      expect(ends('f'), 0);
    });

    test('a replaced link moves a journal follow without a state, and a '
        'file once with a gap, while a window on the old link fails', () async {
      open('f', follow: true);
      open('w');
      open('t', follow: true, source: const FileLogSource('/var/log/app.log'));
      final p = await link.process(0);
      p.emitText(_follow(1, 1));
      (await link.process(2)).emitText('one\n');
      await clock.elapse(Duration.zero);

      final next = ScriptedLink();
      links['srv-1'] = next;
      router.update('srv-1');
      expect(statuses('f'), [_running]);
      expect(statuses('w'), [_running, _failed]);
      const gap = LogStreamRunning(continuity: LogContinuity.gap);
      expect(statuses('t'), [_running, gap]);
      // The failed window does not run again.
      expect(next.commands, hasLength(2));
      expect(next.commands.first, contains("'--after-cursor=s=1'"));
      await pumpEventQueue();
      expect(p.closeCalls, 1);

      links['srv-1'] = ScriptedLink();
      router.update('srv-1');
      expect(statuses('f'), [_running]);
      expect(statuses('t'), [_running, gap]);
    });

    test('a follow lost on a live link runs again there, in its own slot '
        'and ahead of a follow waiting for a channel', () async {
      for (final id in ['f1', 'f2', 'f3']) {
        open(id, follow: true);
      }
      (await link.process(0)).end(const RemoteExit());
      await pumpEventQueue();
      expect(link.commands, hasLength(3));
      expect(statuses('f1'), [_running]);
      expect(statuses('f3'), [_forChannel]);
    });

    test('a follow the host ended sends its last batch and ends through '
        'the background or a replaced link, and runs no more', () async {
      for (final way in ['background', 'replaced link']) {
        link = ScriptedLink();
        links['srv-1'] = link;
        events = [];
        start();
        open('f', follow: true);
        final p = await link.process(0);
        p.emitText(_follow(1, 1));
        await clock.elapse(Duration.zero);
        p
          ..emitText(_follow(2, 2))
          ..end(const RemoteExit(exitCode: 1));
        await pumpEventQueue();

        final next = ScriptedLink();
        if (way == 'background') {
          router.activity = AppActivity.background;
        } else {
          links['srv-1'] = next;
          router.update('srv-1');
        }
        await clock.elapse(const Duration(milliseconds: 50));
        expect(events.whereType<LogBatch>(), hasLength(2), reason: way);
        expect(statuses('f'), [_running, _failed], reason: way);
        expect(next.commands, isEmpty, reason: way);
      }
    });

    test('the background pauses a follow and the foreground resumes it; '
        'a file says lines may be missing', () async {
      open('f', follow: true);
      open('t', follow: true, source: const FileLogSource('/var/log/app.log'));
      final journal = await link.process(0);
      journal.emitText(_follow(1, 2));
      (await link.process(1)).emitText('one\n');
      await clock.elapse(Duration.zero);

      router.activity = AppActivity.background;
      expect(statuses('f'), [_running, _forForeground]);
      await pumpEventQueue();
      expect(journal.closeCalls, 1);
      await clock.elapse(const Duration(minutes: 1));

      router.activity = AppActivity.foreground;
      expect(statuses('f'), [_running, _forForeground, _running]);
      expect(statuses('t'), [
        _running,
        _forForeground,
        const LogStreamRunning(continuity: LogContinuity.gap),
      ]);
      expect(link.commands[2], contains("'--after-cursor=s=2'"));
      expect(link.commands[3], contains("'tail' '-n' '0' '-F'"));
    });

    test(
      'a follow the host ends frees its slot after its last batch',
      () async {
        for (final id in ['f1', 'f2', 'f3']) {
          open(id, follow: true);
        }
        (await link.process(0))
          ..emitText(_follow(1, 1))
          ..end(const RemoteExit(exitCode: 1));
        await pumpEventQueue();
        expect(statuses('f3'), [_forChannel]);

        await clock.elapse(Duration.zero);
        expect(events.whereType<LogBatch>().single.streamId, 'f1');
        expect(statuses('f1'), [_running, _failed]);
        expect(statuses('f3'), [_forChannel, _running]);

        router.closeStream('f1');
        expect(statuses('f1'), [_running, _failed]);
      },
    );

    test('Disconnect, fleet removal and close end every follow as failed, '
        'once, and stop its timer', () async {
      final ways = <String, void Function()>{
        'disconnect': () => router.disconnect('srv-1'),
        'fleet removal': () => router.retain({'srv-2'}),
        'close': () => unawaited(router.close()),
      };
      for (final MapEntry(key: way, value: end) in ways.entries) {
        link = ScriptedLink();
        links['srv-1'] = link;
        events = [];
        start();
        for (final id in ['f1', 'f2', 'f3']) {
          open(id, follow: true);
        }
        final first = await link.process(0);
        first.emitText(_follow(1, 1));
        await pumpEventQueue();

        end();
        router.closeStream('f3');
        for (final id in ['f1', 'f2', 'f3']) {
          expect(statuses(id).last, _failed, reason: '$way $id');
          expect(ends(id), 1, reason: '$way $id');
        }
        final count = events.length;
        await clock.elapse(const Duration(seconds: 1));
        expect(events, hasLength(count), reason: '$way: nothing after');
        expect(first.closeCalls, 1, reason: way);
      }
    });
  });
}
