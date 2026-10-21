import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';
import 'support/sync_sign_in.dart';

// 03 §4.3 steps 1 and 2: the sign-in, the fleet assertion and the
// disclosures, and the sync control around them.
void main() {
  testWidgets('step 1 checks the fields before step 2, and nothing is sent '
      'before the fleet assertion', (tester) async {
    final harness = await pumpApp(tester);

    await tester.tap(find.text('Synchronize'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to your Séance account'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Server address'),
      'sync.example.com',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter the server address, starting with https:// or http://.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Server address'),
      'https://sync.example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Account name'),
      'ops',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.enterText(
      find.widgetWithText(TextField, 'Encryption passphrase'),
      'pp',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Before you sign in'), findsOneWidget);
    expect(
      find.textContaining('It publishes no servers, host keys or passwords.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('opens the records of every app on this account'),
      findsOneWidget,
    );
    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    expect(tester.widget<FilledButton>(signIn).onPressed, isNull);
    expect(harness.engine.sentOfType<EnrollSync>(), isEmpty);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(signIn);
    await tester.pump();

    final request =
        harness.engine.sentOfType<EnrollSync>().single as EnrollSync;
    expect(
      (
        request.baseUrl,
        request.username,
        request.password,
        request.encryptionPassphrase,
      ),
      ('https://sync.example.com', 'ops', 'pw', 'pp'),
    );
    harness.engine.emit(
      const SyncStatus(
        SyncPhase.succeeded,
        operation: SyncOperation.enroll,
        account: testSyncAccount,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Before you sign in'), findsNothing);
    expect(
      find.text('Signed in. Your Séance servers are now in the fleet.'),
      findsOneWidget,
    );
    expect(harness.sync.account, testSyncAccount);
  });

  testWidgets('a refused sign-in says why and keeps the sheet open', (
    tester,
  ) async {
    final harness = await pumpApp(tester);

    await signInThroughTheSheet(
      tester,
      harness.engine,
      answer: const SyncStatus(
        SyncPhase.failed,
        operation: SyncOperation.enroll,
        failure: SyncFailure.credentialsRejected,
      ),
    );

    expect(
      find.text('The server did not accept this account name and password.'),
      findsOneWidget,
    );
    expect(find.text('Before you sign in'), findsOneWidget);
    expect(harness.sync.account, isNull);
  });

  testWidgets('once signed in, the phone sync button runs a round and tells '
      'a failure', (tester) async {
    final harness = await pumpApp(
      tester,
      size: const Size(400, 800),
      syncAccount: testSyncAccount,
    );

    final button = find.byTooltip('Synchronize with sync.example.com as ops');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(harness.engine.sentOfType<RunSyncRound>(), hasLength(1));
    harness.engine.emit(
      const SyncStatus(
        SyncPhase.failed,
        operation: SyncOperation.round,
        account: testSyncAccount,
        failure: SyncFailure.unreachable,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The sync server could not be reached. Check the address and your '
        'connection.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a damaged sync file is told at startup', (tester) async {
    await pumpApp(
      tester,
      syncStoreIssues: const [
        SyncStoreIssue(
          'pin_verdicts.json',
          SyncStoreIssueKind.recovered,
          preservedAs: '/support/pin_verdicts.json.corrupt-20261016T093005250Z',
        ),
      ],
    );

    expect(
      find.text(
        'The sync file pin_verdicts.json could not be read and was cleared. '
        'The old file is kept as '
        'pin_verdicts.json.corrupt-20261016T093005250Z.',
      ),
      findsOneWidget,
    );
  });
}
