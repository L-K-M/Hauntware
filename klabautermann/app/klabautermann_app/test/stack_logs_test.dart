// CTX-04: a stack's logs, every container's follow merged by time, each
// line led by its container's name, with a chip per container.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_streams.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/ui/docker/stack_logs.dart';
import 'package:klabautermann_app/ui/logs/log_text.dart' show logRowText;
import 'package:klabautermann_app/ui/logs/log_view.dart' show LogView;
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
      hold: Duration.zero,
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
        hold: Duration.zero,
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

  test('lines the engine dropped keep their marker through out-of-order '
      'batches, rebuilds and a hidden container', () async {
    final logs = StackLogsController(
      streams: streams,
      serverId: _serverId,
      containers: [_web, _db],
      hold: Duration.zero,
    )..setVisible(true);
    addTearDown(logs.dispose);

    /// The merged view as text, a gap as `dropped N`.
    List<String> view() => [
      for (var i = 0; i < logs.logs.length; i++)
        switch (logs.logs[i]) {
          final LogLine line => logRowText(line),
          LogDroppedLines(:final count) => 'dropped $count',
        },
    ];

    await batch('web1', [containerLine('a', at: _at(1))]);
    await batch('web1', [containerLine('d', at: _at(4))]);
    engine.emit(
      containerLogBatch(streamOf('db1'), [
        containerLine('b', at: _at(2)),
      ], dropped: 5),
    );
    await pumpEventQueue();
    expect(view(), ['web-1 a', 'dropped 5', 'db-1 b', 'web-1 d']);

    // A later out-of-order batch rebuilds the view and keeps the marker.
    await batch('web1', [containerLine('c', at: _at(3))]);
    expect(view(), ['web-1 a', 'dropped 5', 'db-1 b', 'web-1 c', 'web-1 d']);

    // A hidden container's marker goes with its lines and returns.
    logs.toggle('db1');
    expect(view(), ['web-1 a', 'web-1 c', 'web-1 d']);
    engine.emit(containerLogBatch(streamOf('db1'), const [], dropped: 2));
    await pumpEventQueue();
    expect(view(), ['web-1 a', 'web-1 c', 'web-1 d']);
    logs.toggle('db1');
    expect(view(), [
      'web-1 a',
      'dropped 5',
      'db-1 b',
      'web-1 c',
      'web-1 d',
      'dropped 2',
    ]);
  });

  test(
    'each stream says how it stands, and hiding the page closes them',
    () async {
      final logs = StackLogsController(
        streams: streams,
        serverId: _serverId,
        containers: [_web, _db],
        hold: Duration.zero,
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

  test('lines of two containers that arrive within the hold are shown in '
      'time order without a rebuild (UIB-3)', () async {
    final logs = StackLogsController(
      streams: streams,
      serverId: _serverId,
      containers: [_web, _db],
      hold: const Duration(milliseconds: 30),
    )..setVisible(true);
    addTearDown(logs.dispose);

    engine
      ..emit(
        containerLogBatch(streamOf('web1'), [
          containerLine('a', at: _at(1)),
          containerLine('c', at: _at(3)),
        ]),
      )
      ..emit(
        containerLogBatch(streamOf('db1'), [containerLine('b', at: _at(2))]),
      );
    await pumpEventQueue();
    expect(texts(logs), isEmpty, reason: 'held for the other containers');

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(texts(logs), ['web-1 a', 'db-1 b', 'web-1 c']);
    // A rebuild numbers its lines on from those it replaced.
    expect(logs.logs.firstSeq, 0);
  });

  test('a paused view keeps an older line back until it follows again '
      '(UIB-3)', () async {
    final logs = StackLogsController(
      streams: streams,
      serverId: _serverId,
      containers: [_web, _db],
      hold: Duration.zero,
    )..setVisible(true);
    addTearDown(logs.dispose);
    await batch('web1', [
      containerLine('a', at: _at(1)),
      containerLine('c', at: _at(3)),
    ]);
    logs.search
      ..setQuery('c')
      ..next();
    logs.logs.pause();

    engine.emit(
      containerLogBatch(streamOf('db1'), [
        containerLine('b', at: _at(2)),
        containerLine('d', at: _at(4)),
      ], dropped: 3),
    );
    await pumpEventQueue();
    // The newer line is appended; the older one and its marker wait.
    expect(texts(logs), ['web-1 a', 'web-1 c', 'db-1 d']);
    expect(logs.logs.firstSeq, 0, reason: 'no line was renumbered');
    expect(logs.search.current, (seq: 1, index: 0));

    await batch('web1', [containerLine('e', at: _at(5))]);
    expect(texts(logs), ['web-1 a', 'web-1 c', 'db-1 d', 'web-1 e']);
    expect(logs.logs.firstSeq, 0);

    logs.logs.follow();
    await pumpEventQueue();
    expect(
      [
        for (var i = 0; i < logs.logs.length; i++)
          switch (logs.logs[i]) {
            final LogLine line => logRowText(line),
            LogDroppedLines(:final count) => 'dropped $count',
          },
      ],
      ['web-1 a', 'dropped 3', 'db-1 b', 'web-1 c', 'db-1 d', 'web-1 e'],
    );
  });

  test('a hidden container\'s dropped lines mark nothing among the lines '
      'released with them', () async {
    final logs = StackLogsController(
      streams: streams,
      serverId: _serverId,
      containers: [_web, _db],
      hold: const Duration(milliseconds: 30),
    )..setVisible(true);
    addTearDown(logs.dispose);
    logs.toggle('db1');

    // One release: the hidden container's marker sorts first, and one
    // of its lines falls between the visible container's.
    engine
      ..emit(
        containerLogBatch(streamOf('db1'), [
          containerLine('b', at: _at(1)),
          containerLine('d', at: _at(3)),
        ], dropped: 7),
      )
      ..emit(
        containerLogBatch(streamOf('web1'), [
          containerLine('c', at: _at(2)),
          containerLine('e', at: _at(4)),
        ]),
      );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(logs.logs.length, 2);
    expect(texts(logs), ['web-1 c', 'web-1 e']);

    logs.toggle('db1');
    expect(logs.logs[0], isA<LogDroppedLines>());
    expect(texts(logs), ['db-1 b', 'web-1 c', 'db-1 d', 'web-1 e']);
  });

  test('a container that replaces one of the same name is read in its '
      'place; one that is gone keeps its lines (UIB-9)', () async {
    final logs = StackLogsController(
      streams: streams,
      serverId: _serverId,
      containers: [_web, _db],
      hold: Duration.zero,
    )..setVisible(true);
    addTearDown(logs.dispose);
    await batch('web1', [containerLine('old', at: _at(1))]);
    await batch('db1', [containerLine('ready', at: _at(2))]);
    logs.toggle('db1');

    // A redeploy: web-1 again under a new id, db-1 gone, a cache new.
    logs.setContainers([
      const StackLogContainer(id: 'web2', name: 'web-1'),
      const StackLogContainer(id: 'cache1', name: 'cache-1'),
    ]);
    expect(
      [for (final container in logs.containers) container.id],
      ['web2', 'db1', 'cache1'],
    );
    expect(containerLogOpens(engine.sent, 'web2'), hasLength(1));
    expect(containerLogOpens(engine.sent, 'cache1'), hasLength(1));
    expect(
      [
        for (final close in engine.sentOfType<CloseStream>())
          (close as CloseStream).streamId,
      ],
      [streamOf('web1'), streamOf('db1')],
    );
    expect(logs.stateOf('web2'), StackLogState.opening);
    expect(logs.stateOf('db1'), StackLogState.ended);
    expect(logs.hidden, {'db1'}, reason: 'its chip still shows its lines');

    await batch('web2', [containerLine('new', at: _at(3))]);
    await batch('cache1', [containerLine('up', at: _at(4))]);
    expect(texts(logs), ['web-1 old', 'web-1 new', 'cache-1 up']);
    // The new container's lines take the old one's colour.
    String colourOf(int index) =>
        (logs.logs[index] as LogLine).text.split('m').first;
    expect(colourOf(1), colourOf(0));
    expect(colourOf(2), isNot(colourOf(0)));

    logs.toggle('db1');
    expect(texts(logs), ['web-1 old', 'db-1 ready', 'web-1 new', 'cache-1 up']);
    // Showing a gone container's lines reads nothing again.
    expect(containerLogOpens(engine.sent, 'db1'), hasLength(1));

    // An id that was replaced names no container any more: a tap that
    // lands on a chip drawn before the redeploy does nothing.
    logs.toggle('web1');
    expect(logs.hidden, isEmpty);
    expect(logs.stateOf('web1'), StackLogState.ended);
    expect(texts(logs), ['web-1 old', 'db-1 ready', 'web-1 new', 'cache-1 up']);

    // The same containers again change nothing.
    final sent = engine.sent.length;
    logs.setContainers([
      const StackLogContainer(id: 'web2', name: 'web-1'),
      const StackLogContainer(id: 'cache1', name: 'cache-1'),
    ]);
    expect(engine.sent, hasLength(sent));
  });

  testWidgets('a paused page holds its place when an older line arrives '
      '(UIB-3)', (tester) async {
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
    engine.emit(
      containerLogBatch(containerLogOpens(engine.sent, 'web1').last.streamId, [
        for (var i = 0; i < 300; i++)
          containerLine('line $i', at: _at(0).add(Duration(seconds: 10 + i))),
      ]),
    );
    await tester.pump(kStackLogsHold);
    await tester.pumpAndSettle();

    // Scroll up to read: the view pauses.
    final view = find.descendant(
      of: find.byType(LogView),
      matching: find.byType(Scrollable),
    );
    await tester.drag(view.first, const Offset(0, 300));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(view.first).position;
    final offset = position.pixels;
    expect(offset, greaterThan(1000));
    expect(offset, lessThan(position.maxScrollExtent));

    // The other container's batch of the same interval arrives later.
    engine.emit(
      containerLogBatch(containerLogOpens(engine.sent, 'db1').last.streamId, [
        containerLine('older', at: _at(5)),
      ]),
    );
    await tester.pump(kStackLogsHold);
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(view.first).position.pixels, offset);
  });

  testWidgets('a paused view keeps its open fields and current match when '
      'an older batch arrives (UIB-3)', (tester) async {
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

    engine.emit(
      containerLogBatch(streamOf('web1'), [
        containerLine('{"level":"error","msg":"alpha"}', at: _at(10)),
        containerLine('plain line', at: _at(11)),
        containerLine('{"level":"warn","msg":"gamma"}', at: _at(12)),
      ]),
    );
    await tester.pump(kStackLogsHold);
    await tester.pumpAndSettle();

    // Open the first JSON row's fields, which pauses the view.
    final row = find.textContaining('"msg":"alpha"', findRichText: true);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.textContaining('level=error', findRichText: true), findsOne);
    expect(find.textContaining('msg=alpha', findRichText: true), findsOne);

    // Search 'msg' and step to the oldest match.
    await tester.enterText(find.byType(TextField), 'msg');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOne);

    final view = find.descendant(
      of: find.byType(LogView),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(view.first).position;
    final offset = position.pixels;

    // The other container's batch of the same interval arrives later: an
    // older line, then a newer one. Before the hold these rebuilt the view
    // and renumbered every line, closing the fields and losing the match.
    engine.emit(
      containerLogBatch(streamOf('db1'), [
        containerLine('older', at: _at(9)),
        containerLine('newer', at: _at(13)),
      ]),
    );
    await tester.pump(kStackLogsHold);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('level=error', findRichText: true),
      findsOne,
      reason: 'the open fields stayed open',
    );
    expect(find.text('1 of 2'), findsOne, reason: 'the match stayed current');
    expect(position.pixels, offset, reason: 'the paused view held its place');
    expect(find.textContaining('newer', findRichText: true), findsOne);
  });

  testWidgets('the page reads a redeployed stack\'s new containers '
      '(UIB-9)', (tester) async {
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
    for (final id in ['web1', 'db1']) {
      engine.emit(
        LogStreamState(
          containerLogOpens(engine.sent, id).last.streamId,
          const LogStreamEnded(LogStreamEndReason.missing),
        ),
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('web-1: stopped reading'), findsOne);

    // Another stack's list, or one without this stack, changes nothing.
    engine.emit(
      dockerStackList(_serverId, [
        dockerStack('other', [
          dockerService('x', [dockerContainer('x1', name: 'x-1')]),
        ]),
      ], at: _at(1)),
    );
    await tester.pumpAndSettle();
    expect(engine.sentOfType<OpenLogStream>(), hasLength(2));

    engine.emit(
      dockerStackList(_serverId, [
        dockerStack('web', [
          dockerService('web', [dockerContainer('web2', name: 'web-1')]),
          dockerService('db', [dockerContainer('db2', name: 'db-1')]),
        ]),
      ], at: _at(2)),
    );
    await tester.pumpAndSettle();
    expect(containerLogOpens(engine.sent, 'web2'), hasLength(1));
    expect(containerLogOpens(engine.sent, 'db2'), hasLength(1));
    expect(find.text('web-1: stopped reading'), findsNothing);
    expect(find.text('web-1'), findsOne);
    expect(find.byType(FilterChip), findsNWidgets(2));
  });

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

  testWidgets('at three times the text size on a phone the header scrolls '
      'and the log keeps its room', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final monitoring = MonitoringController(engine);
    addTearDown(monitoring.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(3)),
          child: child!,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StackLogsPage(
          monitoring: monitoring,
          serverId: _serverId,
          project: 'web',
          containers: [
            for (var i = 0; i < kStackLogsMax + 2; i++)
              StackLogContainer(id: 'c$i', name: 'service-$i'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    engine.emit(
      containerLogBatch(containerLogOpens(engine.sent, 'c0').last.streamId, [
        containerLine('ready', at: _at(1)),
      ]),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(LogView)).height, greaterThan(100));
  });
}
