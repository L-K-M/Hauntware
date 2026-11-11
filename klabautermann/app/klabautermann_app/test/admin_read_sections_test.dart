// The System tab's root-read sections (firewall, sshd posture, drive
// health, services to restart) run each read once: a server switch while a
// read is out neither re-enables the button nor lets a second read start.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/package_reads.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/admin_mode_chip.dart' show AdminScope;
import 'package:klabautermann_app/ui/drive_health.dart';
import 'package:klabautermann_app/ui/firewall.dart';
import 'package:klabautermann_app/ui/sshd_posture.dart';
import 'package:klabautermann_app/ui/updates.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _a = 'srv-a';
const _b = 'srv-b';

typedef _Section = Widget Function(PackageReads reads, String serverId);

void main() {
  final sections = <(String, String, String, Type, _Section)>[
    (
      'firewall',
      'Read firewall rules',
      'Reading the firewall rules…',
      ReadFirewall,
      (reads, serverId) => FirewallSection(serverId: serverId),
    ),
    (
      'sshd posture',
      'Read SSH server settings',
      'Reading the SSH server\'s settings…',
      ReadSshdPosture,
      (reads, serverId) => SshdPostureSection(
        serverId: serverId,
        fact: (label, value, {note}) => Text('$label $value'),
      ),
    ),
    (
      'drive health',
      'Read drive health',
      'Reading drive health…',
      ReadSmart,
      (reads, serverId) =>
          DriveHealthSection(serverId: serverId, tableId: 'drives'),
    ),
    (
      'services to restart',
      'Find services to restart',
      'Looking for services to restart…',
      ReadRestarts,
      (reads, serverId) =>
          UpdatesSection(reads: reads, serverId: serverId, tableId: 'updates'),
    ),
  ];

  for (final (name, button, reading, request, build) in sections) {
    testWidgets('$name: a server switch does not allow a second read', (
      tester,
    ) async {
      final engine = FakeEngineClient();
      final admin = AdminController(engine);
      final reads = PackageReads(engine);
      final serverId = ValueNotifier(_a);
      addTearDown(() async {
        serverId.dispose();
        reads.dispose();
        admin.dispose();
        await engine.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AdminScope(
              admin: admin,
              child: SingleChildScrollView(
                child: ValueListenableBuilder(
                  valueListenable: serverId,
                  builder: (context, id, _) => build(reads, id),
                ),
              ),
            ),
          ),
        ),
      );
      engine
        ..emit(const AdminModeState(_a, AdminModePhase.on))
        ..emit(const AdminModeState(_b, AdminModePhase.on));
      await tester.pumpAndSettle();

      int sent() => engine.sentOfType<EngineRequest>().where((r) {
        return r.runtimeType == request;
      }).length;

      await tester.tap(find.text(button));
      // A second tap in the same frame is ignored.
      await tester.tap(find.text(button), warnIfMissed: false);
      await tester.pump();
      expect(sent(), 1);

      serverId.value = _b;
      await tester.pump();
      serverId.value = _a;
      await tester.pump();

      // The first read is still out for this server: no button to tap.
      expect(find.text(button), findsNothing);
      expect(find.text(reading), findsOneWidget);
      expect(sent(), 1);
    });
  }
}
