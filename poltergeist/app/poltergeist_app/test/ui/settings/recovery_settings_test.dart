// CRED-05's Settings → Backup → Recovery section in Poltergeist's words:
// the ARB copy of the status, the actions, an export, a restore summary
// and each failure, and the section's place in Backup. The section's
// behavior is ghost_ui's GhostRecoverySection, tested there.
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
  Object? statusError;
  Object? saveError;
  int refreshes = 0;
  String? savedCode;
  String? restoredCode;
  RestoreConflictPolicy? restoredPolicy;

  @override
  Future<void> refresh() async {
    refreshes++;
    final error = statusError;
    if (error != null) throw error;
    configured ??= false;
    notifyListeners();
  }

  @override
  Future<String> newCode() async => code;

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

  testWidgets('a failed status check is visible and retryable', (tester) async {
    final recovery = _FakeRecovery()
      ..statusError = StateError('untrusted diagnostic');
    await pumpSection(tester, recovery);

    expect(find.byKey(const ValueKey('recovery.status.retry')), findsOneWidget);
    expect(find.text(l10n.recoveryChecking), findsNothing);
    expect(find.textContaining('untrusted diagnostic'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('recovery.setUp')))
          .onPressed,
      isNull,
    );

    recovery.statusError = null;
    await tester.tap(find.byKey(const ValueKey('recovery.status.retry')));
    await tester.pumpAndSettle();
    expect(recovery.refreshes, 2);
    expect(find.text(l10n.recoveryNotConfigured), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('recovery.setUp')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('recovery failures do not echo secret-bearing diagnostics', (
    tester,
  ) async {
    final recovery = _FakeRecovery(configured: true)
      ..exportError = StateError('untrusted diagnostic');
    await pumpSection(tester, recovery);
    await tester.tap(find.byKey(const ValueKey('recovery.export')));
    await tester.pumpAndSettle();
    expect(find.textContaining('untrusted diagnostic'), findsNothing);
    expect(find.text(l10n.recoveryFailed), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recovery.setUp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery.replace.confirm')));
    await tester.pumpAndSettle();
    recovery.saveError = StateError('untrusted diagnostic');
    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      _code.split('-').first,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recovery.code.done')));
    await tester.pumpAndSettle();
    expect(find.textContaining('untrusted diagnostic'), findsNothing);
    expect(find.text(l10n.recoveryFailed), findsWidgets);
    expect(recovery.savedCode, isNull);
  });

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
