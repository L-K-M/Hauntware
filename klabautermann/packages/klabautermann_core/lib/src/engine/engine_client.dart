import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

import 'engine_isolate.dart';
import 'protocol.dart';

/// How the app talks to the engine (03 §10.1, D18). Requests are plain data;
/// events arrive in engine order. Widget tests substitute a fake; production
/// uses [IsolateEngineClient].
abstract interface class EngineClient {
  /// Every [EngineEvent] the engine emits, in order. Broadcast so each
  /// concern's controller can subscribe its own slice (03 §10.1).
  Stream<EngineEvent> get events;

  /// Queues [request] for the engine.
  ///
  /// Throws [StateError] once [shutdown] ran.
  void send(EngineRequest request);

  /// Asks the engine to stop and waits for its isolate to exit. Idempotent.
  Future<void> shutdown();
}

/// [EngineClient] over a spawned engine isolate.
final class IsolateEngineClient implements EngineClient {
  IsolateEngineClient._(
    this._toEngine,
    this._isolate,
    this._fromEngine,
    this._exitPort,
    this._exited,
    this._events,
  );

  SendPort? _toEngine;
  final Isolate _isolate;
  final ReceivePort _fromEngine;
  final ReceivePort _exitPort;
  final Future<void> _exited;
  final StreamController<EngineEvent> _events;
  Future<void>? _shutdown;

  /// How long [shutdown] waits for a clean exit before killing the isolate.
  static const _shutdownTimeout = Duration(seconds: 2);

  /// Spawns the engine isolate and completes the [Hello]/[EngineReady]
  /// handshake, so a returned client is ready for feature requests.
  ///
  /// Throws [StateError] when the engine exits or refuses [Hello] before
  /// it is ready. [entryPoint] lets tests substitute a misbehaving engine.
  static Future<IsolateEngineClient> spawn({
    @visibleForTesting void Function(SendPort uiPort) entryPoint = engineMain,
  }) async {
    final fromEngine = ReceivePort('klabautermann engine events');
    final exitPort = ReceivePort('klabautermann engine exit');
    final isolate = await Isolate.spawn(
      entryPoint,
      fromEngine.sendPort,
      onExit: exitPort.sendPort,
    );

    // One receive port carries the isolate's whole life: first the
    // command-port handshake, then every EngineEvent.
    final handshake = Completer<SendPort>();
    final ready = Completer<void>();
    // A failed handshake leaves [ready] unawaited; mark its error handled.
    ready.future.ignore();
    final exited = Completer<void>();
    final events = StreamController<EngineEvent>.broadcast();
    final subscriptions = <StreamSubscription<Object?>>[
      fromEngine.listen((message) {
        if (message is SendPort) {
          handshake.complete(message);
          return;
        }
        if (message is! EngineEvent) return;

        // The first answer to Hello decides the handshake.
        if (!ready.isCompleted) {
          if (message is EngineReady) ready.complete();
          if (message is RequestRejected && message.requestName == 'Hello') {
            ready.completeError(
              StateError('engine refused Hello: ${message.reason}'),
            );
          }
        }
        events.add(message);
      }),
      exitPort.listen((_) {
        const reason = 'engine isolate exited before answering Hello';
        if (!handshake.isCompleted) {
          handshake.completeError(StateError(reason));
        }
        if (!ready.isCompleted) {
          ready.completeError(StateError(reason));
        }
        if (!exited.isCompleted) {
          exited.complete();
        }
        unawaited(events.close());
      }),
    ];

    try {
      final toEngine = await handshake.future;
      toEngine.send(const Hello());
      await ready.future;
      return IsolateEngineClient._(
        toEngine,
        isolate,
        fromEngine,
        exitPort,
        exited.future,
        events,
      );
    } catch (_) {
      isolate.kill();
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      fromEngine.close();
      exitPort.close();
      unawaited(events.close());
      rethrow;
    }
  }

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  void send(EngineRequest request) {
    final port = _toEngine;
    if (port == null) {
      throw StateError('the engine isolate is shut down');
    }
    port.send(request);
  }

  @override
  Future<void> shutdown() {
    return _shutdown ??= () async {
      final port = _toEngine;
      _toEngine = null;
      if (port != null) {
        port.send(const Shutdown());
      }
      try {
        await _exited.timeout(_shutdownTimeout);
      } on TimeoutException {
        _isolate.kill();
      }
      _fromEngine.close();
      _exitPort.close();
      await _events.close();
    }();
  }
}
