// The System tab's Updates section (PKG-01 to PKG-03, 03 §7.8): it reads
// the engine's check when it shows, lists the updates with security ones
// first, says whether the server asks for a restart, and checks again on
// request.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/package_reads.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart'
    show OperationsScope;
import 'package:klabautermann_app/ui/admin_mode_chip.dart' show AdminScope;
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_app/ui/updates.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

void main() {
  late FakeEngineClient engine;
  late PackageReads reads;

  setUp(() {
    engine = FakeEngineClient();
    reads = PackageReads(engine);
  });

  tearDown(() async {
    reads.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester, {String serverId = _server}) =>
      tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: UpdatesSection(
                reads: reads,
                serverId: serverId,
                tableId: 'updates',
              ),
            ),
          ),
        ),
      );

  ReadPackages lastRead() =>
      engine.sentOfType<ReadPackages>().last as ReadPackages;

  Future<void> answer(
    WidgetTester tester, {
    PackageCheck? check,
    PackagesReportFailure? failure,
  }) async {
    final read = lastRead();
    engine.emit(
      PackagesReport(
        serverId: read.serverId,
        requestId: read.requestId,
        check: check,
        checkedAt: check == null ? null : DateTime.utc(2026, 10, 25, 12),
        failure: failure,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('it reads the kept check when it shows, then lists the '
      'updates with security ones first and the restart asked for', (
    tester,
  ) async {
    await pump(tester);
    expect(lastRead().fresh, isFalse);
    expect(find.text('Checking for updates…'), findsOneWidget);

    await answer(
      tester,
      check: PackageCheck(
        manager: PackageManager.apt,
        updates: const [
          PackageUpdate(name: 'base-files', current: '12.4', available: '12.6'),
          PackageUpdate(
            name: 'libssl3',
            current: '3.0.11',
            available: '3.0.13',
            security: true,
          ),
        ],
        securityCount: 1,
        cachedAt: DateTime.utc(2026, 10, 25, 9),
        reboot: RebootState.required,
        rebootPackages: const ['libc6'],
      ),
    );

    expect(find.text('2 updates available'), findsOneWidget);
    expect(find.text('1 is a security update'), findsOneWidget);
    expect(
      find.text('The server asks for a restart, for libc6.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Package lists last downloaded'),
      findsOneWidget,
    );
    final libssl = tester.getTopLeft(find.text('libssl3')).dy;
    final baseFiles = tester.getTopLeft(find.text('base-files')).dy;
    expect(libssl, lessThan(baseFiles));
  });

  testWidgets('check again asks for a fresh check', (tester) async {
    await pump(tester);
    await answer(tester, check: PackageCheck(manager: PackageManager.apk));
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.textContaining('security'), findsNothing);

    await tester.tap(find.text('Check again'));
    await tester.pump();
    expect(lastRead().fresh, isTrue);
    expect(engine.sentOfType<ReadPackages>(), hasLength(2));
  });

  testWidgets('each failure says why, and zypper counts patches', (
    tester,
  ) async {
    await pump(tester);
    await answer(tester, failure: PackagesReportFailure.noLink);
    expect(
      find.text(
        'The server is not connected, so updates could not be checked.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Check again'));
    await tester.pump();
    await answer(
      tester,
      check: PackageCheck(
        manager: PackageManager.dnf,
        failure: PackageCheckFailure.noCache,
      ),
    );
    expect(find.textContaining('never downloads them'), findsOneWidget);

    await tester.tap(find.text('Check again'));
    await tester.pump();
    await answer(
      tester,
      check: PackageCheck(
        manager: PackageManager.zypper,
        updates: const [PackageUpdate(name: 'bash', available: '5.1-2')],
        securityCount: 3,
        reboot: RebootState.notRequired,
      ),
    );
    expect(find.text('3 security patches are needed'), findsOneWidget);
    expect(find.text('No restart required'), findsOneWidget);
  });

  testWidgets('a server switch reads that server and drops a late answer '
      'for the last one', (tester) async {
    await pump(tester);
    final first = lastRead();
    await pump(tester, serverId: 'srv-2');
    expect(lastRead().serverId, 'srv-2');

    engine.emit(
      PackagesReport(
        serverId: first.serverId,
        requestId: first.requestId,
        check: PackageCheck(manager: PackageManager.apk),
        checkedAt: DateTime.utc(2026, 10, 25),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Up to date'), findsNothing);
    expect(find.text('Checking for updates…'), findsOneWidget);
  });

  testWidgets('in admin mode the lists can be refreshed, and without it a '
      'check that found none says admin mode downloads them', (tester) async {
    final admin = AdminController(engine);
    final operations = OperationsController(engine);
    final safety = SafetyController(
      initial: const SafetyPolicy(
        servers: {_server: ServerSafety(management: true)},
      ),
      apply: (_) {},
    );
    addTearDown(() {
      admin.dispose();
      operations.dispose();
      safety.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SafetyScope(
            safety: safety,
            child: OperationsScope(
              operations: operations,
              child: AdminScope(
                admin: admin,
                child: SingleChildScrollView(
                  child: UpdatesSection(
                    reads: reads,
                    serverId: _server,
                    tableId: 'updates',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await answer(
      tester,
      check: PackageCheck(
        manager: PackageManager.dnf,
        failure: PackageCheckFailure.noCache,
      ),
    );
    expect(find.text('Refresh package lists'), findsNothing);
    expect(find.text('Turn on admin mode to download them.'), findsOneWidget);

    engine.emit(const AdminModeState(_server, AdminModePhase.on));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh package lists'));
    await tester.pump();
    final plan = engine.sentOfType<PlanAction>().single as PlanAction;
    expect(plan.intent, isA<RefreshPackageLists>());
    expect(plan.intent.serverId, _server);
  });
}
