import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/sync_controller.dart';
import 'package:klabautermann_app/controllers/sync_secrets_controller.dart';
import 'package:klabautermann_app/controllers/sync_sign_out.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/ui/settings_page.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _account = SyncAccountInfo(
  baseUrl: 'https://sync.example.com',
  username: 'ops',
);

const _conflict = SyncPinConflict(
  locator: 'alpha.example.com:22',
  localFingerprintSha256: 'SHA256:local',
  pulledFingerprintSha256: 'SHA256:pulled',
);

FleetEntry _entry(String id, FleetEntryOrigin origin) => FleetEntry(
  serverId: id,
  label: id,
  host: '$id.example.com',
  port: 22,
  origin: origin,
);

/// A sign-out as a settings value, with the calls asked of it.
final class _SignOut extends ChangeNotifier implements SyncSignOutSettings {
  @override
  SyncAccountInfo? account = _account;

  @override
  bool busy = false;

  int open = 0;
  bool refuse = false;
  int signOuts = 0;

  @override
  Future<int> openConnectionsRemoved() async => open;

  @override
  Future<void> signOut() async {
    signOuts++;
    if (refuse) throw const SyncSignOutFailedException('refused');
    account = null;
    notifyListeners();
  }
}

// Sync sign-out (03 §4.3, decision Q2): the controller's request, the
// count of connections it closes, and Settings > Sync's confirmation.
void main() {
  group('SyncController.signOut', () {
    test('sends SignOutSync and completes with its answer, which clears the '
        'account, its size and the conflicts', () async {
      final engine = FakeEngineClient();
      final sync = SyncController(engine, account: _account);
      addTearDown(sync.dispose);
      engine.emit(
        const SyncStatus(
          SyncPhase.succeeded,
          operation: SyncOperation.round,
          account: _account,
          pinConflicts: [_conflict],
          prefixBudget: SyncPrefixBudget(10),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sync.conflicts, isNotEmpty);
      expect(sync.accountSize.value, isNotNull);

      final pending = sync.signOut();
      final request = engine.sentOfType<SignOutSync>().single as SignOutSync;
      expect(sync.busy, isTrue);
      engine.emit(
        SyncStatus(
          SyncPhase.succeeded,
          operation: SyncOperation.signOut,
          requestId: request.requestId,
          pinConflicts: const [],
        ),
      );

      final status = await pending;
      expect(status.operation, SyncOperation.signOut);
      expect(sync.account, isNull);
      expect(sync.conflicts, isEmpty);
      expect(sync.accountSize.value, isNull);
      expect(sync.needsSignIn, isTrue);
      expect(sync.busy, isFalse);
    });

    test('a refused sign-out throws from SyncSignOut and keeps the '
        'account', () async {
      final engine = FakeEngineClient();
      final sync = SyncController(engine, account: _account);
      final fleet = FleetController(engine);
      addTearDown(sync.dispose);
      addTearDown(fleet.dispose);

      final pending = SyncSignOut(sync, fleet).signOut();
      final request = engine.sentOfType<SignOutSync>().single as SignOutSync;
      engine.emit(
        SyncStatus(
          SyncPhase.failed,
          operation: SyncOperation.signOut,
          requestId: request.requestId,
          account: _account,
          failure: SyncFailure.storeUnavailable,
        ),
      );

      await expectLater(pending, throwsA(isA<SyncSignOutFailedException>()));
      expect(sync.account, _account);
    });
  });

  test('only synced servers with a usable link count as connections a '
      'sign-out closes', () async {
    final engine = FakeEngineClient();
    final fleet = FleetController(engine);
    addTearDown(fleet.dispose);
    engine
      ..emit(
        CatalogReplaced([
          _entry('ready', FleetEntryOrigin.synced),
          _entry('degraded', FleetEntryOrigin.synced),
          _entry('connecting', FleetEntryOrigin.synced),
          _entry('idle', FleetEntryOrigin.synced),
          _entry('import', FleetEntryOrigin.sshConfig),
        ]),
      )
      ..emit(const LinkState('ready', LinkReady()))
      ..emit(
        const LinkState(
          'degraded',
          LinkDegraded(LinkDegradedReason.sessionLimitLearned),
        ),
      )
      ..emit(const LinkState('connecting', LinkConnecting()))
      ..emit(const LinkState('import', LinkReady()));
    await Future<void>.delayed(Duration.zero);

    expect(openSyncedConnections(fleet), 2);
  });

  test('the link carries the account and whether a sync runs', () {
    final both = decodeSyncAccount(encodeSyncAccount(_account, busy: true));
    expect(both.account, _account);
    expect(both.busy, isTrue);

    final none = decodeSyncAccount(encodeSyncAccount(null, busy: false));
    expect(none.account, isNull);
    expect(none.busy, isFalse);
    expect(decodeSyncAccount('junk').account, isNull);
  });

  group('Settings > Sync', () {
    Future<_SignOut> pump(WidgetTester tester, {_SignOut? model}) async {
      final signOut = model ?? _SignOut();
      final syncSecrets = SyncSecretsController(apply: (_) {});
      addTearDown(syncSecrets.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SyncTab(syncSecrets: syncSecrets, signOut: signOut),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return signOut;
    }

    testWidgets('shows nothing while no account is enrolled', (tester) async {
      await pump(tester, model: _SignOut()..account = null);

      expect(find.text('Sign out'), findsNothing);
    });

    testWidgets('asks first, and Cancel signs nothing out', (tester) async {
      final signOut = await pump(tester);
      expect(
        find.text('Signed in as ops on https://sync.example.com'),
        findsOneWidget,
      );

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out of sync?'), findsOneWidget);
      expect(find.textContaining('open connection'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(signOut.signOuts, 0);
    });

    testWidgets('warns of the connections it closes and signs out on '
        'confirmation', (tester) async {
      final signOut = await pump(tester, model: _SignOut()..open = 2);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(
        find.text('2 servers it removes have open connections, which close.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(signOut.signOuts, 1);
      expect(find.text('Sign out'), findsNothing);
    });

    testWidgets('a refused sign-out says so', (tester) async {
      final signOut = await pump(tester, model: _SignOut()..refuse = true);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pump();

      expect(signOut.signOuts, 1);
      expect(
        find.text('Sign-out did not finish. This device is still signed in.'),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 10));
    });

    testWidgets('the button waits while a sync runs', (tester) async {
      await pump(tester, model: _SignOut()..busy = true);

      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Sign out'),
      );
      expect(button.onPressed, isNull);
    });
  });
}
