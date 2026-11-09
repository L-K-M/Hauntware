import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/prompts/elevation_dialog.dart';

// The admin-mode sudo password (03 §8.2) stays out of the keyboard's
// learning, as the shared credential dialog's secrets do (#625).
void main() {
  testWidgets('the sudo password keeps the keyboard from learning it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showElevationPasswordDialog(
                context,
                user: 'deploy',
                host: 'box.example.com',
                retry: false,
                dialogKey: GlobalKey(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final secret = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Password'),
    );
    expect(secret.obscureText, isTrue);
    expect(secret.autocorrect, isFalse);
    expect(secret.enableSuggestions, isFalse);
    expect(secret.enableIMEPersonalizedLearning, isFalse);
  });
}
