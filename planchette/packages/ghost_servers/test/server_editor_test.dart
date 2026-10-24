import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_protocol/seance_protocol.dart' show AuthMethod;

const _mono = TextStyle(fontFamily: 'Host Mono');

GhostServerDraft _draft(
  String id, {
  bool excludeFromSync = false,
  String? startDirectory,
}) => GhostServerDraft(
  id: id,
  label: 'web',
  host: '$id.example.com',
  port: 22,
  username: 'deploy',
  authMethod: GhostAuthMethod.agent,
  syncSecret: true,
  excludeFromSync: excludeFromSync,
  startDirectory: startDirectory,
);

/// No host behind it: records what the editor hands over, and answers a
/// connection test with [testReply] when set, a passing report otherwise.
final class _FakeDelegate extends GhostServerEditorDelegate {
  final List<GhostServerSave> saves = [];
  Object? saveFailure;
  bool configured = false;
  bool canPick = true;
  bool canTest = true;
  bool canImport = false;
  Future<String?> Function()? importReply;
  int testCalls = 0;
  Future<GhostTestReport> Function()? testReply;
  int _ids = 0;

  @override
  List<String> get serverGroups => const [];

  @override
  bool get syncConfigured => configured;

  @override
  Color get themeSeed => const Color(0xFF335577);

  @override
  String newId() => 'id-${_ids++}';

  @override
  bool get canPickIdentityFile => canPick;

  @override
  bool get canTestConnection => canTest;

  @override
  Future<String?> pickIdentityFile() async => null;

  @override
  bool get canImportKeyFile => canImport;

  @override
  Future<String?> importKeyFile() => importReply?.call() ?? Future.value();

  @override
  Future<bool> save(GhostServerSave save) async {
    saves.add(save);
    if (saveFailure case final failure?) throw failure;
    return false;
  }

  @override
  Future<GhostTestReport> testConnection(
    GhostServerDraft draft,
    GhostCredentialDraft credential,
  ) {
    testCalls++;
    return testReply?.call() ??
        Future.value(
          const GhostTestReport(ok: true, summary: 'Connected.', log: ''),
        );
  }
}

/// A host section whose write fails, as Poltergeist's transfer limit can.
final class _FailingSection extends GhostServerEditorSection {
  @override
  Widget build(BuildContext context) => const Text('Host section');

  @override
  Future<void> Function(String serverId)? capture() =>
      (_) async => throw StateError('disk full');

  @override
  String failureMessage(Object error) => 'Section not saved';
}

