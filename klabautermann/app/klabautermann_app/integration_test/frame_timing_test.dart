// Spike S5 part 2 (04 §13 S5, 03 §11.4): the app's frame timing with ten
// monitored servers and a 1,000 lines/s follow. The replay engine
// (package:klabautermann_core/replay.dart) serves the committed host
// fixtures through the production client and isolate hop, and the real
// app draws them; `FrameTiming` build and raster times are summarized for
// the fleet list, a server's Overview and its Logs panel.
//
// `klabautermann/scripts/bench-frame-timing.sh` runs it in profile mode
// under `flutter drive`; the driver writes the report, which
// klabautermann/docs/evidence/s5/README.md describes. It fails when the
// load does not reach the app or stops while a surface is measured, never
// on a slow number.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:klabautermann_app/app.dart';
import 'package:klabautermann_app/controllers/announcement_controller.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/controllers/coverage_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/prompt_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/replay.dart';

/// `klabautermann_host`'s fixtures; the default is their place relative
/// to this app, for a run from its directory.
const _fixtures = String.fromEnvironment(
  'KLABAUTERMANN_REPLAY_FIXTURES',
  defaultValue: '../../packages/klabautermann_host/test/fixtures',
);

/// How long each surface is measured.
const _seconds = int.fromEnvironment(
  'KLABAUTERMANN_FRAME_SECONDS',
  defaultValue: 20,
);

/// What the script says about the display and toolchain, for the report.
const _display = String.fromEnvironment('KLABAUTERMANN_FRAME_DISPLAY');
const _flutterVersion = String.fromEnvironment('KLABAUTERMANN_FLUTTER_VERSION');

/// The server opened: the second fixture platform, debian-12, whose probe
/// finds a journal, so its Logs panel shows.
const _opened = 'replay-1';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('frame timing with ten monitored servers and a 1,000 lines/s '
      'follow', (tester) async {
    // Frames as the app schedules them; the test's pumps only wait.
    binding.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

    final plan = ReplayPlan(
      fixtures: loadHostFixtures(_fixtures),
      journalRows: loadJournalRows(_fixtures),
    );
    final engine = await IsolateEngineClient.spawn(
      supportDirectory: Directory.systemTemp.path,
      entryPoint: replayEngine(plan),
    );
    // The fleet controller listens first: the client holds the startup
    // fleet for its first listener (main.dart).
    final fleet = FleetController(engine);
    final monitoring = MonitoringController(engine);
    // The replay engine opens no prompt; the app shows them all the same.
    final prompts = PromptController(engine);
    final appearance = AppearanceController();
    final coverage = CoverageController(firstRunCardDismissed: true);
    final announcements = AnnouncementController();
    final load = _Load(engine.events);
    addTearDown(() async {
      await load.cancel();
      fleet.dispose();
      monitoring.dispose();
      prompts.dispose();
      appearance.dispose();
      coverage.dispose();
      announcements.dispose();
      await engine.shutdown();
    });

    binding.reportData = {
      'schemaVersion': 1,
      'test': 'klabautermann_app/integration_test/frame_timing_test.dart',
      'measuredAt': DateTime.now().toUtc().toIso8601String(),
      'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
      'display': _display.isEmpty ? null : _display,
      'flutterVersion': _flutterVersion.isEmpty ? null : _flutterVersion,
      'machine': {
        'os': Platform.operatingSystemVersion,
        'cpus': Platform.numberOfProcessors,
        'cpuModel': _cpuModel(),
        'loadavgStart': _loadavg(),
      },
      'plan': {
        'hosts': [
          for (var i = 0; i < plan.hosts; i++)
            plan.fixtures[i % plan.fixtures.length].platform,
        ],
        'monitored': [for (final s in plan.monitored) s.name],
        'logLinesPerSecond': plan.logLinesPerSecond,
        'secondsPerSurface': _seconds,
      },
    };

    await tester.pumpWidget(
      KlabautermannApp(
        fleet: fleet,
        monitoring: monitoring,
        prompts: prompts,
        appearance: appearance,
        coverage: coverage,
        announcements: announcements,
      ),
    );
    await _until(
      () => load.serversSampled.length == plan.hosts,
      'a sample from every replayed server',
    );
    await _measure(binding, load, 'fleet');

    fleet.select(_opened);
    await _until(
      () => monitoring.sampleFor(_opened, SampleStream.fs).value != null,
      "the Overview's readings",
    );
    await _measure(binding, load, 'overview');

    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.tap(find.widgetWithText(Tab, l10n.workspaceTabLogs));
    await _until(() => load.logRecords > 0, "the Logs panel's follow");
    await _measure(
      binding,
      load,
      'logs',
      minLogRecordsPerSecond: plan.logLinesPerSecond / 2,
    );

    (binding.reportData!['machine'] as Map)['loadavgEnd'] = _loadavg();
  });
}

