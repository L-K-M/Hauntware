import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_reads.dart';
import 'package:klabautermann_app/controllers/log_streams.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

LogStreamSpec _window(String unit) => LogStreamSpec(
  serverId: 'srv-1',
  source: JournalLogSource(unit: unit),
  window: 50,
  follow: false,
);

const _rejected = RequestRejected('OpenLogStream', 'not implemented yet');

/// The app's side of bounded log reads (03 §10.1, SVC-04): what it sends,
/// which read each answer belongs to, and what a closed read still owes.
/// They share [LogStreams] with the Logs panel, which the monitoring
/// controller's tests interleave them with; the Services panel's tests
/// drive them through that controller.
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

  LogRead open(LogStreamSpec spec) => LogRead(streams, spec);
  String idOf(int open) =>
      (engine.sentOfType<OpenLogStream>()[open] as OpenLogStream).streamId;
  List<String> closed() => [
    for (final close in engine.sentOfType<CloseStream>())
      (close as CloseStream).streamId,
  ];

  /// Delivers [events] to the reads, in order.
  Future<void> accept(List<EngineEvent> events) async {
    events.forEach(engine.emit);
    await pumpEventQueue();
  }

  test('collects batches and states until the read ends', () async {
    final spec = _window('nginx.service');
    final read = open(spec);
    open(spec);
    expect(
      (engine.sentOfType<OpenLogStream>().first as OpenLogStream).spec,
      same(spec),
    );
    expect(idOf(0), isNot(idOf(1)));
    var notified = 0;
    read.addListener(() => notified++);

    const end = LogStreamEnded(LogStreamEndReason.oldestReached);
    await accept([
      LogStreamState(idOf(0), const LogStreamRunning()),
      LogBatch(
        streamId: idOf(0),
        records: const [
          JournalRecord(message: 'b'),
          JournalRecord(message: 'a'),
        ],
        dropped: 2,
      ),
      LogStreamState(idOf(0), end),
      // Nothing more counts once it ended.
      LogBatch(streamId: idOf(0), records: const [JournalRecord()]),
    ]);

    expect(notified, 3);
    expect((read.ended, read.dropped, read.records.length), (true, 2, 2));
    expect((read.state as LogReadReported).status, end);
    read.close();
    expect(closed(), isEmpty);
  });

  test('gives a rejection to the oldest open without an answer', () async {
    final first = open(_window('a.service'));
    final second = open(_window('b.service'));
    final third = open(_window('c.service'));
    await accept([
      LogStreamState(idOf(0), const LogStreamWaiting(LogStreamWaitReason.link)),
      const RequestRejected('Connect', 'not implemented yet'),
    ]);
    expect(second.state, isA<LogReadRequested>());

    await accept([_rejected]);
    expect(first.state, isA<LogReadReported>());
    expect(
      second.state,
      isA<LogReadRefused>().having(
        (state) => state.rejection,
        'rejection',
        LogRejection.refused,
      ),
    );
    expect(second.ended, isTrue);
    expect(third.state, isA<LogReadRequested>());

    await accept([_rejected]);
    expect(third.state, isA<LogReadRefused>());
    // No open is left to take one more.
    await accept([_rejected]);
  });

  test('stops a running read once closed, and only once', () async {
    final read = open(_window('nginx.service'));
    await accept([LogStreamState(idOf(0), const LogStreamRunning())]);

    read
      ..close()
      ..close();

    expect(closed(), [idOf(0)]);
    // The engine's last word for it reaches nothing.
    await accept([
      LogStreamState(idOf(0), const LogStreamEnded(LogStreamEndReason.closed)),
    ]);
  });

  test('keeps a closed open in line until the engine answers it', () async {
    final first = open(_window('a.service'));
    final second = open(_window('b.service'));

    first.close();
    await accept([_rejected]);
    expect(second.state, isA<LogReadRequested>());

    await accept([_rejected]);
    expect(second.state, isA<LogReadRefused>());
  });

  test('refuses a read still open when the engine stops', () async {
    final running = open(_window('a.service'));
    await accept([LogStreamState(idOf(0), const LogStreamRunning())]);
    final requested = open(_window('b.service'));
    final ended = open(_window('c.service'));
    await accept([
      LogStreamState(
        idOf(2),
        const LogStreamEnded(LogStreamEndReason.windowFilled),
      ),
    ]);

    await engine.close();
    await pumpEventQueue();
    final stopped = isA<LogReadRefused>().having(
      (state) => state.rejection,
      'rejection',
      LogRejection.engineStopped,
    );
    expect(running.state, stopped);
    expect(requested.state, stopped);
    expect(ended.state, isA<LogReadReported>());
  });
}
