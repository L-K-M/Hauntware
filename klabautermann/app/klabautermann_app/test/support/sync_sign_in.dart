import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'fake_engine.dart';

/// The account every sign-in test enters.
const testSyncAccount = SyncAccountInfo(
  baseUrl: 'https://sync.example.com',
  username: 'ops',
);

/// Opens the sign-in from the sync control, fills step 1, ticks step 2's
/// fleet assertion and signs in, then answers as the engine would with
/// [answer], or a success for [testSyncAccount].
Future<void> signInThroughTheSheet(
  WidgetTester tester,
  FakeEngineClient engine, {
  SyncStatus? answer,
}) async {
  await tester.tap(find.text('Synchronize'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Server address'),
    testSyncAccount.baseUrl,
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Account name'),
    testSyncAccount.username,
  );
  await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
  await tester.enterText(
    find.widgetWithText(TextField, 'Encryption passphrase'),
    'pp',
  );
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(Checkbox));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pump();
  engine.emit(
    answer ??
        const SyncStatus(
          SyncPhase.succeeded,
          operation: SyncOperation.enroll,
          account: testSyncAccount,
        ),
  );
  await tester.pumpAndSettle();
}
