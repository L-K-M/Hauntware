import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart'
    show engineMain;
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

  test('ENG-6: an engine that dies after the handshake says what it died '
      'of', () async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      entryPoint: _dieAfterHello,
    );
    addTearDown(client.shutdown);

    final exit = await client.exited.timeout(const Duration(seconds: 5));
    expect(exit.error, contains('link table corrupt'));
    expect(exit.stack, isNotEmpty);
  });

  test('CTL-01: every listener subscribed in the turn after the first gets '
      'the startup events', () async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      entryPoint: _startupEvents,
    );
    addTearDown(client.shutdown);

    // The composition root may await other startup work after the spawn,
    // so the startup events wait for it; then it builds its controllers
    // one after another in one turn, the first subscribing before the
    // others exist.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final first = <EngineEvent>[];
    final second = <EngineEvent>[];
    client.events.listen(first.add);
    client.events.listen(second.add);
    await client.events
        .firstWhere((event) => event is EngineFault && event.error == 'two')
        .timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);

    String errors(List<EngineEvent> events) =>
        events.whereType<EngineFault>().map((fault) => fault.error).join(',');
    expect(errors(first), 'one,two');
    expect(errors(second), 'one,two');
  });

  test('shutdown ends an engine that does not answer Shutdown', () async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      entryPoint: _ignoreShutdown,
    );

    final watch = Stopwatch()..start();
    await client.shutdown().timeout(const Duration(seconds: 10));

    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    await client.exited.timeout(const Duration(seconds: 5));
  });

  test('an engine that stops on Shutdown exits without an error', () async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
    );
    await client.shutdown();

    expect((await client.exited).error, isNull);
  });

  test('a real engine whose startup fails refuses Hello with the error, '
      'rather than dying unhandled', () async {
    await expectLater(
      IsolateEngineClient.spawn(
        supportDirectory: support.path,
        entryPoint: _engineFailingAtStartup,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          startsWith(
            'engine refused Hello: engine failed to start: '
            'FileSystemException: store unreadable',
          ),
        ),
      ),
    );
  });

  test('spawn names the error an engine met while starting', () async {
    await expectLater(
      IsolateEngineClient.spawn(
        supportDirectory: support.path,
        entryPoint: _failWhileStarting,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('support directory unreadable'),
        ),
      ),
    );
  });
}

/// The real engine, whose last startup step throws as a store that
/// cannot open would.
void _engineFailingAtStartup(EngineStart start) => engineMain(
  start,
  onSupportWrites: (_) => throw const FileSystemException('store unreadable'),
);

/// An engine whose startup work fails unhandled after it hands over its
/// command port, before it answers [Hello].
void _failWhileStarting(EngineStart start) {
  start.uiPort.send(ReceivePort().sendPort);
  Future<void>(
    () => throw const FileSystemException('support directory unreadable'),
  );
}

/// An engine that completes the handshake and then meets an unhandled
/// error, which ends a spawned isolate.
void _dieAfterHello(EngineStart start) {
  final commands = ReceivePort();
  start.uiPort.send(commands.sendPort);
  commands.listen((_) {
    start.uiPort.send(const EngineReady(kEngineProtocolVersion));
    throw StateError('link table corrupt');
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

/// An engine that answers [Hello] and at once sends two events, as the
/// real one sends its startup fleet and preferences.
void _startupEvents(EngineStart start) {
  final commands = ReceivePort();
  start.uiPort.send(commands.sendPort);
  commands.listen((message) {
    if (message is Shutdown) {
      commands.close();
      return;
    }
    if (message is! Hello) return;
    start.uiPort
      ..send(const EngineReady(kEngineProtocolVersion))
      ..send(const EngineFault('one'))
      ..send(const EngineFault('two'));
  });
}

/// An engine that answers [Hello] and then nothing, not even Shutdown.
void _ignoreShutdown(EngineStart start) {
  final commands = ReceivePort();
  start.uiPort.send(commands.sendPort);
  commands.listen((message) {
    if (message is Hello) {
      start.uiPort.send(const EngineReady(kEngineProtocolVersion));
    }
  });
}
