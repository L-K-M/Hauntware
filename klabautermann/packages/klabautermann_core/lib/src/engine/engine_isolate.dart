import 'dart:isolate';

import 'protocol.dart';

/// The engine isolate's entry point (03 D18): one isolate owns the SSH links,
/// samplers, parsers, Docker calls, sync and rule evaluation so the UI isolate
/// never blocks on a host.
///
/// [uiPort] is the client isolate's port. The engine first returns its
/// command port on it, then answers requests on the same port: [Hello] gets
/// [EngineReady], [Subscribe]/[Unsubscribe] update the (still silent) stub
/// sampler's bookkeeping, [Shutdown] exits, and every other 03 §10.1 row
/// gets [RequestRejected] until its milestone lands.
void engineMain(SendPort uiPort) {
  final commands = ReceivePort('klabautermann engine commands');
  uiPort.send(commands.sendPort);

  // The stub sampler's bookkeeping: which server ticks with which collectors
  // and cadence. It emits nothing yet (M1a); the fast/slow samplers of
  // 03 §6.2 fill this map's consumers in M2.
  final subscriptions = <String, Subscribe>{};

  commands.listen((message) {
    switch (message) {
      case Hello(:final protocolVersion):
        if (protocolVersion == kEngineProtocolVersion) {
          uiPort.send(const EngineReady(kEngineProtocolVersion));
        } else {
          uiPort.send(
            RequestRejected(
              'Hello',
              'protocol $protocolVersion; engine speaks '
                  '$kEngineProtocolVersion',
            ),
          );
        }
      case Subscribe():
        subscriptions[message.serverId] = message;
      case Unsubscribe():
        subscriptions.remove(message.serverId);
      case Shutdown():
        commands.close();
        Isolate.exit();
      case EngineRequest():
        uiPort.send(
          RequestRejected(
            message.runtimeType.toString(),
            'not implemented yet (M1a scaffold)',
          ),
        );
      default:
        uiPort.send(
          const RequestRejected(
            '<unknown>',
            'isolate message was not an EngineRequest',
          ),
        );
    }
  });
}
