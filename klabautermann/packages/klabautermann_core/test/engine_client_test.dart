import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory support;

  setUp(() => support = Directory.systemTemp.createTempSync('klab-client-'));
  tearDown(() => support.deleteSync(recursive: true));

  test('send throws once the engine isolate exited by itself', () async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      entryPoint: _exitAfterHello,
    );
    addTearDown(client.shutdown);

    // The events close when the isolate exits; by then a request has
    // nowhere to go, and silently dropping it would leave its caller
    // waiting for an answer forever.
    await client.events.drain<void>().timeout(const Duration(seconds: 5));

    expect(() => client.send(const RunSyncRound()), throwsStateError);
  });
}

/// An engine that completes the handshake and then exits on its own, as
/// one that met an unhandled error would.
void _exitAfterHello(EngineStart start) {
  final commands = ReceivePort();
  start.uiPort.send(commands.sendPort);
  commands.listen((_) {
    start.uiPort.send(const EngineReady(kEngineProtocolVersion));
    commands.close();
    Isolate.exit();
  });
}
