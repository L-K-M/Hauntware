import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/settings_screen.dart';
import 'package:seance_core/seance_core.dart' show SyncEnrollmentMode;

void main() {
  late TextEditingController password;
  late TextEditingController encryptionPassphrase;
  late TextEditingController confirmation;

  setUp(() {
    password = TextEditingController();
    encryptionPassphrase = TextEditingController();
    confirmation = TextEditingController();
  });

  tearDown(() {
    password.dispose();
    encryptionPassphrase.dispose();
    confirmation.dispose();
  });

  Future<void> pumpFields(
    WidgetTester tester,
    SyncEnrollmentMode mode, {
    VoidCallback? onSubmit,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SyncEnrollmentFields(
          mode: mode,
          passwordController: password,
          encryptionPassphraseController: encryptionPassphrase,
          confirmationController: confirmation,
          onSubmit: onSubmit,
        ),
      ),
    ),
  );

  testWidgets('login shows both required secrets without confirmation', (
    tester,
  ) async {
    await pumpFields(tester, SyncEnrollmentMode.login);

    expect(find.text('Account password'), findsOneWidget);
    expect(find.text('Vault encryption passphrase'), findsOneWidget);
    expect(find.text('Confirm vault encryption passphrase'), findsNothing);
  });

  testWidgets('registration adds encryption passphrase confirmation', (
    tester,
  ) async {
    await pumpFields(tester, SyncEnrollmentMode.register);

    expect(find.text('Account password'), findsOneWidget);
    expect(find.text('Vault encryption passphrase'), findsOneWidget);
    expect(find.text('Confirm vault encryption passphrase'), findsOneWidget);
  });

  testWidgets('secret fields keep the keyboard from learning them', (
    tester,
  ) async {
    await pumpFields(tester, SyncEnrollmentMode.register);

    for (final label in [
      'Account password',
      'Vault encryption passphrase',
      'Confirm vault encryption passphrase',
    ]) {
      final secret = tester.widget<TextField>(
        find.widgetWithText(TextField, label),
      );
      expect(secret.autocorrect, isFalse, reason: label);
      expect(secret.enableSuggestions, isFalse, reason: label);
      expect(secret.enableIMEPersonalizedLearning, isFalse, reason: label);
    }
  });

  testWidgets('Return in the last login field runs the primary action', (
    tester,
  ) async {
    var runs = 0;
    await pumpFields(tester, SyncEnrollmentMode.login, onSubmit: () => runs++);

    await tester.tap(find.byKey(const ValueKey('sync-account-password')));
    await tester.testTextInput.receiveAction(TextInputAction.next);
    expect(runs, 0);

    await tester.tap(find.byKey(const ValueKey('sync-encryption-passphrase')));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(runs, 1);
  });

  testWidgets('registration submits only from the confirmation field', (
    tester,
  ) async {
    var runs = 0;
    await pumpFields(
      tester,
      SyncEnrollmentMode.register,
      onSubmit: () => runs++,
    );

    await tester.tap(find.byKey(const ValueKey('sync-encryption-passphrase')));
    await tester.testTextInput.receiveAction(TextInputAction.next);
    expect(runs, 0);

    await tester.tap(
      find.byKey(const ValueKey('sync-encryption-passphrase-confirmation')),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(runs, 1);
  });
}
