// SYN-09: the account size view in Settings > Sync, from the prefix
// budget a succeeded sync operation reports.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/account_size.dart';
import 'package:klabautermann_app/controllers/sync_controller.dart';
import 'package:klabautermann_app/controllers/sync_secrets_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/ui/settings_page.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _account = SyncAccountInfo(
  baseUrl: 'https://sync.example',
  username: 'ada',
);

SyncPrefixBudget _budget(int used) => SyncPrefixBudget(
  used,
  byPrefix: {
    'klabautermann:pref': SyncRecordUsage(records: 2, bytes: used),
    'snippet': const SyncRecordUsage(records: 1, bytes: 300),
    'serverConfig': const SyncRecordUsage(records: 4, bytes: 4096),
  },
);

void main() {
  test('the controller keeps the size a succeeded operation reports and '
      'drops it once no account is enrolled', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine, account: _account);
    addTearDown(() async {
      sync.dispose();
      await engine.close();
    });
    expect(sync.accountSize.value, isNull);

    engine.emit(
      SyncStatus(
        SyncPhase.succeeded,
        operation: SyncOperation.round,
        account: _account,
        prefixBudget: _budget(2048),
      ),
    );
    await pumpEventQueue();
    final size = sync.accountSize.value!;
    expect(size.prefixBytes, 2048);
    expect(size.budgetBytes, kSyncPrefixBudgetBytes);
    expect(
      [for (final row in size.rows) row.prefix],
      ['serverConfig', 'klabautermann:pref', 'snippet'],
      reason: 'the largest first',
    );

    engine.emit(
      const SyncStatus(SyncPhase.failed, operation: SyncOperation.round),
    );
    await pumpEventQueue();
    expect(sync.accountSize.value, isNull);
  });

  test('the size survives the settings link', () {
    final size = accountSizeOf(_budget(900 * 1024));
    expect(decodeAccountSize(encodeAccountSize(size)), size);
    expect(decodeAccountSize(null), isNull);
    expect(decodeAccountSize('nonsense'), isNull);
  });

  testWidgets('the Sync tab shows the size once known, the rows the '
      'largest first, and warns near the budget', (tester) async {
    final syncSecrets = SyncSecretsController(apply: (_) {});
    final size = ValueNotifier<AccountSize?>(null);
    addTearDown(() {
      syncSecrets.dispose();
      size.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncTab(syncSecrets: syncSecrets, accountSize: size),
        ),
      ),
    );
    expect(find.text('Account size'), findsNothing);

    size.value = accountSizeOf(_budget(2048));
    await tester.pump();
    expect(find.text('Account size'), findsOneWidget);
    expect(
      find.text(
        "Klabautermann's records take 2 KiB of their 1 MiB in the sync "
        'account.',
      ),
      findsOneWidget,
    );
    expect(find.text('4 records, 4 KiB'), findsOneWidget);
    expect(find.text('1 record, 300 B'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('serverConfig')).dy,
      lessThan(tester.getTopLeft(find.text('snippet')).dy),
    );
    expect(find.textContaining('close to the limit'), findsNothing);

    size.value = accountSizeOf(_budget(900 * 1024));
    await tester.pump();
    expect(find.textContaining('close to the limit'), findsOneWidget);

    size.value = accountSizeOf(_budget(kSyncPrefixBudgetBytes));
    await tester.pump();
    expect(find.textContaining('reached the limit'), findsOneWidget);
  });
}
