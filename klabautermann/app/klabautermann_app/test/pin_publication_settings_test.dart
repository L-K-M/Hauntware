import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/pin_publication_controller.dart';
import 'package:klabautermann_app/controllers/sync_secrets_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/ui/settings_page.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';
import 'support/sync_sign_in.dart';

/// Host key sharing as a settings value, with the changes asked of it.
final class _Pins extends ValueNotifier<PinPublication>
    implements PinPublicationSettings {
  _Pins(super.value);

  final List<bool> asked = [];
  bool refuse = false;

  @override
  Future<void> setAsserted(bool asserted) async {
    asked.add(asserted);
    if (refuse) throw const PinPublicationNotChangedException('refused');
    value = PinPublication(release: value.release, asserted: asserted);
  }
}

// M5 plan M07: the host key assertion in Settings > Sync and at sign-in,
// shown only once a release is named.
void main() {
  Future<void> pumpSyncTab(WidgetTester tester, _Pins pins) async {
    final syncSecrets = SyncSecretsController(apply: (_) {});
    addTearDown(syncSecrets.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncTab(syncSecrets: syncSecrets, pinPublication: pins),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the Sync tab offers no host key row while no release is '
      'named', (tester) async {
    await pumpSyncTab(tester, _Pins(const PinPublication()));

    expect(find.text('Host keys'), findsNothing);
    expect(find.byType(SwitchListTile), findsOneWidget);
  });

  testWidgets('with a release named, the Sync tab asserts and withdraws, '
      'and says when a change did not take', (tester) async {
    final pins = _Pins(const PinPublication(release: '2026.11.0'));
    await pumpSyncTab(tester, pins);

    final row = find.text('Every device runs Séance 2026.11.0 or later');
    expect(find.text('Host keys'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(pins.asked, [true]);
    expect(pins.value.asserted, isTrue);

    pins.refuse = true;
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(pins.asked, [true, false]);
    expect(find.text('The host key setting could not be changed.'), findsOne);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a sign-in with the host key tick asserts the release once '
      'signed in', (tester) async {
    final harness = await pumpApp(
      tester,
      pinPublication: const PinPublicationState(release: '2026.11.0'),
    );

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

    expect(find.byType(Checkbox), findsNWidgets(2));
    await tester.tap(find.byType(Checkbox).first);
    await tester.tap(
      find.text('Every device on this account runs Séance 2026.11.0 or later'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(harness.engine.sentOfType<SetPinPublication>(), isEmpty);

    harness.engine.emit(
      const SyncStatus(
        SyncPhase.succeeded,
        operation: SyncOperation.enroll,
        account: testSyncAccount,
      ),
    );
    await tester.pump();
    final request =
        harness.engine.sentOfType<SetPinPublication>().single
            as SetPinPublication;
    expect(request.asserted, isTrue);
    harness.engine.emit(
      const PinPublicationState(release: '2026.11.0', asserted: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('Before you sign in'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  test('the settings link carries the state, and none when it is absent', () {
    const state = PinPublication(release: '2026.11.0', asserted: true);
    expect(decodePinPublication(encodePinPublication(state)), state);
    expect(decodePinPublication(null), const PinPublication());
  });
}