/// Polls [done] on a real timer, since the test's pumps draw nothing.
Future<void> _until(bool Function() done, String what) async {
  final clock = Stopwatch()..start();
  while (!done()) {
    if (clock.elapsed > const Duration(seconds: 60)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Measures [surface] for [_seconds] through `watchPerformance`, which
/// reports `FrameTimingSummarizer`'s summary under [surface]; keeps its
/// figures without the per-frame lists, and adds the load that reached
/// the app meanwhile. Throws, after keeping them, when no sample or fewer
/// than [minLogRecordsPerSecond] log records arrived: a replay isolate
/// that died or a follow that stalled, not a slow frame.
Future<void> _measure(
  IntegrationTestWidgetsFlutterBinding binding,
  _Load load,
  String surface, {
  double minLogRecordsPerSecond = 0,
}) async {
  late final ({int samples, int records, int batches}) before, after;
  final clock = Stopwatch();
  await binding.watchPerformance(() async {
    before = load.counts;
    clock.start();
    await Future<void>.delayed(const Duration(seconds: _seconds));
    clock.stop();
    after = load.counts;
  }, reportKey: surface);

  final seconds = clock.elapsedMicroseconds / 1e6;
  double rate(int count) => (count / seconds * 10).round() / 10;
  final summary = (binding.reportData![surface] as Map<String, dynamic>)
    ..removeWhere((_, value) => value is List);
  summary['load'] = {
    'seconds': seconds,
    'samplesPerSecond': rate(after.samples - before.samples),
    'logRecordsPerSecond': rate(after.records - before.records),
    'logBatchesPerSecond': rate(after.batches - before.batches),
  };

  if (after.samples == before.samples) {
    throw StateError('no sample reached the app while $surface showed');
  }
  final records = (after.records - before.records) / seconds;
  if (records < minLogRecordsPerSecond) {
    throw StateError(
      '${records.toStringAsFixed(1)} log records a second reached the app '
      'while $surface showed, under $minLogRecordsPerSecond',
    );
  }
}

/// What reached the app from the engine.
final class _Load {
  _Load(Stream<EngineEvent> events) {
    _subscription = events.listen((event) {
      switch (event) {
        case Sample(:final serverId):
          samples++;
          serversSampled.add(serverId);
        case LogBatch(:final records):
          logBatches++;
          logRecords += records.length;
        case EngineEvent():
          break;
      }
    });
  }

  late final StreamSubscription<EngineEvent> _subscription;
  final Set<String> serversSampled = {};
  int samples = 0, logBatches = 0, logRecords = 0;

  ({int samples, int records, int batches}) get counts =>
      (samples: samples, records: logRecords, batches: logBatches);

  Future<void> cancel() => _subscription.cancel();
}

String? _loadavg() =>
    Platform.isLinux ? File('/proc/loadavg').readAsStringSync().trim() : null;

String? _cpuModel() {
  if (!Platform.isLinux) return null;

  for (final line in File('/proc/cpuinfo').readAsLinesSync()) {
    if (line.startsWith('model name')) {
      return line.substring(line.indexOf(':') + 1).trim();
    }
  }
  return null;
}
