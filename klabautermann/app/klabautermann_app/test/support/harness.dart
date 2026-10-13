import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/app.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';

import 'fake_engine.dart';

/// Everything a widget test drives the app through (03 §10.1: one controller
/// per concern, handed to the composition root's view by constructor).
final class AppHarness {
  AppHarness({
    required this.engine,
    required this.fleet,
    required this.monitoring,
    required this.appearance,
  });

  final FakeEngineClient engine;
  final FleetController fleet;
  final MonitoringController monitoring;
  final AppearanceController appearance;

  void dispose() {
    fleet.dispose();
    monitoring.dispose();
    appearance.dispose();
  }
}

/// Pumps the real [KlabautermannApp] over a [FakeEngineClient] at [size],
/// which is what decides the shell (03 §10.2 desktop, §10.5 phone).
Future<AppHarness> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  List<FleetServer> servers = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final harness = AppHarness(
    engine: engine,
    fleet: FleetController(engine, servers: servers),
    monitoring: MonitoringController(engine),
    appearance: AppearanceController(),
  );
  addTearDown(() async {
    harness.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    KlabautermannApp(
      fleet: harness.fleet,
      monitoring: harness.monitoring,
      appearance: harness.appearance,
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

/// The ARB strings the widget tests assert against by their English text.
const List<FleetServer> twoServers = [
  FleetServer(id: 'srv-1', displayName: 'web-1', address: 'web-1.example'),
  FleetServer(id: 'srv-2', displayName: 'db-1', address: '10.0.0.4'),
];
