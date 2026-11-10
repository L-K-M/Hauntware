// CRED-05's enrolment prompt: after a credential is saved on a device
// without a recovery code, the code is offered once; "Not now" is
// remembered, and dismissing without an answer leaves the offer standing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/recovery_settings.dart';
import 'package:poltergeist_app/services/secrets_recovery.dart';
import 'package:poltergeist_app/ui/recovery_prompt.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final class _FakeFiles implements SecretsExportFiles {
  @override
  Future<String?> save(Uint8List bytes, String fileName) async => null;

  @override
  Future<Uint8List?> open() async => null;
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late RecoverySettings settings;
  late List<bool> declined;

  setUp(() {
    final store = InMemoryVaultStore();
    final recovery = SecretsRecovery(
      store,
      () async => SecretVault(store, Uint8List(32)),
    );
    declined = [];
    settings = RecoverySettings(
      recovery: recovery,
      files: _FakeFiles(),
      promptDeclined: false,
      savePromptDeclined: (value) async => declined.add(value),
    );
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => offerRecoveryCode(context, settings),
              child: const Text('saved a credential'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('"Not now" is remembered and the offer is not made again', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('saved a credential'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryPromptTitle), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recovery.prompt.notNow')));
    await tester.pumpAndSettle();
    expect(declined, [true]);
    expect(settings.promptDeclined, isTrue);

    await tester.tap(find.text('saved a credential'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryPromptTitle), findsNothing);
  });

  testWidgets('setting up shows the code and keeps it once confirmed', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('saved a credential'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery.prompt.setUp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery.code')), findsOneWidget);

    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('recovery.code')))
        .data!;
    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      code.split('-').first,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recovery.code.done')));
    await tester.pumpAndSettle();

    expect(await settings.recoveryConfigured(), isTrue);

    // With a code, saving another credential offers nothing.
    await tester.tap(find.text('saved a credential'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryPromptTitle), findsNothing);
  });

  testWidgets('Return in the confirmation field keeps the code once it '
      'matches', (tester) async {
    await pump(tester);

    await tester.tap(find.text('saved a credential'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery.prompt.setUp')));
    await tester.pumpAndSettle();
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('recovery.code')))
        .data!;
    final field = find.byKey(const ValueKey('recovery.code.confirm'));

    await tester.enterText(field, 'ZZZZ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byKey(const ValueKey('recovery.code')), findsOneWidget);

    await tester.enterText(field, code.split('-').first);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recovery.code')), findsNothing);
    expect(await settings.recoveryConfigured(), isTrue);
  });

  testWidgets('dismissing without an answer asks again next time', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('saved a credential'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryPromptTitle), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryPromptTitle), findsNothing);
    expect(settings.promptDeclined, isFalse);

    await tester.tap(find.text('saved a credential'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryPromptTitle), findsOneWidget);
  });
}
