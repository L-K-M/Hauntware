import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_app/ui/server_editor.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

final class _HeldReadVaultStore implements VaultStore {
  final InMemoryVaultStore _delegate = InMemoryVaultStore();
  Completer<void>? readGate;
  Object? deleteError;
  int deleteCalls = 0;

  @override
  Future<Uint8List?> getSecretBlob(String id) async {
    await readGate?.future;
    return _delegate.getSecretBlob(id);
  }

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) =>
      _delegate.putSecretBlob(id, blob);

  @override
  Future<void> putSecretBlobs(Map<String, Uint8List> blobs) =>
      _delegate.putSecretBlobs(blobs);

  @override
  Future<void> deleteSecret(String id) async {
    deleteCalls++;
    if (deleteError case final error?) throw error;
    await _delegate.deleteSecret(id);
  }

  @override
  Future<Map<String, Uint8List>> allSecretBlobs() =>
      _delegate.allSecretBlobs();
}

/// The server editor as a dialog: what Return does from where, and how the
/// colour row's custom choice reaches the saved record.
///
/// Stood up over a real [AppServices] like the list-pane tests, because a
/// save writes through the config store, and the point of these is what lands
/// there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    state = null;
    services = null;
    directory = null;
  });

  /// A real [AppServices] over a temp directory. `AppServices.initialize()`
  /// touches the disk, which a widget test's fake-async zone never completes
  /// — hence [WidgetTester.runAsync].
  Future<void> boot(WidgetTester tester) => tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('seance-editor-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _pathChannel,
          (call) async => directory!.path,
        );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    // The editor tests exercise credential intent, not the JSON vault's I/O
    // queue. Its chained file futures originate in the widget fake-async zone
    // when an editor loads an existing secret, which can leave later writes
    // waiting on a completion that only another pump can deliver. The same
    // encrypted SecretVault over an in-memory blob store keeps the production
    // crypto and versioning while removing that test-harness lock inversion.
    services!.vault = SecretVault(
      InMemoryVaultStore(),
      services!.vaultKey!,
    );
    state = AppState(services!);
  });

  Future<void> openEditor(WidgetTester tester, {ServerConfig? existing}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showServerEditor(context, state!, existing),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (existing?.secretRef != null) {
      // Vault reads use real file/keychain I/O, which does not advance in the
      // widget binding's fake-async zone. Give the editor's initial read one
      // real event-loop turn, as boot() does for service initialization.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }
    expect(
      find.text(existing == null ? 'Add server' : 'Edit server'),
      findsOneWidget,
    );
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  /// The dialog's own scrollable, as opposed to one of its text fields'.
  Future<void> scrollTo(WidgetTester tester, Finder target) =>
      tester.scrollUntilVisible(
        target,
        100,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  /// Type the three required fields, leaving the focus in the last of them.
  Future<void> fillRequired(WidgetTester tester) async {
    await tester.enterText(field('Label'), 'box');
    await tester.enterText(field('Host'), 'box.example.com');
    await tester.enterText(field('Username'), 'deploy');
    await tester.pump();
  }

  /// Poll [done] on the real event loop until it holds or five seconds pass.
  /// Only meaningful inside `runAsync`.
  Future<void> waitUntil(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Named as what it is: a save that never landed reads differently from
    // one that wrote the wrong thing, and the downstream expect only says
    // the second.
    expect(done(), isTrue, reason: 'timed out after 5 s waiting for a save');
  }

  /// Press [key] with the editor open, and give a save it triggers time to
  /// finish. The save writes through the config store on the real event
  /// loop, so the key press that starts it has to happen inside `runAsync`
  /// too (see AGENTS.md §5). With [expectSave] false the wait is a short
  /// fixed one: long enough for a save that should not happen to show up,
  /// without spending the whole deadline proving a negative.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool expectSave = true,
  }) async {
    await tester.runAsync(() async {
      await tester.sendKeyEvent(key);
      if (expectSave) {
        await waitUntil(() => state!.servers.isNotEmpty);
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });
    await tester.pumpAndSettle();
  }

  group('Authentication', () {
    testWidgets('a new server defaults to ssh-agent auth', (tester) async {
      await boot(tester);
      await openEditor(tester);

      expect(
        find.text('Keys are provided by your ssh-agent; nothing is stored.'),
        findsOneWidget,
      );
      expect(find.textContaining('isn\'t supported yet'), findsNothing);
    });

    testWidgets('editing preserves the saved jump host and start directory',
        (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'target',
        label: 'target',
        host: 'target.internal',
        username: 'deploy',
        jumpHostId: 'jump',
        startDirectory: '/srv/www',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(() => state!.saveServer(existing));
      await openEditor(tester, existing: existing);
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(() => state!.servers.single.updatedAt > 1);
      });
      await tester.pumpAndSettle();

      expect(state!.servers.single.jumpHostId, 'jump');
      // Poltergeist's field, which this editor does not show.
      expect(state!.servers.single.startDirectory, '/srv/www');
    });

    testWidgets('a stored credential exposes explicit keep replace and clear '
        'states', (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'secret-box',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'secret-box',
            kind: SecretKind.password,
            value: 'hunter2',
          ),
        ),
      );

      await openEditor(tester, existing: existing);

      expect(find.text('Saved credential: password'), findsOneWidget);
      expect(find.byKey(const ValueKey('credential-edit-action')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('credential-edit-action')));
      await tester.pumpAndSettle();
      expect(find.text('Keep saved credential'), findsWidgets);
      expect(find.text('Replace saved credential'), findsOneWidget);
      expect(find.text('Clear saved credential'), findsOneWidget);
    });

    testWidgets('a delayed vault read does not override explicit edit intent',
        (tester) async {
      await boot(tester);
      final heldStore = _HeldReadVaultStore();
      services!.vault = SecretVault(heldStore, services!.vaultKey!);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        secretRef: 'secret-box',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'secret-box',
            kind: SecretKind.privateKey,
            value: 'PEM',
            keyPassphrase: 'saved phrase',
          ),
        ),
      );
      heldStore.readGate = Completer<void>();
      await openEditor(tester, existing: existing);

      await tester.tap(find.byKey(const ValueKey('credential-edit-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace saved credential').last);
      await tester.pumpAndSettle();
      expect(find.text('Use no saved passphrase'), findsOneWidget);

      heldStore.readGate!.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      final credentialField = tester.widget<
          DropdownButtonFormField<CredentialEditAction>>(
        find.descendant(
          of: find.byKey(const ValueKey('credential-edit-action')),
          matching:
              find.byType(DropdownButtonFormField<CredentialEditAction>),
        ),
      );
      final passphraseField = tester.widget<
          DropdownButtonFormField<KeyPassphraseAction>>(
        find.descendant(
          of: find.byKey(const ValueKey('key-passphrase-action')),
          matching:
              find.byType(DropdownButtonFormField<KeyPassphraseAction>),
        ),
      );
      expect(credentialField.initialValue, CredentialEditAction.replace);
      expect(passphraseField.initialValue, KeyPassphraseAction.clear);
    });

    testWidgets('changing a referenced key source visibly switches to replace',
        (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        secretRef: 'secret-box',
        identityFilePath: '/keys/old',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'secret-box',
            kind: SecretKind.privateKey,
            value: '',
            identityFilePath: '/keys/old',
            identityFilePassphrase: 'saved phrase',
          ),
        ),
      );
      await openEditor(tester, existing: existing);

      await tester.enterText(field('Identity file path'), '/keys/new');
      await tester.pumpAndSettle();

      final credentialField = tester.widget<
          DropdownButtonFormField<CredentialEditAction>>(
        find.descendant(
          of: find.byKey(const ValueKey('credential-edit-action')),
          matching:
              find.byType(DropdownButtonFormField<CredentialEditAction>),
        ),
      );
      expect(credentialField.initialValue, CredentialEditAction.replace);
      expect(find.byKey(const ValueKey('key-passphrase-action')), findsOneWidget);
    });

    testWidgets('a method switch cannot keep a credential of the wrong kind',
        (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'secret-box',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'secret-box',
            kind: SecretKind.password,
            value: 'hunter2',
          ),
        ),
      );
      await openEditor(tester, existing: existing);

      final auth = find.byType(DropdownButtonFormField<AuthMethod>);
      await tester.tap(auth);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private key').last);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.text('A saved password cannot be kept for private-key auth.'),
        findsOneWidget,
      );
      expect(state!.servers.single.authMethod, AuthMethod.password);
    });

    testWidgets('clear removes the reference and its unshared vault entry',
        (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'secret-box',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'secret-box',
            kind: SecretKind.password,
            value: 'hunter2',
          ),
        ),
      );
      await openEditor(tester, existing: existing);

      await tester.tap(find.byKey(const ValueKey('credential-edit-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear saved credential').last);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(() => state!.servers.single.secretRef == null);
      });
      await tester.pumpAndSettle();

      expect(state!.servers.single.secretRef, isNull);
      expect(
        await tester.runAsync(
          () => services!.vault.getSecret('secret-box'),
        ),
        isNull,
      );
    });

    testWidgets('replace is copy-on-write and removes the old unshared entry',
        (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'secret-box',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'secret-box',
            kind: SecretKind.password,
            value: 'old password',
          ),
        ),
      );
      await openEditor(tester, existing: existing);

      await tester.tap(find.byKey(const ValueKey('credential-edit-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace saved credential').last);
      await tester.pumpAndSettle();
      await tester.enterText(field('Password'), 'new password');
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(
          () => state!.servers.single.secretRef != 'secret-box',
        );
      });
      await tester.pumpAndSettle();

      final newRef = state!.servers.single.secretRef!;
      expect(newRef, isNot('secret-box'));
      expect(await services!.vault.getSecret('secret-box'), isNull);
      expect((await services!.vault.getSecret(newRef))!.value, 'new password');
      final withdrawals = await tester.runAsync(
        () => services!.tombstoneStore.all(),
      );
      final withdrawal = withdrawals!.singleWhere(
        (record) => record.id == 'secret:secret-box',
      );
      expect(withdrawal.deleted, isTrue);
      expect(
        withdrawal.updatedAt,
        greaterThanOrEqualTo(state!.servers.single.updatedAt),
      );
    });

    testWidgets('failed cleanup is queued, closes the saved editor, and retries',
        (tester) async {
      await boot(tester);
      final store = _HeldReadVaultStore();
      services!.vault = SecretVault(store, services!.vaultKey!);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'secret-box',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'secret-box',
            kind: SecretKind.password,
            value: 'old password',
          ),
        ),
      );
      await openEditor(tester, existing: existing);
      store.deleteError = StateError('keyring locked');

      await tester.tap(find.byKey(const ValueKey('credential-edit-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear saved credential').last);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(() => state!.servers.single.secretRef == null);
      });
      await tester.pumpAndSettle();

      expect(find.text('Edit server'), findsNothing);
      expect(
        services!.settings.pendingCredentialCleanup,
        {'secret-box'},
      );
      expect(await services!.vault.getSecret('secret-box'), isNotNull);
      final withdrawals = await tester.runAsync(
        () => services!.tombstoneStore.all(),
      );
      final withdrawal = withdrawals!.singleWhere(
        (record) => record.id == 'secret:secret-box',
      );

      store.deleteError = null;
      await tester.runAsync(
        () => state!.saveServer(
          state!.servers.single.copyWith(updatedAt: 2),
        ),
      );
      expect(await services!.vault.getSecret('secret-box'), isNull);
      expect(services!.settings.pendingCredentialCleanup, isEmpty);
      final retriedWithdrawals = await tester.runAsync(
        () => services!.tombstoneStore.all(),
      );
      expect(
        retriedWithdrawals!.singleWhere(
          (record) => record.id == 'secret:secret-box',
        ).updatedAt,
        withdrawal.updatedAt,
        reason: 'a cleanup retry retains the original withdrawal stamp',
      );
    });

    testWidgets('save refuses a credential ref changed while the editor is open',
        (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'old-ref',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(
        () => state!.saveServer(
          existing,
          secret: const Secret(
            id: 'old-ref',
            kind: SecretKind.password,
            value: 'old',
          ),
        ),
      );
      await openEditor(tester, existing: existing);

      await tester.runAsync(
        () => state!.saveServer(
          existing.copyWith(secretRef: 'new-ref', updatedAt: 2),
          secret: const Secret(
            id: 'new-ref',
            kind: SecretKind.password,
            value: 'new',
          ),
        ),
      );
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('credential changed while it was open'),
        findsOneWidget,
      );
      expect(state!.servers.single.secretRef, 'new-ref');
    });

    testWidgets('save never clears the credential it still references',
        (tester) async {
      await boot(tester);
      final config = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'secret-box',
        createdAt: 1,
        updatedAt: 1,
      );

      await tester.runAsync(
        () => expectLater(
          state!.saveServer(config, clearSecretRef: 'secret-box'),
          throwsArgumentError,
        ),
      );
      expect(state!.servers, isEmpty);
    });

    testWidgets('the mutation queue enforces the observed credential ref',
        (tester) async {
      await boot(tester);
      final original = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'old-ref',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(() async {
        await state!.saveServer(original);
        await state!.saveServer(
          original.copyWith(secretRef: 'new-ref', updatedAt: 2),
        );
        await expectLater(
          state!.saveServer(
            original.copyWith(secretRef: 'replacement-ref', updatedAt: 3),
            credentialPrecondition: const ServerCredentialPrecondition(
              serverId: 'box',
              secretRef: 'old-ref',
              secret: null,
            ),
          ),
          throwsA(isA<ServerCredentialChanged>()),
        );
      });

      expect(state!.servers.single.secretRef, 'new-ref');
    });

    testWidgets('the mutation queue enforces the observed secret snapshot',
        (tester) async {
      await boot(tester);
      final original = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'old-ref',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(() async {
        await state!.saveServer(
          original,
          secret: const Secret(
            id: 'old-ref',
            kind: SecretKind.password,
            value: 'observed',
          ),
        );
        final observed = await services!.vault.getSecret('old-ref');
        await services!.vault.putLocalSecret(
          const Secret(
            id: 'old-ref',
            kind: SecretKind.password,
            value: 'newer',
          ),
          updatedAt: 2,
        );

        await expectLater(
          state!.saveServer(
            original.copyWith(secretRef: 'replacement-ref', updatedAt: 3),
            secret: const Secret(
              id: 'replacement-ref',
              kind: SecretKind.password,
              value: 'replacement',
            ),
            clearSecretRef: 'old-ref',
            credentialPrecondition: ServerCredentialPrecondition(
              serverId: 'box',
              secretRef: 'old-ref',
              secret: observed,
            ),
          ),
          throwsA(isA<ServerCredentialChanged>()),
        );
      });

      expect((await services!.vault.getSecret('old-ref'))!.value, 'newer');
      expect(await services!.vault.getSecret('replacement-ref'), isNull);
      expect(state!.servers.single.secretRef, 'old-ref');
    });
  });

  group('Return', () {
    testWidgets('in a one-line field saves the server', (tester) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);

      await press(tester, LogicalKeyboardKey.enter);

      expect(state!.servers.map((s) => s.label), ['box']);
      expect(
        find.text('Add server'),
        findsNothing,
        reason: 'the dialog closed',
      );
    });

    testWidgets('in the login script is a newline, not a save', (tester) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty);
      expect(find.text('Add server'), findsOneWidget);
    });

    testWidgets('with a modifier saves from the login script too', (
      tester,
    ) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');

      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await waitUntil(() => state!.servers.isNotEmpty);
      });
      await tester.pumpAndSettle();

      expect(state!.servers.map((s) => s.loginScript), ['cd ~/work']);
      expect(find.text('Add server'), findsNothing);
    });

    testWidgets('on a focused button presses that button', (tester) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      // The button's own focus node, through the text it wraps: the nearest
      // Focus above the label is the button's.
      await scrollTo(tester, find.text('Cancel'));
      Focus.of(tester.element(find.text('Cancel'))).requestFocus();
      await tester.pump();

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty, reason: 'Cancel, not Save');
      expect(find.text('Add server'), findsNothing, reason: 'Cancel closed it');
    });

    testWidgets('on a focused colour swatch picks the colour', (tester) async {
      // A swatch is an InkWell, which activates on Return through its own
      // action; the save shortcut yields to that, so keyboard users can pick
      // a colour without the dialog closing under them.
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, find.byTooltip('Teal'));
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byTooltip('Teal'),
            matching: find.byType(Container),
          ),
        ),
      ).requestFocus();
      await tester.pump();

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty);
      expect(find.text('Add server'), findsOneWidget);
      final previews = tester.widgetList<ServerAccentBar>(
        find.byType(ServerAccentBar),
      );
      expect(previews, isNotEmpty);
      expect(previews.map((bar) => bar.tint).toSet(), {
        const ServerTint(named: ServerColor.teal),
      });
    });

    testWidgets('does nothing while the form does not validate', (
      tester,
    ) async {
      await boot(tester);
      await openEditor(tester);
      await tester.enterText(field('Label'), 'box');

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty);
      expect(find.text('Required'), findsWidgets);
    });
  });

  group('custom colour', () {
    testWidgets('is stored with the nearest named accent beside it', (
      tester,
    ) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, find.byTooltip('Custom colour…'));
      await tester.tap(find.byTooltip('Custom colour…'));
      await tester.pumpAndSettle();
      expect(find.text('Custom colour'), findsOneWidget);
      // Deliberately no frame between typing and pressing: the press has to
      // take what was typed, not what was drawn.
      await tester.enterText(find.widgetWithText(TextField, 'Hex'), '1e90ff');
      await tester.tap(find.text('Use colour'));
      await tester.pumpAndSettle();
      // The swatch now shows the choice, and says what it is.
      expect(find.byTooltip('Custom colour (#1E90FF)'), findsOneWidget);

      // Into view first: the row is scrolled to the colour swatches, and a
      // tap on a button below the fold lands on nothing.
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(() => state!.servers.isNotEmpty);
      });
      await tester.pumpAndSettle();

      final saved = state!.servers.single;
      expect(saved.customColor, '#1E90FF');
      // What a build without the field draws: the closest of the ten by hue.
      expect(saved.color, ServerColor.blue);

      // And reopening finds the choice in force rather than the stand-in.
      await openEditor(tester, existing: saved);
      await scrollTo(tester, find.byTooltip('Custom colour (#1E90FF)'));
      expect(find.byTooltip('Custom colour (#1E90FF)'), findsOneWidget);
    });

    testWidgets('a named swatch replaces it', (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        color: ServerColor.blue,
        customColor: '#1E90FF',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(() => state!.saveServer(existing));
      await openEditor(tester, existing: existing);
      await scrollTo(tester, find.byTooltip('Teal'));
      await tester.tap(find.byTooltip('Teal'));
      await tester.pump();
      expect(find.byTooltip('Custom colour…'), findsOneWidget);

      // Into view first: the row is scrolled to the colour swatches, and a
      // tap on a button below the fold lands on nothing.
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(() => state!.servers.single.customColor == null);
      });
      await tester.pumpAndSettle();

      final saved = state!.servers.single;
      expect(saved.color, ServerColor.teal);
      expect(saved.customColor, isNull);
    });
  });

  group('Recovery offer', () {
    /// Picks [method] in the authentication dropdown.
    Future<void> chooseAuth(WidgetTester tester, String method) async {
      final dropdown = find.byType(DropdownButtonFormField<AuthMethod>);
      await scrollTo(tester, dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(method).last);
      await tester.pumpAndSettle();
    }

    /// Saves through Return, then gives the offer, which reads the vault
    /// once the editor has closed, real time to appear (bounded).
    Future<void> saveAndSettle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await waitUntil(() => state!.servers.isNotEmpty);
      });
      for (var i = 0; i < 100; i++) {
        await tester.pumpAndSettle();
        if (find.text('Set up a recovery code?').evaluate().isNotEmpty) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
    }

    testWidgets('saving a password offers a recovery code', (tester) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      await chooseAuth(tester, 'Password');
      await tester.enterText(field('Password'), 'hunter2');
      await tester.tap(field('Label'));
      await tester.pump();

      await saveAndSettle(tester);

      expect(find.text('Add server'), findsNothing);
      expect(find.text('Set up a recovery code?'), findsOneWidget);
    });

    testWidgets('a save that wrote no credential offers nothing', (
      tester,
    ) async {
      await boot(tester);
      await openEditor(tester);
      // A new server's default is the SSH agent: nothing to recover.
      await fillRequired(tester);

      await saveAndSettle(tester);

      expect(find.text('Add server'), findsNothing);
      expect(find.text('Set up a recovery code?'), findsNothing);
    });
  });
}
