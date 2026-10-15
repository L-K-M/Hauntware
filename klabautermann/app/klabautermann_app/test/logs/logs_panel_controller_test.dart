import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_streams.dart';
import 'package:klabautermann_app/ui/logs/log_query.dart';
import 'package:klabautermann_app/ui/logs/logs_panel_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../support/fake_engine.dart';

JournalRecord _journal(int n) => JournalRecord(
  cursor: 's=$n',
  fields: {'MESSAGE': 'entry $n', '__CURSOR': 's=$n'},
);

void main() {
  late FakeEngineClient engine;
  late LogStreams streams;
  late LogsPanelController panel;

  setUp(() {
    engine = FakeEngineClient();
    streams = LogStreams(engine);
    panel = LogsPanelController(
      streams: streams,
      serverId: 'srv-1',
      now: () => DateTime.utc(2026, 10, 15, 12),
    );
  });

  tearDown(() async {
    panel.dispose();
    streams.dispose();
    await engine.close();
  });

  List<OpenLogStream> opens() =>
      engine.sentOfType<OpenLogStream>().cast<OpenLogStream>();

  String lastId() => opens().last.streamId;

  List<String> lines() => [
    for (var i = 0; i < panel.logs.length; i++)
      switch (panel.logs[i]) {
        LogLine(:final text) => text,
        LogDroppedLines(:final count) => 'dropped $count',
      },
  ];

  Future<void> emit(EngineEvent event) async {
    engine.emit(event);
    await pumpEventQueue();
  }

  test(
    'follows only while visible and resumes after the newest record',
    () async {
      expect(opens(), isEmpty);

      panel.setVisible(true);
      expect(panel.opening, isTrue);
      final follow = opens().single.spec;
      expect(follow.follow, isTrue);
      expect(follow.window, kLogsPanelWindow);
      expect(follow.afterCursor, isNull);

      await emit(LogStreamState(lastId(), const LogStreamRunning()));
      await emit(
        LogBatch(
          streamId: lastId(),
          records: [_journal(1), _journal(2)],
          dropped: 3,
        ),
      );
      expect(lines(), ['dropped 3', 'entry 1', 'entry 2']);

      panel.setVisible(false);
      expect(
        (engine.sent.last as CloseStream).streamId,
        opens().single.streamId,
      );

      panel.setVisible(true);
      expect(opens().last.spec.afterCursor, 's=2');
      expect(lines(), hasLength(3), reason: 'a resume keeps what it holds');
    },
  );

  test(
    'a window shows its records oldest first once it ends, and stays',
    () async {
      panel
        ..setVisible(true)
        ..setLive(false);
      expect(lines(), isEmpty);
      // The follow showed nothing to keep, so a window is read.
      expect(opens(), hasLength(2));
      expect(opens().last.spec.follow, isFalse);

      panel.apply(const LogQuery(unit: 'nginx.service'));
      final window = opens().last.spec;
      expect(window.follow, isFalse);
      expect((window.source as JournalLogSource).unit, 'nginx.service');

      await emit(
        LogBatch(streamId: lastId(), records: [_journal(9), _journal(8)]),
      );
      await emit(LogBatch(streamId: lastId(), records: [_journal(7)]));
      expect(lines(), isEmpty, reason: 'shown once the window ends');
      await emit(
        LogStreamState(
          lastId(),
          const LogStreamEnded(LogStreamEndReason.windowFilled),
        ),
      );
      expect(lines(), ['entry 7', 'entry 8', 'entry 9']);

      final sent = opens().length;
      panel
        ..setVisible(false)
        ..setVisible(true);
      expect(opens(), hasLength(sent), reason: 'a full window is kept');

      panel.setLive(true);
      expect(opens().last.spec.afterCursor, 's=9');
    },
  );

  test('an empty window keeps its end through a hide and a show', () async {
    panel
      ..setVisible(true)
      ..setLive(false);
    const end = LogStreamEnded(LogStreamEndReason.oldestReached);
    await emit(LogStreamState(lastId(), end));
    expect(panel.status, end);

    final sent = opens().length;
    panel
      ..setVisible(false)
      ..setVisible(true);
    expect(opens(), hasLength(sent), reason: 'an ended window is kept');
    expect(panel.status, end, reason: 'the empty view says why');
  });

  test('Live off after a refusal reads a window, which may answer', () async {
    panel.setVisible(true);
    await emit(const RequestRejected('OpenLogStream', 'not implemented yet'));

    panel.setLive(false);
    expect(opens(), hasLength(2));
    expect(opens().last.spec.follow, isFalse);
    await emit(const RequestRejected('OpenLogStream', 'not implemented yet'));
    expect(panel.rejected, isTrue);
  });

  test(
    'a rejection stays until retried; a file without a valid path waits',
    () async {
      panel.setVisible(true);
      await emit(const RequestRejected('OpenLogStream', 'not implemented yet'));
      expect(panel.rejected, isTrue);
      expect(panel.opening, isFalse);

      panel.retry();
      expect(panel.rejected, isFalse);
      expect(opens(), hasLength(2));

      panel.apply(
        const LogQuery(source: LogSourceKind.file).withPath('var/log'),
      );
      expect(opens(), hasLength(2));
      expect(engine.sentOfType<CloseStream>(), hasLength(1));

      panel.apply(panel.query.withPath('/var/log/syslog'));
      final tail = opens().last.spec;
      expect((tail.source as FileLogSource).path, '/var/log/syslog');
      await emit(
        LogBatch(streamId: lastId(), records: const [FileRecord('one')]),
      );
      expect(lines(), ['one']);

      // No cursor: a file's follow starts over.
      panel
        ..setVisible(false)
        ..setVisible(true);
      expect(opens().last.spec.afterCursor, isNull);
      expect(lines(), isEmpty);
    },
  );
}
