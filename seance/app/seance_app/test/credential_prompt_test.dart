import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/missing_credential.dart';
import 'package:seance_app/ui/credential_prompt.dart';
import 'package:seance_core/seance_core.dart';

/// CRED-05's inline prompt: the password or key a tab could not find,
/// asked for in place.
void main() {
  final answers = <MissingCredential?>[];
  setUp(answers.clear);

  Future<void> open(
    WidgetTester tester, {
    required AuthMethod authMethod,
    Future<String?> Function()? pickKeyText,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => answers.add(
                await showMissingCredentialDialog(
                  context,
                  serverLabel: 'box',
                  authMethod: authMethod,
                  pickKeyText: pickKeyText ?? () async => null,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  FilledButton save(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const ValueKey('credential.save')),
  );

  testWidgets('a password, once typed, is the answer', (tester) async {
    await open(tester, authMethod: AuthMethod.password);
    expect(find.text('Password for box'), findsOneWidget);
    expect(save(tester).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('credential.password')),
      'hunter2',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('credential.save')));
    await tester.pumpAndSettle();

    expect(answers.single, isA<MissingPassword>());
    expect((answers.single! as MissingPassword).password, 'hunter2');
  });

  testWidgets('a key comes from a file or a paste, with its passphrase', (
    tester,
  ) async {
    await open(
      tester,
      authMethod: AuthMethod.privateKey,
      pickKeyText: () async => '-----BEGIN OPENSSH PRIVATE KEY-----\nabc',
    );
    expect(find.text('Private key for box'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('credential.chooseFile')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('credential.key')))
          .controller!
          .text,
      startsWith('-----BEGIN OPENSSH'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('credential.passphrase')),
      'pp',
    );
    await tester.tap(find.byKey(const ValueKey('credential.save')));
    await tester.pumpAndSettle();

    final key = answers.single! as MissingPrivateKey;
    expect(key.pem, startsWith('-----BEGIN OPENSSH'));
    expect(key.passphrase, 'pp');
  });

  testWidgets('no passphrase is no passphrase, not an empty one', (
    tester,
  ) async {
    await open(tester, authMethod: AuthMethod.privateKey);
    await tester.enterText(find.byKey(const ValueKey('credential.key')), 'PEM');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('credential.save')));
    await tester.pumpAndSettle();

    expect((answers.single! as MissingPrivateKey).passphrase, isNull);
  });

  testWidgets('a file that is not a key says so and keeps the dialog', (
    tester,
  ) async {
    await open(
      tester,
      authMethod: AuthMethod.privateKey,
      pickKeyText: () async =>
          throw const FormatException('That file is not a text private key.'),
    );

    await tester.tap(find.byKey(const ValueKey('credential.chooseFile')));
    await tester.pumpAndSettle();

    expect(find.text('That file is not a text private key.'), findsOneWidget);
    expect(answers, isEmpty);
  });

  testWidgets('cancelling answers nothing', (tester) async {
    await open(tester, authMethod: AuthMethod.password);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(answers, [null]);
  });
}
