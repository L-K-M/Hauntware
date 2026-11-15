// CRED-05's shared Recovery section and dialogs: the configured status
// and its retry, the show-once code dialog's first-group check, the
// replace-code confirmation, the export destination, the restore
// conflict policy and its Return key, and the app's own wording of a
// failure. Moved from Poltergeist's and Klabautermann's app tests, whose
// remaining tests cover each app's ARB wording.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

const _code = 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB';

enum _Policy { keep, replace }

/// A restore summary: what was added.
typedef _Summary = int;

final _strings = GhostRecoveryStrings(
  title: 'Recovery',
  description: 'A code opens an export.',
  checking: 'Checking',
  configured: 'Has a code',
  notConfigured: 'No code yet',
  retry: 'Retry',
  setUp: 'Set up',
  replace: 'Replace code',
  export: 'Export',
  restore: 'Restore',
  replaceTitle: 'Replace the code?',
  replaceBody: 'Old exports still open with the old code.',
  replaceCancel: 'Keep it',
  replaceConfirm: 'Replace it',
  exportDone: (destination) => 'Exported to $destination',
  code: const GhostRecoveryCodeStrings(
    title: 'Your code',
    body: 'Write it down.',
    copy: 'Copy',
    copied: 'Copied',
    confirmLabel: 'First group',
    cancel: 'Cancel code',
    done: 'Saved it',
  ),
  restoreDialog: const GhostRestoreDialogStrings(
    title: 'Restore secrets',
    body: 'Enter the code.',
    codeLabel: 'Code',
    conflictLabel: 'Existing credentials:',
    keep: 'Keep mine',
    replace: 'Use theirs',
    cancel: 'Cancel restore',
    choose: 'Choose file',
  ),
);

/// The model with scripted answers, notifying like the apps' do.
final class _FakeRecovery extends ChangeNotifier
    implements GhostRecoveryModel<_Policy, _Summary> {
  _FakeRecovery({this.configured});

  @override
  bool? configured;

  String? destination;
  _Summary? summary;
  Object? exportError;
  Object? statusError;
  Object? saveError;
  int refreshes = 0;
  String? savedCode;
  String? restoredCode;
  _Policy? restoredPolicy;

  @override
  Future<void> refresh() async {
    refreshes++;
    final error = statusError;
    if (error != null) throw error;
    configured ??= false;
    notifyListeners();
  }

  @override
  Future<String> newCode() async => _code;

  @override
  Future<void> saveCode(String code) async {
    final error = saveError;
    if (error != null) throw error;
    savedCode = code;
    configured = true;
    notifyListeners();
  }

  @override
  Future<String?> exportSecrets() async {
    final error = exportError;
    if (error != null) throw error;
    return destination;
  }

  @override
  Future<_Summary?> restoreSecrets({
    required String code,
    required _Policy policy,
  }) async {
    restoredCode = code;
    restoredPolicy = policy;
    return summary;
  }
}

