import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_reads.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

LogStreamSpec _window(String unit) => LogStreamSpec(
  serverId: 'srv-1',
  source: JournalLogSource(unit: unit),
  window: 50,
  follow: false,
);

const _rejected = RequestRejected('OpenLogStream', 'not implemented yet');

/// The app's side of bounded log reads (03 §10.1, SVC-04): what it sends,
/// which read each answer belongs to, and what a closed read still owes.
/// The Services panel's tests drive them through the monitoring
/// controller.
void main() {
  late List<EngineRequest> sent;
  late LogReads reads;

  setUp(() {
    sent = [];
    reads = LogReads(sent.add);
  });

  String idOf(int open) =>
      sent.whereType<OpenLogStream>().toList()[open].streamId;
  List<String> closed() => [
    for (final close in sent.whereType<CloseStream>()) close.streamId,
  ];

  test('collects batches and states until the read ends', () {
    final spec = _window('nginx.service');
    final read = reads.open(spec);
    reads.open(spec);
    expect(sent.whereType<OpenLogStream>().first.spec, same(spec));
    expect(idOf(0), isNot(idOf(1)));
    var notified = 0;
    read.addListener(() => notified++);

    const end = LogStreamEnded(LogStreamEndReason.oldestReached);
    reads
      ..accept(LogStreamState(idOf(0), const LogStreamRunning()))
      ..accept(
        LogBatch(
          streamId: idOf(0),
          records: const [
            JournalRecord(message: 'b'),
            JournalRecord(message: 'a'),
          ],
          dropped: 2,
        ),
      )
      ..accept(LogStreamState(idOf(0), end))
      // Nothing more counts once it ended.
      ..accept(LogBatch(streamId: idOf(0), records: const [JournalRecord()]));

    expect(notified, 3);
    expect((read.ended, read.dropped, read.records.length), (true, 2, 2));
    expect((read.state as LogReadReported).status, end);
    read.close();
    expect(closed(), isEmpty);
  });

  test('gives a rejection to the oldest open without an answer', () {
    final first = reads.open(_window('a.service'));
    final second = reads.open(_window('b.service'));
    final third = reads.open(_window('c.service'));
    reads
      ..accept(
        LogStreamState(
          idOf(0),
          const LogStreamWaiting(LogStreamWaitReason.link),
        ),
      )
      ..accept(const RequestRejected('Connect', 'not implemented yet'));
    expect(second.state, isA<LogReadRequested>());

    reads.accept(_rejected);
    expect(first.state, isA<LogReadReported>());
    expect(second.state, isA<LogReadRefused>());
    expect(second.ended, isTrue);
    expect(third.state, isA<LogReadRequested>());

    reads.accept(_rejected);
    expect(third.state, isA<LogReadRefused>());
    // No open is left to take one more.
    reads.accept(_rejected);
  });

  test('stops a running read once closed, and only once', () {
    final read = reads.open(_window('nginx.service'));
    reads.accept(LogStreamState(idOf(0), const LogStreamRunning()));

    read
      ..close()
      ..close();

    expect(closed(), [idOf(0)]);
    // The engine's last word for it reaches nothing.
    reads.accept(
      LogStreamState(idOf(0), const LogStreamEnded(LogStreamEndReason.closed)),
    );
  });

  test('keeps a closed open in line until the engine answers it', () {
    final first = reads.open(_window('a.service'));
    final second = reads.open(_window('b.service'));

    first.close();
    reads.accept(_rejected);
    expect(second.state, isA<LogReadRequested>());

    reads.accept(_rejected);
    expect(second.state, isA<LogReadRefused>());
  });
}
