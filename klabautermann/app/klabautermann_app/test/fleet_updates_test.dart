// PKG-06's fleet update center (03 §7.8): every server's kept package
// check, most security updates first, and a fresh check of all on
// request.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/package_reads.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/fleet_updates.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart' show twoServers;

void main() {
  testWidgets('each server shows its kept check, the one with security '
      'updates first, and the refresh checks every server afresh', (
    tester,
  ) async {
    final engine = FakeEngineClient();
    final reads = PackageReads(engine);
    final fleet = FleetController(engine, servers: twoServers);
    addTearDown(() async {
      reads.dispose();
      fleet.dispose();
      await engine.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FleetUpdatesPage(reads: reads, fleet: fleet),
      ),
    );
    final first = [
      for (final r in engine.sentOfType<ReadPackages>()) r as ReadPackages,
    ];
    expect(
      [for (final r in first) (r.serverId, r.fresh)],
      [('srv-1', false), ('srv-2', false)],
    );
    expect(find.text('Checking for updates…'), findsNWidgets(2));

    void answer(ReadPackages read, PackageCheck check) => engine.emit(
      PackagesReport(
        serverId: read.serverId,
        requestId: read.requestId,
        check: check,
        checkedAt: DateTime.utc(2026, 10, 25, 12),
      ),
    );
    answer(first[0], PackageCheck(manager: PackageManager.apk));
    answer(
      first[1],
      PackageCheck(
        manager: PackageManager.apt,
        updates: const [
          PackageUpdate(name: 'libssl3', available: '3', security: true),
          PackageUpdate(name: 'bash', available: '5'),
        ],
        securityCount: 1,
        reboot: RebootState.required,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Up to date'), findsOneWidget);
    expect(
      find.text('2 updates, 1 security · restart required'),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('db-1')).dy,
      lessThan(tester.getTopLeft(find.text('web-1')).dy),
    );

    await tester.tap(find.byTooltip('Check every server again'));
    await tester.pump();
    final again = engine.sentOfType<ReadPackages>().skip(2).toList();
    expect([for (final r in again) (r as ReadPackages).fresh], [true, true]);
  });

  testWidgets('a failed check shows as an error, and a server that joins '
      'the fleet while the page is open is read', (tester) async {
    final engine = FakeEngineClient();
    final reads = PackageReads(engine);
    final fleet = FleetController(engine, servers: twoServers);
    addTearDown(() async {
      reads.dispose();
      fleet.dispose();
      await engine.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FleetUpdatesPage(reads: reads, fleet: fleet),
      ),
    );
    final first = engine.sentOfType<ReadPackages>().first as ReadPackages;
    engine.emit(
      PackagesReport(
        serverId: first.serverId,
        requestId: first.requestId,
        failure: PackagesReportFailure.transport,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);

    FleetEntry entry(String id, String label) => FleetEntry(
      serverId: id,
      label: label,
      host: '$label.example',
      port: 22,
      origin: FleetEntryOrigin.sshConfig,
    );
    engine.emit(
      CatalogReplaced([
        entry('srv-1', 'web-1'),
        entry('srv-2', 'db-1'),
        entry('srv-3', 'cache-1'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(
      [
        for (final r in engine.sentOfType<ReadPackages>().skip(2))
          ((r as ReadPackages).serverId, r.fresh),
      ],
      [('srv-3', false)],
    );
  });
}
