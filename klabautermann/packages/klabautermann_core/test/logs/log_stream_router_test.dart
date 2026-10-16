// LogStreamRouter over scripted links (03 §5.2, §7.6, §10.1): when each
// window runs, what it waits for, and that every stream ends once.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/log_service.dart';
import 'package:klabautermann_core/src/logs/log_stream_router.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteExit, SshLink, quoteShellWord;
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

  void start() {
    router = LogStreamRouter(
      linkFor: (serverId) => links[serverId],
      emit: events.add,
      openService: (link, emit) => LogService(
        link: link,
        quote: quoteShellWord,
        emit: emit,
        startTimer: clock.startTimer,
      ),
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
  }) => router.open(
    OpenLogStream(
      streamId: id,
      spec: LogStreamSpec(
        serverId: serverId,
        source: const JournalLogSource(),
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

  group('opens', () {
    test('a reused id, a follow, a server outside the fleet and a server '
        'at its cap are rejected without a state', () {
      links['srv-1'] = null;
      expect(open('a'), isNull);
      router.closeStream('a');
      expect(open('a'), contains('used before'));
      expect(open('f', follow: true), contains('not implemented'));
      expect(open('f'), contains('used before'));
      expect(open('x', serverId: 'gone'), contains('no fleet server'));

      for (var i = 0; i < kLogStreamsPerServerMax; i++) {
        expect(open('w$i'), isNull);
      }
      expect(open('over'), contains('holds'));
      expect(open('other', serverId: 'srv-2'), isNull);

      expect(statuses('a'), [_forLink, _closed]);
      for (final id in ['f', 'x', 'over']) {
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
}
