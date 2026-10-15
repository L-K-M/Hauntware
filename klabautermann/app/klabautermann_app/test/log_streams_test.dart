import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_streams.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

final class _Recorder implements LogStreamListener {
  final events = <Object>[];

  @override
  void onLogBatch(LogBatch batch) => events.add(batch.records.length);

  @override
  void onLogStatus(LogStreamStatus status) => events.add(status);

  @override
  void onLogRejected() => events.add('rejected');
}

final _spec = LogStreamSpec(
  serverId: 'srv-1',
  source: const JournalLogSource(),
  window: 10,
  follow: true,
);

const _rejected = RequestRejected('OpenLogStream', 'not implemented yet');

void main() {
  late FakeEngineClient engine;
  late LogStreams streams;

  setUp(() {
    engine = FakeEngineClient();
    streams = LogStreams(engine);
  });

  tearDown(() async {
    streams.dispose();
    await engine.close();
  });

  String idOf(int open) =>
      (engine.sentOfType<OpenLogStream>()[open] as OpenLogStream).streamId;

  test('opens under ids never reused and routes events by id', () async {
    final first = _Recorder();
    final second = _Recorder();
    final ended = streams.open(_spec, first);
    streams.open(_spec, second).close();
    streams.open(_spec, _Recorder());

    final ids = [for (var i = 0; i < 3; i++) idOf(i)];
    expect(ids.toSet(), hasLength(3));
    expect(engine.sentOfType<CloseStream>().single, isA<CloseStream>());

    engine
      ..emit(LogBatch(streamId: ids[0], records: const [JournalRecord()]))
      ..emit(LogStreamState(ids[0], const LogStreamRunning()))
      // A closed stream's late batch reaches nobody.
      ..emit(LogBatch(streamId: ids[1], records: const [JournalRecord()]))
      ..emit(
        LogStreamState(ids[0], const LogStreamEnded(LogStreamEndReason.failed)),
      )
      ..emit(LogStreamState(ids[0], const LogStreamRunning()));
    await pumpEventQueue();

    expect(first.events, [
      1,
      const LogStreamRunning(),
      const LogStreamEnded(LogStreamEndReason.failed),
    ]);
    expect(second.events, isEmpty);
    // An ended stream is not open, so closing it sends nothing.
    ended.close();
    expect(engine.sentOfType<CloseStream>(), hasLength(1));
  });

  test('a rejection answers the oldest open without an answer', () async {
    final first = _Recorder();
    final second = _Recorder();
    final third = _Recorder();
    streams.open(_spec, first).close();
    streams.open(_spec, second);
    streams.open(_spec, third);

    // The first, though closed, still takes its own rejection.
    engine
      ..emit(_rejected)
      ..emit(LogStreamState(idOf(2), const LogStreamRunning()))
      ..emit(_rejected)
      ..emit(const RequestRejected('Connect', 'not yet'));
    await pumpEventQueue();

    expect(first.events, isEmpty);
    // Answered in order, the second was accepted before the third's
    // answer, so the later rejection is nobody's.
    expect(second.events, isEmpty);
    expect(third.events, [const LogStreamRunning()]);
  });

  test('an engine that stops refuses the streams still open', () async {
    final running = _Recorder();
    final waiting = _Recorder();
    final closed = _Recorder();
    streams.open(_spec, running);
    engine.emit(LogStreamState(idOf(0), const LogStreamRunning()));
    await pumpEventQueue();
    streams.open(_spec, waiting);
    streams.open(_spec, closed).close();

    await engine.close();
    await pumpEventQueue();
    expect(running.events, [const LogStreamRunning(), 'rejected']);
    expect(waiting.events, ['rejected']);
    expect(closed.events, isEmpty);
  });

  test('a stopped engine refuses opens after they return', () async {
    await engine.close();
    final recorder = _Recorder();
    streams.open(_spec, recorder);

    expect(recorder.events, isEmpty);
    await pumpEventQueue();
    expect(recorder.events, ['rejected']);
  });

  test('tells from the probe whether only own journal entries show', () async {
    HostProfile profile(List<String> groups) => HostProfile.fromJson({
      'uid': 1000,
      'groups': groups,
      'tools': {'journalctl': '/usr/bin/journalctl'},
      'areaStatuses': {'identity': 'ok'},
    });
    final limited = streams.journalLimitedFor('srv-1');
    expect(limited.value, isNull);

    engine.emit(HostProfileChanged('srv-1', profile(['users'])));
    await pumpEventQueue();
    expect(limited.value, isTrue);

    engine.emit(HostProfileChanged('srv-1', profile(['adm'])));
    await pumpEventQueue();
    expect(limited.value, isFalse);
    expect(streams.journalLimitedFor('srv-2').value, isNull);
  });
}