void main() {
  Future<void> pumpSection(WidgetTester tester, _FakeRecovery recovery) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GhostRecoverySection<_Policy, _Summary>(
              model: recovery,
              strings: _strings,
              codeStyle: const TextStyle(fontFamily: 'monospace'),
              keepExisting: _Policy.keep,
              replaceExisting: _Policy.replace,
              describeError: (error) => 'action failed: ${error.runtimeType}',
              describeStatusError: (_) => 'status failed',
              describeSaveError: (_) => 'save failed',
              describeRestore: (added) => 'Restored $added',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> retypeFirstGroup(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      _code.split('-').first,
    );
    await tester.pump();
  }

  VoidCallback? onPressed(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed;

  testWidgets('a failed status check is visible and retryable', (tester) async {
    final recovery = _FakeRecovery()
      ..statusError = StateError('untrusted diagnostic');
    await pumpSection(tester, recovery);

    expect(find.text('status failed'), findsOneWidget);
    expect(find.text('Checking'), findsNothing);
    expect(find.textContaining('untrusted diagnostic'), findsNothing);
    expect(onPressed(tester, 'recovery.setUp'), isNull);
    expect(onPressed(tester, 'recovery.export'), isNull);

    recovery.statusError = null;
    await tester.tap(find.byKey(const ValueKey('recovery.status.retry')));
    await tester.pumpAndSettle();
    expect(recovery.refreshes, 2);
    expect(find.text('No code yet'), findsOneWidget);
    expect(onPressed(tester, 'recovery.setUp'), isNotNull);
  });

  testWidgets('shows the status and the three actions', (tester) async {
    await pumpSection(tester, _FakeRecovery(configured: false));

    expect(find.text('Recovery'), findsOneWidget);
    expect(find.text('A code opens an export.'), findsOneWidget);
    expect(find.text('No code yet'), findsOneWidget);
    expect(find.text('Set up'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
    expect(find.text('Replace code'), findsNothing);
    expect(onPressed(tester, 'recovery.export'), isNull, reason: 'no code');
  });

  testWidgets('set up shows the code once and keeps it after the first '
      'group is retyped', (tester) async {
    final recovery = _FakeRecovery(configured: false);
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery.code')), findsOneWidget);

    // The gated button stays off until the first group matches.
    expect(onPressed(tester, 'recovery.code.done'), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      'ZZZZ',
    );
    await tester.pump();
    expect(onPressed(tester, 'recovery.code.done'), isNull);

    await retypeFirstGroup(tester);
    await tester.tap(find.byKey(const ValueKey('recovery.code.done')));
    await tester.pumpAndSettle();

    expect(recovery.savedCode, _code);
    expect(recovery.configured, isTrue);
    expect(find.byKey(const ValueKey('recovery.code')), findsNothing);
    expect(find.text('Replace code'), findsOneWidget);
  });

  testWidgets('cancelling the code dialog keeps nothing', (tester) async {
    final recovery = _FakeRecovery(configured: false);
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery.code.cancel')));
    await tester.pumpAndSettle();

    expect(recovery.savedCode, isNull);
    expect(recovery.configured, isFalse);
  });

  testWidgets('a failed save shows the app\'s line and keeps the dialog', (
    tester,
  ) async {
    final recovery = _FakeRecovery(configured: false)
      ..saveError = StateError('untrusted diagnostic');
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    await retypeFirstGroup(tester);
    await tester.tap(find.byKey(const ValueKey('recovery.code.done')));
    await tester.pumpAndSettle();

    expect(find.text('save failed'), findsOneWidget);
    expect(find.textContaining('untrusted diagnostic'), findsNothing);
    expect(find.byKey(const ValueKey('recovery.code')), findsOneWidget);
    expect(recovery.savedCode, isNull);
  });

  testWidgets('replace asks before replacing an existing code', (tester) async {
    final recovery = _FakeRecovery(configured: true);
    await pumpSection(tester, recovery);

    expect(find.text('Has a code'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    expect(find.text('Replace the code?'), findsOneWidget);

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery.code')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery.replace.confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery.code')), findsOneWidget);
    expect(recovery.savedCode, isNull);
  });

  testWidgets('export reports where it wrote, and a failure in the app\'s '
      'words', (tester) async {
    final recovery = _FakeRecovery(configured: true)
      ..destination = '/tmp/secrets.json';
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.export')));
    await tester.pumpAndSettle();
    expect(find.text('Exported to /tmp/secrets.json'), findsOneWidget);

    recovery.exportError = StateError('untrusted diagnostic');
    await tester.tap(find.byKey(const ValueKey('recovery.export')));
    await tester.pumpAndSettle();
    expect(find.text('action failed: StateError'), findsOneWidget);
    expect(find.text('Exported to /tmp/secrets.json'), findsNothing);
  });

  testWidgets('restore asks for the code and the policy, then summarizes', (
    tester,
  ) async {
    final recovery = _FakeRecovery(configured: true)..summary = 2;
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.restore')));
    await tester.pumpAndSettle();
    expect(find.text('Restore secrets'), findsOneWidget);

    // The choose button arms only with a code.
    expect(onPressed(tester, 'recovery.restore.choose'), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('recovery.restore.code')),
      _code,
    );
    await tester.pump();

    await tester.tap(find.text('Use theirs'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery.restore.choose')));
    await tester.pumpAndSettle();

    expect(recovery.restoredCode, _code);
    expect(recovery.restoredPolicy, _Policy.replace);
    expect(find.text('Restored 2'), findsOneWidget);
  });

  testWidgets('a cancelled restore dialog restores nothing', (tester) async {
    final recovery = _FakeRecovery(configured: true)..summary = 1;
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.restore')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel restore'));
    await tester.pumpAndSettle();

    expect(recovery.restoredCode, isNull);
    expect(find.text('Restored 1'), findsNothing);
  });

  testWidgets('Return on the code field restores under the same gate as '
      'the button', (tester) async {
    final recovery = _FakeRecovery(configured: true)..summary = 1;
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.restore')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('recovery.restore.code'));

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(recovery.restoredCode, isNull, reason: 'no code yet');

    await tester.enterText(field, _code);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(recovery.restoredCode, _code);
    expect(recovery.restoredPolicy, _Policy.keep);
    expect(find.text('Restore secrets'), findsNothing);
  });

  testWidgets('the code fields keep the keyboard from learning them', (
    tester,
  ) async {
    await pumpSection(tester, _FakeRecovery(configured: false));

    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    final confirm = tester.widget<TextField>(
      find.byKey(const ValueKey('recovery.code.confirm')),
    );
    expect(confirm.autocorrect, isFalse);
    expect(confirm.enableSuggestions, isFalse);
    expect(confirm.enableIMEPersonalizedLearning, isFalse);

    await tester.tap(find.byKey(const ValueKey('recovery.code.cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery.restore')));
    await tester.pumpAndSettle();
    final restore = tester.widget<TextField>(
      find.byKey(const ValueKey('recovery.restore.code')),
    );
    expect(restore.autocorrect, isFalse);
    expect(restore.enableSuggestions, isFalse);
    expect(restore.enableIMEPersonalizedLearning, isFalse);
  });
}
