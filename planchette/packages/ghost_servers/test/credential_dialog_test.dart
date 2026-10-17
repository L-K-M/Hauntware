import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_protocol/seance_protocol.dart' show AuthMethod;

const _mono = TextStyle(fontFamily: 'Host Mono');

// Split so no file carries a private-key header
// (scripts/assert-private-keys-scoped.sh).
const _pemHead =
    '-----BEGIN OPENSSH'
    ' PRIVATE KEY-----';

/// CRED-05's inline prompt: the password or key a tab could not find,
/// asked for in place. Widget tests moved here from Séance with the
/// dialog; the moved cases run in Séance's configuration (the pasted key
/// field, a dismissible barrier). The cases after them cover the package's
/// own parameters and the identity-file form.
void main() {
  final answers = <GhostCredentialReply?>[];
  setUp(answers.clear);

  Future<void> openRequest(
    WidgetTester tester,
    GhostCredentialRequest request, {
    GhostCredentialStrings strings = const GhostCredentialStrings(),
    Future<String?> Function()? pickKeyText,
    Future<String> Function(String path)? readKeyFile,
    GlobalKey? dialogKey,
    bool barrierDismissible = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => answers.add(
                await showGhostCredentialDialog(
                  context,
                  request,
                  strings: strings,
                  pickKeyText: pickKeyText,
                  readKeyFile: readKeyFile,
                  monoStyle: _mono,
                  dialogKey: dialogKey,
                  barrierDismissible: barrierDismissible,
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

  Future<void> open(
    WidgetTester tester, {
    required AuthMethod authMethod,
    Future<String?> Function()? pickKeyText,
  }) => openRequest(
    tester,
    GhostCredentialRequest(
      authMethod: authMethod,
      endpointLabel: 'box',
      keyField: GhostKeyField.pastedPem,
    ),
    pickKeyText: pickKeyText ?? () async => null,
    barrierDismissible: true,
  );

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

    expect(answers.single, isA<GhostPasswordReply>());
    expect((answers.single! as GhostPasswordReply).password, 'hunter2');
  });

  testWidgets('a key comes from a file or a paste, with its passphrase', (
    tester,
  ) async {
    await open(
      tester,
      authMethod: AuthMethod.privateKey,
      pickKeyText: () async => '$_pemHead\nabc',
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

    final key = answers.single! as GhostPrivateKeyReply;
    expect(key.privateKeyPem, startsWith('-----BEGIN OPENSSH'));
    expect(key.keyPassphrase, 'pp');
  });

  testWidgets('no passphrase is no passphrase, not an empty one', (
    tester,
  ) async {
    await open(tester, authMethod: AuthMethod.privateKey);
    await tester.enterText(find.byKey(const ValueKey('credential.key')), 'PEM');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('credential.save')));
    await tester.pumpAndSettle();

    expect((answers.single! as GhostPrivateKeyReply).keyPassphrase, isNull);
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

  testWidgets("Séance's words are the defaults", (tester) async {
    await open(tester, authMethod: AuthMethod.privateKey);

    for (final text in [
      'Private key for box',
      'Saved on this device, in its encrypted vault, and used for this '
          'server from now on.',
      'Choose key file…',
      'Private key (PEM)',
      _pemHead,
      'Key passphrase (if it has one)',
      'Cancel',
      'Save and connect',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('credential.key')))
          .style,
      _mono.copyWith(fontSize: 12),
    );
  });

  testWidgets('a file that cannot be read shows none of its error', (
    tester,
  ) async {
    await open(
      tester,
      authMethod: AuthMethod.privateKey,
      pickKeyText: () async => throw StateError('/home/alice/.ssh/id_rsa'),
    );

    await tester.tap(find.byKey(const ValueKey('credential.chooseFile')));
    await tester.pumpAndSettle();

    expect(find.text('That file could not be opened.'), findsOneWidget);
    expect(find.textContaining('alice'), findsNothing);
    expect(answers, isEmpty);
  });

  testWidgets('the injector for the key field is required', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );

    for (final (keyField, missing) in [
      (GhostKeyField.pastedPem, 'pickKeyText'),
      (GhostKeyField.filePath, 'readKeyFile'),
    ]) {
      expect(
        () => showGhostCredentialDialog(
          context,
          GhostCredentialRequest(
            authMethod: AuthMethod.password,
            endpointLabel: 'box',
            keyField: keyField,
          ),
          // The other field's injector does not stand in.
          pickKeyText: keyField == GhostKeyField.filePath
              ? () async => null
              : null,
          readKeyFile: keyField == GhostKeyField.pastedPem
              ? (_) async => 'PEM'
              : null,
          monoStyle: _mono,
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', missing)),
        reason: '$keyField',
      );
    }
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a tap outside cancels only where the host allows it', (
    tester,
  ) async {
    const request = GhostCredentialRequest(
      authMethod: AuthMethod.password,
      endpointLabel: 'box',
      keyField: GhostKeyField.pastedPem,
    );
    await openRequest(tester, request, pickKeyText: () async => null);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Password for box'), findsOneWidget);
    expect(answers, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    answers.clear();

    await openRequest(
      tester,
      request,
      pickKeyText: () async => null,
      barrierDismissible: true,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(answers, [null]);
  });

  testWidgets("a host's words, endpoint and dialog key reach the dialog", (
    tester,
  ) async {
    final dialogKey = GlobalKey();
    final endpoints = <(String?, String, int)>[];
    final strings = GhostCredentialStrings(
      passwordTitle: (label) => 'password title $label',
      privateKeyTitle: (label) => 'key title $label',
      explanation: null,
      endpoint: (username, host, port) {
        endpoints.add((username, host, port));
        return '$host port $port as $username';
      },
      vaultUnavailable: 'vault unavailable',
      passwordField: 'password field',
      chooseKeyFile: 'choose',
      keyPemField: 'pem field',
      keyPemHint: 'pem hint',
      keyFileField: 'path field',
      keyFileRequired: 'path required',
      keyFileError: (error) => 'read error',
      passphraseField: 'passphrase field',
      saveInVault: 'save in vault',
      cancel: 'no',
      connect: 'yes',
    );
    await openRequest(
      tester,
      const GhostCredentialRequest(
        authMethod: AuthMethod.privateKey,
        endpointLabel: 'box',
        keyField: GhostKeyField.pastedPem,
        username: 'root',
        host: '2001:db8::1',
        port: 22,
      ),
      strings: strings,
      pickKeyText: () async => throw StateError('unreadable'),
      dialogKey: dialogKey,
    );

    expect(
      find.descendant(
        of: find.byKey(dialogKey),
        matching: find.byType(AlertDialog),
      ),
      findsOneWidget,
    );
    // The formatter receives the host as configured, without brackets.
    expect(endpoints.toSet(), {('root', '2001:db8::1', 22)});
    for (final text in [
      'key title box',
      '2001:db8::1 port 22 as root',
      'choose',
      'pem field',
      'pem hint',
      'passphrase field',
      'no',
      'yes',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.textContaining('Saved on this device'), findsNothing);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).style,
      _mono.copyWith(fontSize: 12),
    );

    await tester.tap(find.text('choose'));
    await tester.pumpAndSettle();
    expect(find.text('read error'), findsOneWidget);
  });

  testWidgets('an endpoint without a username shows the host and port', (
    tester,
  ) async {
    await openRequest(
      tester,
      const GhostCredentialRequest(
        authMethod: AuthMethod.password,
        endpointLabel: 'box',
        keyField: GhostKeyField.pastedPem,
        host: 'example.com',
        port: 2222,
      ),
      pickKeyText: () async => null,
    );

    expect(find.text('example.com:2222'), findsOneWidget);
  });

  group('the identity-file form', () {
    GhostCredentialRequest pathRequest({
      AuthMethod authMethod = AuthMethod.privateKey,
      String? initialKeyPath = '~/.ssh/id_ed25519',
      bool offerVaultSave = false,
      bool vaultUnavailable = false,
    }) => GhostCredentialRequest(
      authMethod: authMethod,
      endpointLabel: 'box',
      keyField: GhostKeyField.filePath,
      username: 'deploy',
      host: 'example.com',
      port: 2222,
      initialKeyPath: initialKeyPath,
      offerVaultSave: offerVaultSave,
      vaultUnavailable: vaultUnavailable,
    );

    TextField field(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(ValueKey(key)));

    testWidgets('a password answers on Enter, with suggestions off', (
      tester,
    ) async {
      await openRequest(
        tester,
        pathRequest(authMethod: AuthMethod.password),
        readKeyFile: (_) async => fail('a password reads no file'),
      );
      expect(find.text('deploy@example.com:2222'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      // Unlike the pasted form, the answer is enabled before anything is
      // typed.
      expect(save(tester).onPressed, isNotNull);

      final password = field(tester, 'credential.password');
      expect(password.autofocus, isTrue);
      expect(password.autocorrect, isFalse);
      expect(password.enableSuggestions, isFalse);
      expect(password.enableIMEPersonalizedLearning, isFalse);

      await tester.enterText(
        find.byKey(const ValueKey('credential.password')),
        'pw',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final reply = answers.single! as GhostPasswordReply;
      expect(reply.password, 'pw');
      expect(reply.saveToVault, isFalse);
    });

    testWidgets('a key is read from the typed path on submit', (tester) async {
      final reads = <String>[];
      await openRequest(
        tester,
        pathRequest(),
        readKeyFile: (path) async {
          reads.add(path);
          return 'PEM';
        },
      );
      expect(
        field(tester, 'credential.keyFile').controller!.text,
        '~/.ssh/id_ed25519',
      );
      expect(reads, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('credential.keyFile')),
        '  ~/.ssh/id_work  ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('credential.passphrase')),
        'pp',
      );
      // Enter in the passphrase field submits.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(reads, ['~/.ssh/id_work']);
      final reply = answers.single! as GhostPrivateKeyReply;
      expect(reply.privateKeyPem, 'PEM');
      expect(reply.keyPassphrase, 'pp');
    });

    testWidgets('an empty path asks for one and reads nothing', (tester) async {
      var reads = 0;
      await openRequest(
        tester,
        pathRequest(initialKeyPath: null),
        readKeyFile: (_) async {
          reads++;
          return 'PEM';
        },
      );

      await tester.tap(find.text('Save and connect'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a key file.'), findsOneWidget);
      expect(reads, 0);
      expect(answers, isEmpty);

      // Editing the path clears the error.
      await tester.enterText(
        find.byKey(const ValueKey('credential.keyFile')),
        '~',
      );
      await tester.pump();
      expect(find.text('Choose a key file.'), findsNothing);
    });

    testWidgets("a failing read shows the host's words and stays open", (
      tester,
    ) async {
      final errors = <Object>[];
      await openRequest(
        tester,
        pathRequest(),
        strings: GhostCredentialStrings(
          keyFileError: (error) {
            errors.add(error);
            return 'Could not read the key file.';
          },
        ),
        readKeyFile: (_) async => throw StateError('secret detail'),
      );

      await tester.tap(find.text('Save and connect'));
      await tester.pumpAndSettle();

      expect(errors.single, isA<StateError>());
      expect(find.text('Could not read the key file.'), findsOneWidget);
      expect(find.textContaining('secret detail'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(answers, isEmpty);
    });

    testWidgets('a read completing after cancel cannot pop the page below', (
      tester,
    ) async {
      final readGate = Completer<String>();
      await openRequest(
        tester,
        pathRequest(),
        readKeyFile: (_) => readGate.future,
      );

      await tester.tap(find.text('Save and connect'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(save(tester).onPressed, isNull);

      await tester.tap(find.text('Cancel'));
      readGate.complete('PEM');
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      expect(answers, [null]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the vault offer starts unchecked and rides the reply', (
      tester,
    ) async {
      await openRequest(
        tester,
        pathRequest(authMethod: AuthMethod.password, offerVaultSave: true),
        readKeyFile: (_) async => 'PEM',
      );
      final offer = find.widgetWithText(CheckboxListTile, 'Save in vault');
      expect(tester.widget<CheckboxListTile>(offer).value, isFalse);

      await tester.tap(offer);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('credential.password')),
        'pw',
      );
      await tester.tap(find.text('Save and connect'));
      await tester.pumpAndSettle();

      expect(answers.single!.saveToVault, isTrue);
    });

    testWidgets('an unavailable vault explains itself without an offer', (
      tester,
    ) async {
      await openRequest(
        tester,
        pathRequest(
          authMethod: AuthMethod.password,
          offerVaultSave: true,
          vaultUnavailable: true,
        ),
        readKeyFile: (_) async => 'PEM',
      );

      expect(
        find.text(
          'Saved secrets are unavailable. You can still enter the secret '
          'below.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      // The banner never blocks manual entry.
      expect(find.byKey(const ValueKey('credential.password')), findsOne);
    });
  });
  group('the passphrase-only form', () {
    const keyPath = '~/.ssh/id_work';

    GhostCredentialRequest passphraseRequest({
      AuthMethod authMethod = AuthMethod.privateKey,
      String? initialKeyPath = keyPath,
      bool offerVaultSave = false,
      bool vaultUnavailable = false,
    }) => GhostCredentialRequest(
      authMethod: authMethod,
      endpointLabel: 'box',
      keyField: GhostKeyField.passphraseOnly,
      username: 'deploy',
      host: 'example.com',
      port: 2222,
      initialKeyPath: initialKeyPath,
      offerVaultSave: offerVaultSave,
      vaultUnavailable: vaultUnavailable,
    );

    TextField field(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(ValueKey(key)));

    testWidgets('shows the known key and asks only for its passphrase', (
      tester,
    ) async {
      await openRequest(tester, passphraseRequest());
      expect(find.text('Key passphrase for box'), findsOneWidget);
      expect(find.text('deploy@example.com:2222'), findsOneWidget);
      expect(find.text('Key file'), findsOneWidget);

      final path = tester.widget<SelectableText>(
        find.descendant(
          of: find.byKey(const ValueKey('credential.keyPath')),
          matching: find.byType(SelectableText),
        ),
      );
      expect(path.data, keyPath);
      expect(path.style!.fontFamily, 'Host Mono');
      expect(path.style!.fontSize, 12);
      // The path is shown, not edited: no field holds it.
      expect(find.byKey(const ValueKey('credential.keyFile')), findsNothing);
      expect(find.byKey(const ValueKey('credential.key')), findsNothing);
      expect(find.byKey(const ValueKey('credential.chooseFile')), findsNothing);
      expect(find.byKey(const ValueKey('credential.password')), findsNothing);

      final passphrase = field(tester, 'credential.passphrase');
      expect(passphrase.decoration!.labelText, 'Passphrase');
      expect(passphrase.obscureText, isTrue);
      expect(passphrase.autofocus, isTrue);
      expect(passphrase.autocorrect, isFalse);
      expect(passphrase.enableSuggestions, isFalse);
      expect(passphrase.enableIMEPersonalizedLearning, isFalse);
      // No reveal toggle, as in the other two forms.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(IconButton),
        ),
        findsNothing,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('the passphrase alone is the answer, on Enter or the button', (
      tester,
    ) async {
      for (final viaEnter in [true, false]) {
        answers.clear();
        await openRequest(tester, passphraseRequest());
        await tester.enterText(
          find.byKey(const ValueKey('credential.passphrase')),
          'pp',
        );
        await tester.pump();
        if (viaEnter) {
          await tester.testTextInput.receiveAction(TextInputAction.done);
        } else {
          await tester.tap(find.text('Save and connect'));
        }
        await tester.pumpAndSettle();

        final reply = answers.single;
        expect(reply, isA<GhostKeyPassphraseReply>(), reason: '$viaEnter');
        expect((reply! as GhostKeyPassphraseReply).keyPassphrase, 'pp');
        expect(reply.saveToVault, isFalse);
      }
    });

    testWidgets('an empty passphrase cannot answer', (tester) async {
      await openRequest(tester, passphraseRequest());
      expect(save(tester).onPressed, isNull);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(answers, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('credential.passphrase')),
        'p',
      );
      await tester.pump();
      expect(save(tester).onPressed, isNotNull);

      await tester.enterText(
        find.byKey(const ValueKey('credential.passphrase')),
        '',
      );
      await tester.pump();
      expect(save(tester).onPressed, isNull);
    });

    testWidgets('a password prompt in this mode asks for the password', (
      tester,
    ) async {
      await openRequest(
        tester,
        passphraseRequest(
          authMethod: AuthMethod.password,
          initialKeyPath: null,
        ),
      );
      expect(find.text('Password for box'), findsOneWidget);
      expect(find.byKey(const ValueKey('credential.keyPath')), findsNothing);
      expect(find.byKey(const ValueKey('credential.passphrase')), findsNothing);
      expect(save(tester).onPressed, isNull);

      final password = field(tester, 'credential.password');
      expect(password.obscureText, isTrue);
      expect(password.enableSuggestions, isFalse);
      expect(password.enableIMEPersonalizedLearning, isFalse);

      await tester.enterText(
        find.byKey(const ValueKey('credential.password')),
        'pw',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect((answers.single! as GhostPasswordReply).password, 'pw');
    });

    testWidgets('takes no injector and needs the key path', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (built) {
              context = built;
              return const SizedBox();
            },
          ),
        ),
      );

      Matcher rejects(String name) =>
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', name));

      // An injector is rejected, not ignored: the form never takes key text.
      expect(
        () => showGhostCredentialDialog(
          context,
          passphraseRequest(),
          pickKeyText: () async => 'PEM',
          monoStyle: _mono,
        ),
        rejects('pickKeyText'),
      );
      expect(
        () => showGhostCredentialDialog(
          context,
          passphraseRequest(authMethod: AuthMethod.password),
          readKeyFile: (_) async => 'PEM',
          monoStyle: _mono,
        ),
        rejects('readKeyFile'),
      );
      for (final missing in [null, '']) {
        expect(
          () => showGhostCredentialDialog(
            context,
            passphraseRequest(initialKeyPath: missing),
            monoStyle: _mono,
          ),
          rejects('initialKeyPath'),
          reason: '$missing',
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('cancelling answers nothing', (tester) async {
      await openRequest(tester, passphraseRequest());
      await tester.enterText(
        find.byKey(const ValueKey('credential.passphrase')),
        'pp',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(answers, [null]);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('the verbs act only while the dialog is the top route', (
      tester,
    ) async {
      final dialogKey = GlobalKey();
      await openRequest(tester, passphraseRequest(), dialogKey: dialogKey);
      await tester.enterText(
        find.byKey(const ValueKey('credential.passphrase')),
        'pp',
      );
      await tester.pump();
      final answer = save(tester).onPressed!;
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed!;

      unawaited(
        Navigator.of(
          dialogKey.currentContext!,
        ).push(MaterialPageRoute<void>(builder: (_) => const Text('on top'))),
      );
      await tester.pumpAndSettle();

      answer();
      cancel();
      await tester.pumpAndSettle();
      expect(find.text('on top'), findsOneWidget);
      expect(answers, isEmpty);
    });

    testWidgets('the vault offer rides the reply', (tester) async {
      await openRequest(tester, passphraseRequest(offerVaultSave: true));
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Save in vault'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('credential.passphrase')),
        'pp',
      );
      await tester.pump();
      await tester.tap(find.text('Save and connect'));
      await tester.pumpAndSettle();

      final reply = answers.single! as GhostKeyPassphraseReply;
      expect(reply.keyPassphrase, 'pp');
      expect(reply.saveToVault, isTrue);
    });

    testWidgets('an unavailable vault explains itself without an offer', (
      tester,
    ) async {
      await openRequest(
        tester,
        passphraseRequest(offerVaultSave: true, vaultUnavailable: true),
      );
      expect(
        find.text(
          'Saved secrets are unavailable. You can still enter the secret '
          'below.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byKey(const ValueKey('credential.passphrase')), findsOne);
    });

    testWidgets("a host's words label the form", (tester) async {
      await openRequest(
        tester,
        passphraseRequest(),
        strings: GhostCredentialStrings(
          keyPassphraseTitle: (label) => 'Unlock the key for $label',
          keyFileField: 'Identity file',
          keyPassphraseField: 'Key passphrase',
          connect: 'Connect',
        ),
      );
      expect(find.text('Unlock the key for box'), findsOneWidget);
      expect(find.text('Identity file'), findsOneWidget);
      expect(find.text('Key passphrase'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });
  });
}
