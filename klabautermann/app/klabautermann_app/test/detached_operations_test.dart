// Detached operations in the app (M4 E23, 03 §7.17, SAF-23): the server
// header's chip counts what runs and what waits to be seen, the sheet
// words each state, acknowledging asks the engine, the output follows the
// operation's log, and a fresh list after a reconnect replaces the old.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/actions/detached_operations.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';
const _id = '0123456789abcdef';

DetachedOperation _op({
  String id = _id,
  DetachedOperationState state = DetachedOperationState.running,
  OpDirectoryKind directory = OpDirectoryKind.user,
  int? exitCode,
  bool mine = true,
  bool acknowledged = false,
}) => DetachedOperation(
  id: id,
  directory: directory,
  state: state,
  startedAt: DateTime.utc(2026, 10, 18, 9, 30),
  exitCode: exitCode,
  action: mine ? 'RedeployStack' : null,
  targetName: mine ? 'shop' : null,
  acknowledged: acknowledged,
);

void main() {
  late FakeEngineClient engine;
  late MonitoringController monitoring;
  late OperationsController operations;

  // Made inside each test, in its fake-async zone, so the engine's
  // events reach the controllers while the test pumps.
  Future<void> pump(WidgetTester tester) async {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
    operations = OperationsController(engine);
    addTearDown(() async {
      operations.dispose();
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OperationsScope(
          operations: operations,
          child: Scaffold(
            body: Center(
              child: DetachedOperationsChip(
                serverId: _server,
                serverName: 'web',
                monitoring: monitoring,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> list(
    WidgetTester tester,
    Iterable<DetachedOperation> ops, {
    Map<OpDirectoryKind, OpDirectoryListing> directories = const {},
  }) async {
    engine.emit(
      OperationsChanged(_server, operations: ops, directories: directories),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
  }

  testWidgets('the chip stays hidden without operations', (tester) async {
    await pump(tester);
    expect(find.byType(ActionChip), findsNothing);
    await list(tester, const []);
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets('a running operation is counted and shown without a clear', (
    tester,
  ) async {
    await pump(tester);
    await list(tester, [_op()]);
    expect(find.text('1 operation running'), findsOneWidget);

    await openSheet(tester);
    expect(find.text('Operations on web'), findsOneWidget);
    expect(find.text('Redeploy stack: shop'), findsOneWidget);
    expect(find.textContaining('Running since'), findsOneWidget);
    expect(find.text('Clear'), findsNothing);
  });

  testWidgets('an ended result waits to be seen, and clearing it asks the '
      'engine', (tester) async {
    await pump(tester);
    await list(tester, [_op(state: DetachedOperationState.done, exitCode: 0)]);
    expect(find.text('1 operation result'), findsOneWidget);

    await openSheet(tester);
    expect(find.text('Finished.'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(
      engine.sent.whereType<AcknowledgeOperation>().map(
        (r) => (r.serverId, r.id),
      ),
      [(_server, _id)],
    );

    // The engine's next list drops it; the sheet and the chip follow.
    await list(tester, const []);
    await tester.pumpAndSettle();
    expect(find.text('No operations.'), findsOneWidget);
  });

  testWidgets('each state is worded', (tester) async {
    await pump(tester);
    await list(
      tester,
      [
        _op(id: 'a' * 16, state: DetachedOperationState.done, exitCode: 2),
        _op(id: 'b' * 16, state: DetachedOperationState.lost),
        _op(id: 'c' * 16, state: DetachedOperationState.unknown, mine: false),
        _op(
          id: 'd' * 16,
          state: DetachedOperationState.done,
          exitCode: 0,
          directory: OpDirectoryKind.root,
          acknowledged: true,
        ),
      ],
      directories: const {
        OpDirectoryKind.root: OpDirectoryListing(
          state: OpDirectoryState.denied,
        ),
      },
    );
    expect(find.text('2 operation results'), findsOneWidget);

    await openSheet(tester);
    expect(find.text('Failed with exit status 2.'), findsOneWidget);
    expect(find.textContaining('Stopped before it finished'), findsOneWidget);
    expect(find.text('Its state could not be read.'), findsOneWidget);
    expect(find.text('Operation ${'c' * 16}'), findsOneWidget);
    expect(find.text('Started on another device.'), findsOneWidget);
    expect(
      find.text('Cleared. Its files are deleted once admin mode is on.'),
      findsOneWidget,
    );
    expect(find.textContaining('Some operations may be missing'), findsOne);
    expect(find.text('Clear'), findsNWidgets(2), reason: 'failed and lost');
  });

  testWidgets('a done run without an exit status reads as finished, not '
      'failed', (tester) async {
    await pump(tester);
    await list(tester, [_op(state: DetachedOperationState.done)]);

    await openSheet(tester);
    final finished = find.text('Finished.');
    final error = Theme.of(tester.element(finished)).colorScheme.error;
    expect(tester.widget<Text>(finished).style?.color, isNot(error));
  });

  testWidgets("the output follows the operation's log until it closes", (
    tester,
  ) async {
    await pump(tester);
    await list(tester, [_op()]);
    await openSheet(tester);

    await tester.tap(find.text('Show output'));
    await tester.pumpAndSettle();
    expect(find.text('Output of Redeploy stack: shop'), findsOneWidget);
    final open = engine.sent.whereType<OpenLogStream>().single;
    expect(open.spec.serverId, _server);
    expect(open.spec.follow, isTrue);
    expect(
      open.spec.source,
      isA<OperationLogSource>().having((s) => s.operationId, 'id', _id),
    );

    await tester.tap(find.byTooltip('Close output'));
    await tester.pumpAndSettle();
    expect(engine.sent.whereType<CloseStream>().map((c) => c.streamId), [
      open.streamId,
    ]);
  });

  testWidgets('a list after a reconnect replaces the one before', (
    tester,
  ) async {
    await pump(tester);
    await list(tester, [_op()]);
    expect(find.text('1 operation running'), findsOneWidget);

    // Re-attached on the new link: the run ended while the app was away.
    await list(tester, [_op(state: DetachedOperationState.done, exitCode: 0)]);
    expect(find.text('1 operation result'), findsOneWidget);
    expect(
      operations.detachedOf(_server).single.state,
      DetachedOperationState.done,
    );
  });
}
