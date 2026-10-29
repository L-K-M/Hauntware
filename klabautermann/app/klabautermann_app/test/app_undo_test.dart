import 'dart:ui' show AppExitResponse;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/app.dart' show appNavigatorKey;
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/ui/actions/quit_guard.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';
import 'support/sync_sign_in.dart';

const _servers = [
  FleetServer(
    id: 'srv-1',
    displayName: 'web-1',
    address: 'web-1.example',
    origin: FleetEntryOrigin.synced,
  ),
  FleetServer(
    id: 'srv-2',
    displayName: 'db-1',
    address: '10.0.0.4',
    origin: FleetEntryOrigin.synced,
  ),
];

final _rules = AlertRulesChanged([
  SyncedRule(
    id: 'r-web1',
    target: 'srv-1',
    rule: alertRule(
      metric: 'cpu.busy',
      scope: RuleScope.server,
      op: ThresholdOp.greaterThan,
      raise: const ThresholdBound(value: 90, duration: Duration(minutes: 5)),
      clear: const ThresholdBound(value: 80),
      severity: AlertSeverity.warning,
    ),
  ),
]);

Future<void> _pinWeb1(WidgetTester tester) async {
  await tester.tap(
    find.text('web-1'),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Pin to top'));
  await tester.pumpAndSettle();
}

void main() {
  group('the shared undo history (K3)', () {
    testWidgets('pinning a server records a change Undo takes back', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: _servers);
      await _pinWeb1(tester);
      expect(harness.fleet.pinnedServerIds, {'srv-1'});
      expect(harness.undoHistory.undoName, 'Pin server');

      await harness.undoHistory.undo();
      await tester.pumpAndSettle();
      expect(harness.fleet.pinnedServerIds, isEmpty);
      expect(harness.undoHistory.redoName, 'Pin server');
    });

    testWidgets(
      'Ctrl+Z stands down while a text field has focus',
      (tester) async {
        final harness = await pumpApp(tester, servers: _servers);
        await _pinWeb1(tester);

        await tester.tap(find.byType(TextField).first);
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(harness.fleet.pinnedServerIds, {'srv-1'});
        expect(harness.undoHistory.undoName, 'Pin server');

        // Focus off the field — onto a row, as a click does — the same
        // chord undoes the pin and says so.
        await tester.tap(find.text('web-1'));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(harness.fleet.pinnedServerIds, isEmpty);
        expect(find.text('Pin server undone'), findsOneWidget);
      },
      // Desktops bind the suite chords; phones have no chord layer.
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets('deleting an alert rule offers Undo, which puts it back', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        servers: _servers,
        alerts: true,
        syncAccount: testSyncAccount,
      );
      harness.engine.emit(_rules);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Alert rules'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete rule'));
      await tester.pumpAndSettle();
      final remove =
          harness.engine.sentOfType<RemoveRule>().single as RemoveRule;
      harness.engine.emit(CatalogWritten(requestId: remove.requestId));
      await tester.pumpAndSettle();
      expect(harness.undoHistory.undoName, 'Delete alert rule');
      expect(find.text('Alert rule deleted'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      final puts = harness.engine.sentOfType<PutRule>();
      expect(puts, hasLength(1));
      final put = puts.single as PutRule;
      expect(put.ruleId, 'r-web1');
      expect(put.target, 'srv-1');
    });

    testWidgets('rule Undo survives leaving the page and reports refusal', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        servers: _servers,
        alerts: true,
        syncAccount: testSyncAccount,
      );
      harness.engine.emit(_rules);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Alert rules'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete rule'));
      await tester.pumpAndSettle();
      final remove =
          harness.engine.sentOfType<RemoveRule>().single as RemoveRule;
      harness.engine.emit(CatalogWritten(requestId: remove.requestId));
      await tester.pumpAndSettle();

      appNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final put = harness.engine.sentOfType<PutRule>().single as PutRule;
      harness.engine.emit(
        CatalogWriteRefused(
          requestId: put.requestId,
          failure: CatalogWriteFailure.notEnrolled,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Couldn’t undo “Delete alert rule”'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the quit guard (K4)', () {
    DetachedOperation running() => DetachedOperation(
      id: '0123456789abcdef',
      directory: OpDirectoryKind.user,
      state: DetachedOperationState.running,
      startedAt: DateTime.utc(2026, 10, 18, 9, 30),
      action: 'RedeployStack',
      targetName: 'shop',
    );

    testWidgets('with nothing running, the close goes ahead without '
        'asking', (tester) async {
      final harness = await pumpApp(tester, operations: true);
      expect(
        await confirmQuitWhileRunning(
          harness.operations!,
          () => appNavigatorKey.currentContext,
        ),
        isTrue,
      );
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('application exit asks before quitting with running work', (
      tester,
    ) async {
      final harness = await pumpApp(tester, operations: true);
      harness.engine.emit(OperationsChanged('srv-1', operations: [running()]));
      await tester.pumpAndSettle();

      final exiting = tester.binding.handleRequestAppExit();
      await tester.pumpAndSettle();
      expect(find.text('Quit while 1 operation is running?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await exiting, AppExitResponse.cancel);
    });

    testWidgets('overlapping close requests share one question', (
      tester,
    ) async {
      final harness = await pumpApp(tester, operations: true);
      harness.engine.emit(OperationsChanged('srv-1', operations: [running()]));
      await tester.pumpAndSettle();
      final guard = AppQuitGuard(
        operations: harness.operations!,
        contextOf: () => appNavigatorKey.currentContext,
      );
      addTearDown(guard.dispose);

      final windowClose = guard.confirm();
      final applicationQuit = guard.confirm();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await windowClose, isFalse);
      expect(await applicationQuit, isFalse);

      final retry = guard.confirm();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quit'));
      await tester.pumpAndSettle();
      expect(await retry, isTrue);
      expect(await guard.confirm(), isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('with detached operations running, it asks — Cancel holds '
        'the window, Quit lets it go', (tester) async {
      final harness = await pumpApp(tester, operations: true);
      harness.engine.emit(OperationsChanged('srv-1', operations: [running()]));
      await tester.pumpAndSettle();

      final vetoed = confirmQuitWhileRunning(
        harness.operations!,
        () => appNavigatorKey.currentContext,
      );
      await tester.pumpAndSettle();
      expect(find.text('Quit while 1 operation is running?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await vetoed, isFalse);

      final accepted = confirmQuitWhileRunning(
        harness.operations!,
        () => appNavigatorKey.currentContext,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quit'));
      await tester.pumpAndSettle();
      expect(await accepted, isTrue);
    });
  });
}
