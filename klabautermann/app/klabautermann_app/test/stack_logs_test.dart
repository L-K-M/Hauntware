// CTX-04: a stack's logs, every container's follow merged by time, each
// line led by its container's name, with a chip per container.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_streams.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/ui/docker/stack_logs.dart';
import 'package:klabautermann_app/ui/logs/log_text.dart' show logRowText;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';

final _web = StackLogContainer(id: 'web1', name: 'web-1');
final _db = StackLogContainer(id: 'db1', name: 'db-1');

DateTime _at(int second) => DateTime.utc(2026, 10, 26, 12, 0, second);

void main() {
  late FakeEngineClient engine;
  late LogStreams streams;

  setUp(() {
    engine = FakeEngineClient();
    streams = LogStreams(engine);
  });

  tearDown(() => engine.close());

  String streamOf(String id) =>
      containerLogOpens(engine.sent, id).last.streamId;

  Future<void> batch(String id, List<ContainerRecord> records) async {
    engine.emit(containerLogBatch(streamOf(id), records));
    await pumpEventQueue();
  }

  List<String> texts(StackLogsController logs) => [
    for (var i = 0; i < logs.logs.length; i++)
      if (logs.logs[i] case final LogLine line) logRowText(line),
  ];

  test('follows each container, the first $kStackLogsMax, and merges '
      'their lines by time with the name in front', () async {
    final logs = StackLogsController(
      streams: streams,
      serverId: _serverId,
      containers: [
        _web,
        _db,
        for (var i = 0; i < kStackLogsMax; i++)
          StackLogContainer(id: 'x$i', name: 'x-$i'),
      ],
    )..setVisible(true);
    addTearDown(logs.dispose);
    expect(logs.containers, hasLength(kStackLogsMax));
    expect(logs.omitted, 2);
    final opens = engine.sentOfType<OpenLogStream>().cast<OpenLogStream>();
    expect(opens, hasLength(kStackLogsMax));
    expect(opens.every((open) => open.spec.follow), isTrue);
    expect(opens.first.spec.window, kStackLogsWindow);

    await batch('web1', [
      containerLine('GET /', at: _at(1)),
      containerLine('GET /health', at: _at(3)),
    ]);
    expect(texts(logs), ['web-1 GET /', 'web-1 GET /health']);

    // An older line rebuilds the view in time order.
    await batch('db1', [containerLine('ready', at: _at(2))]);
    expect(texts(logs), ['web-1 GET /', 'db-1 ready', 'web-1 GET /health']);

    // A newer one goes at the end.
    await batch('db1', [containerLine('checkpoint', at: _at(4))]);
    expect(texts(logs).last, 'db-1 checkpoint');
    expect(
      (logs.logs[0] as LogLine).text,
      startsWith('\x1b[38;5;'),
      reason: 'the name carries its container colour',
    );
  });

  test(
    'a hidden container keeps being read and shows again in place',
    () async {
      final logs = StackLogsController(
        streams: streams,
        serverId: _serverId,
        containers: [_web, _db],
      )..setVisible(true);
      addTearDown(logs.dispose);
      await batch('web1', [containerLine('a', at: _at(1))]);
      await batch('db1', [containerLine('b', at: _at(2))]);

      logs.toggle('db1');
      expect(logs.hidden, {'db1'});
      expect(texts(logs), ['web-1 a']);
      await batch('db1', [containerLine('c', at: _at(3))]);
      expect(texts(logs), ['web-1 a']);

      logs.toggle('db1');
      expect(texts(logs), ['web-1 a', 'db-1 b', 'db-1 c']);
    },
  );

  test(
    'each stream says how it stands, and hiding the page closes them',
    () async {
      final logs = StackLogsController(
        streams: streams,
        serverId: _serverId,
        containers: [_web, _db],
      )..setVisible(true);
      addTearDown(logs.dispose);
      expect(logs.stateOf('web1'), StackLogState.opening);

      engine.emit(LogStreamState(streamOf('web1'), const LogStreamRunning()));
      engine.emit(
        LogStreamState(
          streamOf('db1'),
          const LogStreamEnded(LogStreamEndReason.missing),
        ),
      );
      await pumpEventQueue();
      expect(logs.stateOf('web1'), StackLogState.running);
      expect(logs.stateOf('db1'), StackLogState.ended);

      // The ended one needs no close.
      logs.setVisible(false);
      expect(
        [
          for (final close in engine.sentOfType<CloseStream>())
            (close as CloseStream).streamId,
        ],
        [streamOf('web1')],
      );
    },
  );

  testWidgets('the page shows a chip per container that hides its lines', (
    tester,
  ) async {
    final monitoring = MonitoringController(engine);
    addTearDown(monitoring.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StackLogsPage(
          monitoring: monitoring,
          serverId: _serverId,
          project: 'web',
          containers: [_web, _db],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('web logs'), findsOne);
    expect(containerLogOpens(engine.sent, 'web1'), hasLength(1));

    engine.emit(
      LogStreamState(
        containerLogOpens(engine.sent, 'db1').last.streamId,
        const LogStreamEnded(LogStreamEndReason.missing),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('db-1: stopped reading'), findsOne);

    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    final chip = tester.widget<FilterChip>(
      find.ancestor(of: find.text('web-1'), matching: find.byType(FilterChip)),
    );
    expect(chip.selected, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(
      engine.sentOfType<CloseStream>(),
      hasLength(1),
      reason: 'leaving the page closes the follow still open',
    );
  });
}
