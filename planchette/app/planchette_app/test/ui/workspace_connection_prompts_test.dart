import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/ui/workspace_connection_prompts.dart';
import 'package:planchette_app/ui/workspace_remote_folder_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:planchette_app/services/document_workspace.dart';

import '../services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs;

class _Scope implements CredentialResolutionScope {
  final done = Completer<void>();
  @override
  Future<void> get dismissed => done.future;
}

void main() {
  late DocumentWorkspace workspace;
  var disposed = false;
  setUp(() {
    disposed = false;
    workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
  });
  tearDown(() {
    if (!disposed) workspace.dispose();
  });
  const server = ServerConfig(
    id: 'server',
    label: 'Production',
    host: 'host',
    username: 'user',
    authMethod: AuthMethod.password,
    createdAt: 0,
    updatedAt: 0,
  );

  testWidgets(
    'missing-password prompt opens and returns a connection-only draft',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const Scaffold()),
      );
      final prompts = AppWorkspaceConnectionPrompts(
        () => (context: key.currentContext!, workspace: workspace),
        pickKeyText: (_) async => null,
      );
      final answer = prompts
          .credentials(server, _Scope())
          .then<Object?>((value) => value, onError: (Object error) => error);
      await tester.pumpAndSettle();
      expect(find.text('Password for Production'), findsOneWidget);
      expect(workspace.interactionLocked, isTrue);
      expect(await workspace.confirmQuit(), isFalse);
      await tester.enterText(find.byType(TextField), 'password');
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(
        await answer,
        isA<CredentialDraft>().having(
          (draft) => draft.password,
          'password',
          'password',
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('private-key prompt can use the window-owned key picker', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    final prompts = AppWorkspaceConnectionPrompts(
      () => (context: key.currentContext!, workspace: workspace),
      pickKeyText: (_) async => 'picked key text',
    );
    final answer = prompts.credentials(
      server.copyWith(authMethod: AuthMethod.privateKey),
      _Scope(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose key file…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect((await answer)!.privateKeyPem, 'picked key text');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('referenced-key prompt returns only a passphrase', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    final prompts = AppWorkspaceConnectionPrompts(
      () => (context: key.currentContext!, workspace: workspace),
      pickKeyText: (_) async => throw StateError('Unexpected picker'),
    );
    final answer = prompts.credentials(
      server.copyWith(
        authMethod: AuthMethod.privateKey,
        identityFilePath: '/keys/id',
      ),
      _Scope(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'passphrase');
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    final draft = (await answer)!;
    expect(draft.keyPassphrase, 'passphrase');
    expect(draft.privateKeyPem, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancellation before the first frame withdraws its prompt', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    final prompts = AppWorkspaceConnectionPrompts(
      () => (context: key.currentContext!, workspace: workspace),
      pickKeyText: (_) async => null,
    );
    final scope = _Scope();
    CredentialDraft? result;
    var completed = false;
    prompts.credentials(server, scope).then((answer) {
      result = answer;
      completed = true;
    });
    scope.done.complete();
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
    expect(find.text('Password for Production'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'remote workspace root is chosen and validated before connecting',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const Scaffold()),
      );
      final root = showRemoteWorkspaceRoot(key.currentContext!, server);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '~',
      );
      await tester.enterText(find.byType(TextField), '~another-user');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a folder using /path, ~ or ~/path.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '/etc');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(await root, '/etc');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('removing the prompt host settles credential resolution', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    final prompts = AppWorkspaceConnectionPrompts(
      () => (context: key.currentContext!, workspace: workspace),
      pickKeyText: (_) async => null,
    );
    var completed = false;
    CredentialDraft? result;
    prompts.credentials(server, _Scope()).then((answer) {
      completed = true;
      result = answer;
    });
    await tester.pumpAndSettle();
    expect(find.text('Password for Production'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      workspace.dispose();
      disposed = true;
      await workspace.whenDisposed;
    });
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('a prompt displayed in another window locks both owners', (
    tester,
  ) async {
    final initiating = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
    addTearDown(initiating.dispose);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    final prompts = AppWorkspaceConnectionPrompts(
      () => (context: key.currentContext!, workspace: workspace),
      pickKeyText: (_) async => null,
    );
    final scope = _Scope();
    final answer = initiating.chooseWorkspace(
      () => prompts.credentials(server, scope),
    );
    await tester.pumpAndSettle();
    expect(initiating.interactionLocked, isTrue);
    expect(workspace.interactionLocked, isTrue);
    expect(await workspace.confirmQuit(), isFalse);
    scope.done.complete();
    await tester.pumpAndSettle();
    expect(await answer, isNull);
    expect(initiating.interactionLocked, isFalse);
    expect(workspace.interactionLocked, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
