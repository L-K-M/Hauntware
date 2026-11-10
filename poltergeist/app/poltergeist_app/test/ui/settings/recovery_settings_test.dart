// CRED-05's Settings → Backup → Recovery section: the configured status,
// the show-once code dialog's first-group check, the replace-code
// confirmation, the export destination, the restore conflict policy and
// its Return key, and the ARB copy a failed export shows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/ui/settings/backup_settings.dart';
import 'package:poltergeist_app/ui/settings/recovery_settings.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_backup_settings.dart';

const _code = 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB';

/// The Recovery section's model with scripted answers, notifying like the
/// app's and the window's do.
final class _FakeRecovery extends ChangeNotifier
    implements RecoverySettingsModel {
  _FakeRecovery({this.configured});

  @override
  bool? configured;

  String code = _code;
  String? destination;
  SecretsRestoreSummary? summary;
  Object? exportError;
  Object? restoreError;
  String? savedCode;
  String? restoredCode;
  RestoreConflictPolicy? restoredPolicy;

  @override
  Future<String> newCode() async => code;

  @override
  Future<void> saveCode(String code) async {
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
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required RestoreConflictPolicy policy,
  }) async {
    final error = restoreError;
    if (error != null) throw error;
    restoredCode = code;
    restoredPolicy = policy;
    return summary;
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  Future<void> pumpSection(WidgetTester tester, _FakeRecovery recovery) async {
    await tester.pumpWidget(wrap(RecoverySection(model: recovery)));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the status and the three actions', (tester) async {
    final recovery = _FakeRecovery(configured: false);
    await pumpSection(tester, recovery);

    expect(find.text(l10n.recoveryTitle), findsOneWidget);
    expect(find.text(l10n.recoveryDescription), findsOneWidget);
    expect(find.text(l10n.recoveryNotConfigured), findsOneWidget);
    expect(find.text(l10n.recoverySetUp), findsOneWidget);
    expect(find.text(l10n.recoveryExport), findsOneWidget);
    expect(find.text(l10n.recoveryRestore), findsOneWidget);
    expect(find.text(l10n.recoveryReplace), findsNothing);
  });

  testWidgets('set up shows the code once and keeps it after the first '
      'group is retyped', (tester) async {
    final recovery = _FakeRecovery(configured: false);
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery.code')), findsOneWidget);

    // The gated button stays off until the first group matches.
    final done = find.byKey(const ValueKey('recovery.code.done'));
    expect(tester.widget<FilledButton>(done).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      'ZZZZ',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(done).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      _code.split('-').first,
    );
    await tester.pump();
    await tester.tap(done);
    await tester.pumpAndSettle();

    expect(recovery.savedCode, _code);
    expect(recovery.configured, isTrue);
    expect(find.byKey(const ValueKey('recovery.code')), findsNothing);
  });

  testWidgets('replace asks before replacing an existing code', (tester) async {
    final recovery = _FakeRecovery(configured: true);
    await pumpSection(tester, recovery);

    expect(find.text(l10n.recoveryConfigured), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryReplaceTitle), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recovery.replace.confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery.code')), findsOneWidget);
    expect(recovery.savedCode, isNull);
  });

  testWidgets('export reports where it wrote, and a failure maps to its '
      'ARB sentence', (tester) async {
    final recovery = _FakeRecovery(configured: true)
      ..destination = '/tmp/poltergeist-secrets-2026-11-10.json';
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.export')));
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.recoveryExportDone(recovery.destination!)),
      findsOneWidget,
    );

    recovery.exportError = const SecretsExportException(
      SecretsExportFailure.wrongCode,
      'diagnostic',
    );
    await tester.tap(find.byKey(const ValueKey('recovery.export')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.secretsExportWrongCode), findsOneWidget);
  });

  testWidgets('restore asks for the code and the policy, then summarizes', (
    tester,
  ) async {
    final recovery = _FakeRecovery(configured: true)
      ..summary = const SecretsRestoreSummary(
        added: 2,
        replaced: 1,
        kept: 3,
        unreadable: 4,
      );
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.restore')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryRestoreTitle), findsOneWidget);

    // The choose button arms only with a code.
    final choose = find.byKey(const ValueKey('recovery.restore.choose'));
    expect(tester.widget<FilledButton>(choose).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('recovery.restore.code')),
      _code,
    );
    await tester.pump();

    await tester.tap(find.text(l10n.recoveryRestoreReplace));
    await tester.pumpAndSettle();
    await tester.tap(choose);
    await tester.pumpAndSettle();

    expect(recovery.restoredCode, _code);
    expect(recovery.restoredPolicy, RestoreConflictPolicy.replaceExisting);
    expect(
      find.text(
        l10n.recoveryRestoreSummary(
          [
            l10n.recoveryRestoreAdded(2),
            l10n.recoveryRestoreReplaced(1),
            l10n.recoveryRestoreKept(3),
            l10n.recoveryRestoreUnreadable(4),
          ].join(', '),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Return on the code field restores under the same gate as '
      'the button', (tester) async {
    final recovery = _FakeRecovery(configured: true)
      ..summary = const SecretsRestoreSummary(
        added: 1,
        replaced: 0,
        kept: 0,
        unreadable: 0,
      );
    await pumpSection(tester, recovery);

    await tester.tap(find.byKey(const ValueKey('recovery.restore')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('recovery.restore.code'));

    await tester.enterText(field, _code);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(recovery.restoredCode, _code);
    expect(recovery.restoredPolicy, RestoreConflictPolicy.keepExisting);
    expect(find.text(l10n.recoveryRestoreTitle), findsNothing);
  });

  testWidgets('the code fields keep the keyboard from learning them', (
    tester,
  ) async {
    final recovery = _FakeRecovery(configured: false);
    await pumpSection(tester, recovery);

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

  testWidgets('the Backup section carries Recovery whether or not the '
      'account is enrolled', (tester) async {
    final recovery = _FakeRecovery(configured: false);
    await tester.pumpWidget(
      wrap(
        BackupSettingsSection(
          service: FakeBackupSettings(),
          recovery: recovery,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecoverySection), findsOneWidget);
    expect(find.text(l10n.recoveryTitle), findsOneWidget);
  });
}
