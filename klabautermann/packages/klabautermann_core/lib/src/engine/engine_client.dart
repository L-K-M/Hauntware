import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'engine_isolate.dart';
import 'protocol.dart';

/// How the app talks to the engine (03 §10.1, D18). Requests are plain data;
/// events arrive in engine order. Widget tests substitute a fake; production
/// uses [IsolateEngineClient].
///
/// A client is one engine run: [events] closes when that engine stops, and
/// a restarted engine is a new client. The app's controllers keep per-run
/// state, such as the sample seq floor (D44), so they are built anew over
/// the new client rather than handed it, and the app's view remounts the
/// surfaces holding them.
abstract interface class EngineClient {
  /// Every [EngineEvent] the engine emits, in order. Broadcast so each
  /// concern's controller can subscribe its own slice (03 §10.1). Events
  /// that arrive before anything has listened, such as the fleet the
  /// engine starts with, are held for the first listener.
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
    this.ready,
    this._toEngine,
    this._isolate,
    this._fromEngine,
    this._exitPort,
    this._exited,
    this._events,
  );

  /// The engine's answer to [Hello], with what it met while starting, such
  /// as [EngineReady.importStoreIssue]. The handshake consumes it, so
  /// [events] never carries it.
  final EngineReady ready;

  SendPort? _toEngine;
  final Isolate _isolate;
  final ReceivePort _fromEngine;
  final ReceivePort _exitPort;
  final Future<void> _exited;
  final StreamController<EngineEvent> _events;
  Future<void>? _shutdown;

  /// How long [shutdown] waits for a clean exit before killing the isolate.
  static const _shutdownTimeout = Duration(seconds: 2);

  /// Spawns the engine isolate over [supportDirectory], the app's support
  /// directory where the engine keeps its files (03 §4.10), and completes
  /// the [Hello]/[EngineReady] handshake, so a returned client is ready
  /// for feature requests. [linksEnabled] turns on the engine's SSH links
  /// ([EngineStart.linksEnabled]); they stay off unless a caller asks, as
  /// do the reachability probes [probesEnabled] turns on
  /// ([EngineStart.probesEnabled]).
  /// [supportDirectoryAccess] lets it write its caches and sync
  /// ([EngineStart.supportDirectoryAccess]), and [deviceId] is the
  /// install's sync authorship id ([EngineStart.deviceId]).
  ///
  /// Throws [StateError] when the engine exits or refuses [Hello] before
  /// it is ready. [entryPoint] lets tests substitute a misbehaving engine.
  static Future<IsolateEngineClient> spawn({
    required String supportDirectory,
    bool linksEnabled = false,
    bool probesEnabled = false,
    SupportDirectoryAccess supportDirectoryAccess =
        SupportDirectoryAccess.unguarded,
    String? deviceId,
    @visibleForTesting void Function(EngineStart start) entryPoint = engineMain,
  }) async {
    final fromEngine = ReceivePort('klabautermann engine events');
    final exitPort = ReceivePort('klabautermann engine exit');
    final isolate = await Isolate.spawn(
      entryPoint,
      EngineStart(
        uiPort: fromEngine.sendPort,
        supportDirectory: supportDirectory,
        linksEnabled: linksEnabled,
        probesEnabled: probesEnabled,
        supportDirectoryAccess: supportDirectoryAccess,
        deviceId: deviceId,
      ),
      onExit: exitPort.sendPort,
    );

    // One receive port carries the isolate's whole life: first the
    // command-port handshake, then every EngineEvent.
    final handshake = Completer<SendPort>();
    final ready = Completer<EngineReady>();
    // A failed handshake leaves [ready] unawaited; mark its error handled.
    ready.future.ignore();
    final exited = Completer<void>();

    // The engine sends its startup fleet right after EngineReady, before
    // spawn's caller can have listened; a broadcast stream would drop it.
    // Events wait here until the first listener arrives, so the
    // composition root may await between spawn and its controllers. Only
    // that first listener gets them, so the controller that needs the
    // startup fleet must subscribe first. After that, events go out live
    // and, as on any broadcast stream, reach only the listeners present.
    List<EngineEvent>? held = [];
    late final StreamController<EngineEvent> events;
    events = StreamController<EngineEvent>.broadcast(
      onListen: () {
        final waiting = held;
        if (waiting == null) return;
        held = null;
        waiting.forEach(events.add);
      },
    );

    final subscriptions = <StreamSubscription<Object?>>[
      fromEngine.listen((message) {
        if (message is SendPort) {
          handshake.complete(message);
          return;
        }
        if (message is! EngineEvent) return;

        // The first answer to Hello decides the handshake and is not an
        // event for the app.
        if (!ready.isCompleted) {
          if (message is EngineReady) {
            ready.complete(message);
            return;
          }
          if (message is RequestRejected && message.requestName == 'Hello') {
            ready.completeError(
              StateError('engine refused Hello: ${message.reason}'),
            );
            return;
          }
        }
        if (held case final waiting?) {
          waiting.add(message);
        } else {
          events.add(message);
        }
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
      final answer = await ready.future;
      return IsolateEngineClient._(
        answer,
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
