import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// Readings each [_countingEngine] run sends per [Subscribe].
const _readings = 3;

/// An engine that counts its own seq from 1, as every run does (D44), and
/// answers a [Subscribe] with [_readings] samples.
void _countingEngine(EngineStart start) {
  final commands = ReceivePort('counting engine');
  var seq = 0;
  start.uiPort.send(commands.sendPort);
  commands.listen((message) {
    switch (message) {
      case Hello():
        start.uiPort.send(const EngineReady(kEngineProtocolVersion));
      case Subscribe(:final serverId, :final streams):
        for (var reading = 1; reading <= _readings; reading++) {
          start.uiPort.send(
            Sample(
              serverId: serverId,
              stream: streams.single,
              seq: ++seq,
              at: DateTime.now().toUtc(),
              result: OverviewResult(
                cpu: CpuPercentages(const [], reading * 10.0),
              ),
            ),
          );
        }
      case Shutdown():
        commands.close();
        Isolate.exit();
    }
  });
}

/// The readings [monitoring] keeps of srv-1's overview once [engine] sent
/// them all; then the engine stops.
Future<List<double?>> _keptReadings(
  IsolateEngineClient engine,
  MonitoringController monitoring,
) async {
  const stream = SampleStream.overview;
  final ring = monitoring.seriesFor('srv-1', stream, MetricSeries.cpuBusy);
  final all = Completer<void>();
  ring.addListener(() {
    if (ring.added == _readings && !all.isCompleted) all.complete();
  });

  monitoring.subscribe('srv-1', 'overview', const {stream});
  await all.future.timeout(const Duration(seconds: 10));
  await engine.shutdown();
  return ring.samples.toList();
}

/// D44 through the real client: the engine handshake consumes
/// [EngineReady] and an exit closes the client's events, so a restarted
/// engine is a new client, and the controller built over it starts with no
/// seq floor. A floor carried over from the first run would drop every
/// sample of the second, whose seq counts from 1 again.
void main() {
  late Directory support;

  setUp(() => support = Directory.systemTemp.createTempSync('klab-restart'));
  tearDown(() => support.deleteSync(recursive: true));

  Future<IsolateEngineClient> spawn() => IsolateEngineClient.spawn(
    supportDirectory: support.path,
    entryPoint: _countingEngine,
  );

  test('a restarted engine\'s samples are kept from seq 1', () async {
    final first = await spawn();
    final firstMonitoring = MonitoringController(first);
    addTearDown(firstMonitoring.dispose);
    expect(await _keptReadings(first, firstMonitoring), [10, 20, 30]);

    // The first run's controller has nothing left to send to, and does not
    // throw for it.
    firstMonitoring
      ..openServer('srv-1')
      ..unsubscribe('srv-1', 'overview');

    final second = await spawn();
    final secondMonitoring = MonitoringController(second);
    addTearDown(secondMonitoring.dispose);
    expect(await _keptReadings(second, secondMonitoring), [10, 20, 30]);
    expect(
      secondMonitoring.sampleFor('srv-1', SampleStream.overview).value?.seq,
      _readings,
    );
  });
}