/// The server editor's own behaviour over a neutral delegate (docs/design/
/// ghost-servers-part2.md, section 8, F5a-2b). Each app's adapter keeps its
/// own suite: Poltergeist's server_editor_test.dart drives the form through
/// its session and records.
void main() {
  late _FakeDelegate delegate;

  setUp(() => delegate = _FakeDelegate());

  Future<void> openEditor(
    WidgetTester tester, {
    GhostServerDraft? existing,
    Set<GhostServerOptionalField> fields = const {
      GhostServerOptionalField.startDirectory,
    },
    List<GhostServerEditorSection> sections = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showGhostServerEditor(
                context,
                delegate,
                existing,
                monoStyle: _mono,
                readMarkImage: () async => null,
                fields: fields,
                sections: sections,
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

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  final saveButton = find.widgetWithText(FilledButton, 'Save');
  bool editorOpen() =>
      find.text('Add server').evaluate().isNotEmpty ||
      find.text('Edit server').evaluate().isNotEmpty;

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

  Future<void> tapSave(WidgetTester tester) async {
    await scrollTo(tester, saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
  }

  /// Type the three required fields, leaving the focus in the last of them.
  Future<void> fillRequired(WidgetTester tester) async {
    await tester.enterText(field('Label'), 'box');
    await tester.enterText(field('Host'), 'box.example.com');
    await tester.enterText(field('Username'), 'deploy');
    await tester.pump();
  }

  /// Lets a toast's dismissal timer run out, so no timer outlives the test.
  Future<void> outlastToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('Return', () {
    testWidgets('in a one-line field saves the server', (tester) async {
      await openEditor(tester);
      await fillRequired(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(delegate.saves.single.draft.label, 'box');
      expect(editorOpen(), isFalse);
    });

    testWidgets('in the login script is a newline, not a save', (tester) async {
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(delegate.saves, isEmpty);
      expect(editorOpen(), isTrue);
    });

    testWidgets('the chord saves from the login script too', (tester) async {
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(delegate.saves.single.draft.loginScript, 'cd ~/work');
      expect(editorOpen(), isFalse);
    });

    testWidgets('an open input-method composition declines, chord or not', (
      tester,
    ) async {
      await openEditor(tester);
      await fillRequired(tester);
      // The Username field holds a preedit the input method has not
      // committed yet; Return belongs to the input method.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'deployかな',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 6, end: 8),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(delegate.saves, isEmpty);
      expect(editorOpen(), isTrue);
    });
  });

  group('exclusion confirmation', () {
    test('asks only for an existing, included server with sync on', () {
      expect(
        ghostExcludingNeedsConfirmation(
          existing: _draft('web'),
          syncConfigured: true,
        ),
        isTrue,
      );
      expect(
        ghostExcludingNeedsConfirmation(existing: null, syncConfigured: true),
        isFalse,
      );
      expect(
        ghostExcludingNeedsConfirmation(
          existing: _draft('web', excludeFromSync: true),
          syncConfigured: true,
        ),
        isFalse,
      );
      expect(
        ghostExcludingNeedsConfirmation(
          existing: _draft('web'),
          syncConfigured: false,
        ),
        isFalse,
      );
    });

    testWidgets('a new server excludes without asking', (tester) async {
      delegate.configured = true;
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, find.text('Exclude from sync'));
      await tester.tap(find.text('Exclude from sync'));
      await tester.pumpAndSettle();

      expect(find.text('Exclude from sync?'), findsNothing);
      await tapSave(tester);
      expect(delegate.saves.single.draft.excludeFromSync, isTrue);
    });

    testWidgets('an existing synced server asks, and dismissing reads as no', (
      tester,
    ) async {
      delegate.configured = true;
      await openEditor(tester, existing: _draft('web'));
      await scrollTo(tester, find.text('Exclude from sync'));
      await tester.tap(find.text('Exclude from sync'));
      await tester.pumpAndSettle();
      expect(find.text('Exclude from sync?'), findsOneWidget);

      // Escape answers nothing, which must not proceed.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Exclude from sync?'), findsNothing);
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Exclude from sync'),
            )
            .value,
        isFalse,
      );

      await tapSave(tester);
      expect(delegate.saves.single.draft.excludeFromSync, isFalse);
    });
  });

  group('connection test', () {
    Future<void> tapTest(WidgetTester tester) async {
      await scrollTo(tester, find.text('Test connection'));
      await tester.tap(find.text('Test connection'));
      await tester.pump();
    }

    testWidgets('typing in a connection field drops a running test and its '
        'late result', (tester) async {
      final reply = Completer<GhostTestReport>();
      delegate.testReply = () => reply.future;
      await openEditor(tester);
      await fillRequired(tester);
      await tapTest(tester);
      expect(find.text('Testing…'), findsOneWidget);

      await scrollTo(tester, field('Host'));
      await tester.enterText(field('Host'), 'other.example.com');
      await tester.pump();
      // The button is free again rather than waiting on a dropped attempt.
      expect(find.text('Testing…'), findsNothing);

      reply.complete(
        const GhostTestReport(ok: true, summary: 'Stale result.', log: ''),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Stale result.'), findsNothing);
    });

    testWidgets('renaming the server keeps a finished result', (tester) async {
      await openEditor(tester);
      await fillRequired(tester);
      await tapTest(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Connected.'), findsWidgets);

      await scrollTo(tester, field('Label'));
      await tester.enterText(field('Label'), 'renamed');
      await tester.pump();
      expect(find.textContaining('Connected.'), findsWidgets);
    });

    testWidgets('a test that throws reports the failure in the live region', (
      tester,
    ) async {
      delegate.testReply = () => Future.error(StateError('socket gone'));
      await openEditor(tester);
      await fillRequired(tester);
      await tapTest(tester);
      await tester.pumpAndSettle();

      final summary = find.textContaining('Could not test the connection.');
      expect(summary, findsOneWidget);
      final region = find.ancestor(
        of: summary,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      );
      expect(region, findsOneWidget);
      expect(find.textContaining('socket gone'), findsOneWidget);
    });
  });

  group('validation', () {
    testWidgets('blank required fields block the save', (tester) async {
      await openEditor(tester);
      await tapSave(tester);

      expect(delegate.saves, isEmpty);
      expect(find.text('Required'), findsNWidgets(3));
      expect(editorOpen(), isTrue);
    });

    testWidgets('a port outside 1 to 65535 blocks the save', (tester) async {
      await openEditor(tester);
      await fillRequired(tester);
      for (final port in ['0', '65536', 'ssh']) {
        await tester.enterText(field('Port'), port);
        await tapSave(tester);
        expect(find.text('1–65535'), findsOneWidget, reason: port);
      }
      expect(delegate.saves, isEmpty);

      // The range's top is in it.
      await tester.enterText(field('Port'), '65535');
      await tapSave(tester);
      expect(delegate.saves.single.draft.port, 65535);
    });
  });

  group('host options', () {
    Future<void> referenceKeyFile(WidgetTester tester) async {
      await tester.tap(find.byType(DropdownButtonFormField<AuthMethod>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private key').last);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Reference a key file on disk'));
      await tester.tap(find.text('Reference a key file on disk'));
      await tester.pumpAndSettle();
    }

    testWidgets('Browse is offered beside the identity file path', (
      tester,
    ) async {
      await openEditor(tester);
      await referenceKeyFile(tester);

      expect(field('Identity file path'), findsOneWidget);
      expect(find.text('Browse…'), findsOneWidget);
    });

    Future<void> pasteKey(WidgetTester tester) async {
      await tester.tap(find.byType(DropdownButtonFormField<AuthMethod>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private key').last);
      await tester.pumpAndSettle();
    }

    testWidgets('Import from file fills the pasted key, which saves as a '
        'pasted one', (tester) async {
      delegate
        ..canImport = true
        ..importReply = () async => 'KEY TEXT';
      await openEditor(tester);
      await fillRequired(tester);
      await pasteKey(tester);

      await scrollTo(tester, find.text('Import from file…'));
      await tester.tap(find.text('Import from file…'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(field('Private key (PEM/OpenSSH)'))
            .controller!
            .text,
        'KEY TEXT',
      );

      await tapSave(tester);
      expect(delegate.saves.single.credential.keyPem, 'KEY TEXT');
      expect(delegate.saves.single.credential.referenceKeyFile, isFalse);
    });

    testWidgets('a key file that cannot be read says so and keeps the box', (
      tester,
    ) async {
      delegate
        ..canImport = true
        ..importReply = () async => throw const FormatException('binary');
      await openEditor(tester);
      await pasteKey(tester);

      await scrollTo(tester, find.text('Import from file…'));
      await tester.tap(find.text('Import from file…'));
      await tester.pumpAndSettle();
      expect(find.text('Could not read that file as a key.'), findsOneWidget);
      await outlastToasts(tester);
    });

    testWidgets('a host without key import hides it', (tester) async {
      await openEditor(tester);
      await pasteKey(tester);

      expect(find.text('Import from file…'), findsNothing);
    });

    testWidgets('a host that cannot pick files hides Browse', (tester) async {
      delegate.canPick = false;
      await openEditor(tester);
      await referenceKeyFile(tester);

      expect(field('Identity file path'), findsOneWidget);
      expect(find.text('Browse…'), findsNothing);
    });

    testWidgets('on a narrow phone Test connection wraps above Cancel and '
        'Save instead of overflowing', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await openEditor(tester);

      final test = find.widgetWithText(OutlinedButton, 'Test connection');
      await scrollTo(tester, saveButton);
      expect(tester.takeException(), isNull);
      expect(
        tester.getBottomLeft(test).dy,
        lessThanOrEqualTo(tester.getTopLeft(saveButton).dy),
      );
    });

    testWidgets('a host without a connection test hides Test and its note', (
      tester,
    ) async {
      delegate.canTest = false;
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, saveButton);

      expect(find.text('Test connection'), findsNothing);
      expect(find.textContaining('Testing authenticates'), findsNothing);
      // Saving still works without it.
      await tapSave(tester);
      expect(delegate.saves, hasLength(1));
    });

    testWidgets('a hidden start folder keeps the value it opened with', (
      tester,
    ) async {
      await openEditor(
        tester,
        existing: _draft('web', startDirectory: '/var/www'),
        fields: const {},
      );
      expect(
        find.byKey(const ValueKey('serverEditor.startDirectory')),
        findsNothing,
      );

      await tester.enterText(field('Label'), 'renamed');
      await tapSave(tester);
      expect(delegate.saves.single.draft.startDirectory, '/var/www');
    });
  });

  group('failed writes', () {
    testWidgets('a failed save toasts saveFailed and keeps the editor open', (
      tester,
    ) async {
      delegate.saveFailure = StateError('keyring locked');
      await openEditor(tester);
      await fillRequired(tester);
      await tapSave(tester);

      expect(
        find.text('Could not save: Bad state: keyring locked'),
        findsOneWidget,
      );
      expect(editorOpen(), isTrue);

      // Save is enabled again, so the retry reaches the delegate.
      delegate.saveFailure = null;
      await tapSave(tester);
      expect(delegate.saves, hasLength(2));
      expect(editorOpen(), isFalse);
      await outlastToasts(tester);
    });

    testWidgets("a section's failed write toasts its own message and keeps "
        'the editor open', (tester) async {
      await openEditor(tester, sections: [_FailingSection()]);
      await fillRequired(tester);
      await tapSave(tester);

      // The server saved first; only the section's part is left to retry.
      expect(delegate.saves, hasLength(1));
      expect(find.text('Section not saved'), findsOneWidget);
      expect(editorOpen(), isTrue);
      await outlastToasts(tester);
    });
  });
}
