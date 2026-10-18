import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/workspace_catalog.dart';
import 'package:planchette_app/ui/workspace_servers_dialog.dart';
import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    _Catalog catalog, {
    void Function(ServerConfig?)? selected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await showWorkspaceServersDialog(
                  context,
                  catalog,
                );
                selected?.call(result);
              },
              child: const Text('Choose server'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose server'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets(
    'search matches label, host and user; selecting returns the server',
    (tester) async {
      final catalog = _Catalog(enrolled: true);
      addTearDown(catalog.dispose);
      ServerConfig? result;
      await open(tester, catalog, selected: (server) => result = server);
      expect(catalog.loads, 1);
      expect(find.text('Production'), findsOneWidget);
      expect(find.text('alice@alpha.example:22'), findsOneWidget);

      for (final query in ['PRODUCTION', 'alpha.example', 'alice']) {
        await tester.enterText(field('Search servers'), query);
        await tester.pump();
        expect(find.text('Production'), findsOneWidget);
        expect(find.text('Backup'), findsNothing);
      }
      await tester.enterText(field('Search servers'), 'missing');
      await tester.pump();
      expect(find.text('No matching servers.'), findsOneWidget);
      await tester.enterText(field('Search servers'), 'alpha');
      await tester.pump();
      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(result?.id, 'alpha');
    },
  );

  testWidgets('first sign-in defaults credentials off and forwards the form', (
    tester,
  ) async {
    final catalog = _Catalog();
    addTearDown(catalog.dispose);
    await open(tester, catalog);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(
      tester.widget<TextField>(field('Account password')).obscureText,
      isTrue,
    );
    expect(
      tester.widget<TextField>(field('Encryption passphrase')).obscureText,
      isTrue,
    );
    await tester.enterText(field('Server URL'), 'https://suite.example');
    await tester.enterText(field('Username'), 'owner');
    await tester.enterText(field('Account password'), 'authentication');
    await tester.enterText(field('Encryption passphrase'), 'encryption');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(catalog.enrollment, (
      'https://suite.example',
      'owner',
      'authentication',
      'encryption',
      WorkspaceCredentialSync.disabled,
    ));
    expect(find.text('Search servers'), findsOneWidget);
  });

  testWidgets(
    'same-account re-signin retains identity and allows credential opt-in',
    (tester) async {
      final catalog = _Catalog(enrolled: true);
      addTearDown(catalog.dispose);
      await open(tester, catalog);
      await tester.tap(find.widgetWithText(TextButton, 'Sign In'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field('Server URL')).readOnly, isTrue);
      expect(tester.widget<TextField>(field('Username')).readOnly, isTrue);
      expect(
        tester.widget<TextField>(field('Server URL')).controller?.text,
        'https://suite.example',
      );
      await tester.enterText(field('Account password'), 'authentication');
      await tester.enterText(field('Encryption passphrase'), 'encryption');
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pumpAndSettle();
      expect(catalog.enrollment?.$1, 'https://suite.example');
      expect(catalog.enrollment?.$2, 'owner');
      expect(catalog.enrollment?.$5, WorkspaceCredentialSync.enabled);
    },
  );

  testWidgets(
    'refresh errors and trust notices remain visible beside cached servers',
    (tester) async {
      final catalog = _Catalog(enrolled: true)
        ..noticeList = ['Local keys remain trusted.']
        ..refreshError = 'Unlock the keystore.';
      addTearDown(catalog.dispose);
      await open(tester, catalog);
      await tester.tap(find.byTooltip('Refresh catalog'));
      await tester.pumpAndSettle();
      expect(catalog.refreshes, 1);
      expect(find.text('Unlock the keystore.'), findsOneWidget);
      expect(find.text('Local keys remain trusted.'), findsOneWidget);
      expect(find.text('Production'), findsOneWidget);
    },
  );

  testWidgets('failed enrollment stays open and busy disables submission', (
    tester,
  ) async {
    final catalog = _Catalog()
      ..signInError = 'Check your encryption passphrase.';
    addTearDown(catalog.dispose);
    await open(tester, catalog);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(find.text('Check your encryption passphrase.'), findsOneWidget);
    expect(find.text('Encryption passphrase'), findsOneWidget);
    catalog.setBusy();
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign In'))
          .onPressed,
      isNull,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}

final class _Catalog extends WorkspaceCatalog {
  _Catalog({bool enrolled = false})
    : super(directory: Directory('unused-catalog-fixture')) {
    if (enrolled) _account = _fixtureAccount;
  }

  static const _fixtureAccount = SyncAccount(
    baseUrl: 'https://suite.example',
    username: 'owner',
    mode: SyncAccountMode.shared,
  );
  SyncAccount? _account;
  WorkspaceCredentialSync _consent = WorkspaceCredentialSync.disabled;
  String? _error;
  bool _busy = false;
  int loads = 0;
  int refreshes = 0;
  String? refreshError;
  String? signInError;
  List<String> noticeList = [];
  (String, String, String, String, WorkspaceCredentialSync)? enrollment;

  @override
  SyncAccount? get account => _account;
  @override
  WorkspaceCredentialSync get credentialSync => _consent;
  @override
  List<ServerConfig> get servers => account == null
      ? const []
      : [
          ServerConfig(
            id: 'alpha',
            label: 'Production',
            host: 'alpha.example',
            port: 22,
            username: 'alice',
            authMethod: AuthMethod.agent,
            createdAt: 1,
            updatedAt: 1,
          ),
          ServerConfig(
            id: 'beta',
            label: 'Backup',
            host: 'backup.example',
            port: 2222,
            username: 'bob',
            authMethod: AuthMethod.agent,
            createdAt: 1,
            updatedAt: 1,
          ),
        ];
  @override
  List<String> get notices => noticeList;
  @override
  String? get error => _error;
  @override
  bool get busy => _busy;

  void setBusy() {
    _busy = true;
    notifyListeners();
  }

  @override
  Future<void> load() async => loads++;

  @override
  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required WorkspaceCredentialSync credentialSync,
  }) async {
    enrollment = (
      baseUrl,
      username,
      password,
      encryptionPassphrase,
      credentialSync,
    );
    _error = signInError;
    if (_error != null) {
      notifyListeners();
      throw StateError(_error!);
    }
    _account = _fixtureAccount;
    _consent = credentialSync;
    notifyListeners();
  }

  @override
  Future<void> sync() async {
    refreshes++;
    _error = refreshError;
    notifyListeners();
    if (_error != null) throw StateError(_error!);
  }
}
