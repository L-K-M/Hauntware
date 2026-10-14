import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/app.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/services/ssh_config_source.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show DeviceSettingsIssue;

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
/// [sshConfig] stands in for the platform's ssh_config source: a fake for a
/// desktop, null (the default) for a phone, as `sshConfigSourceFor` picks.
/// [openSettingsWindow] likewise stands in for the desktop settings window
/// (null, the default, is a phone's route). [appearance] replaces the
/// in-memory controller, for a test that builds one over a settings store
/// or under a settings window host (the harness disposes it), and
/// [settingsIssue] is what opening that store reported.
Future<AppHarness> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  List<FleetServer> servers = const [],
  SshConfigSource? sshConfig,
  AppearanceController? appearance,
  DeviceSettingsIssue? settingsIssue,
  OpenSettingsWindow? openSettingsWindow,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final harness = AppHarness(
    engine: engine,
    fleet: FleetController(engine, servers: servers, sshConfig: sshConfig),
    monitoring: MonitoringController(engine),
    appearance: appearance ?? AppearanceController(),
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
      settingsIssue: settingsIssue,
      openSettingsWindow: openSettingsWindow,
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
