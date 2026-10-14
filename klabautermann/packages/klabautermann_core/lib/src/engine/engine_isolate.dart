import 'dart:isolate';

import '../fleet/ssh_config_entries.dart';
import 'protocol.dart';

/// The engine isolate's entry point (03 D18): one isolate owns the SSH links,
/// samplers, parsers, Docker calls, sync and rule evaluation so the UI isolate
/// never blocks on a host.
///
/// [uiPort] is the client isolate's port. The engine first returns its
/// command port on it, then answers requests on the same port: [Hello] gets
/// [EngineReady], [Subscribe]/[Unsubscribe] update the (still silent) stub
/// sampler's bookkeeping, [ImportSshConfig] gets [CatalogReplaced] and
/// [SshConfigImported], [Shutdown] exits, and every other 03 §10.1 row
/// gets [RequestRejected] until its milestone lands.
void engineMain(SendPort uiPort) {
  final commands = ReceivePort('klabautermann engine commands');
  uiPort.send(commands.sendPort);

  // The stub sampler's bookkeeping: which server ticks with which collectors
  // and cadence. It emits nothing yet (M1a); the fast/slow samplers of
  // 03 §6.2 fill this map's consumers in M2.
  final subscriptions = <String, Subscribe>{};

  // FL-02's imported entries, held in memory only: D13's device-local
  // store arrives with the catalog library in a later PR, so a restarted
  // engine starts without them. Each import replaces the last; the engine
  // keeps them so its later fleet snapshots (sync rounds, F3) carry them
  // after the synced entries. The importer returns them unmodifiable, so
  // building a snapshot cannot edit this state in place.
  var imported = const <FleetEntry>[];

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
      case ImportSshConfig(:final text):
        final ({List<FleetEntry> entries, int skippedCount}) result;
        try {
          result = fleetEntriesFromSshConfig(text);
        } on Object catch (error) {
          // The importer is tolerant and is not expected to throw. If it
          // does, the engine answers rather than dying with every link.
          uiPort.send(
            RequestRejected('$ImportSshConfig', 'ssh_config import: $error'),
          );
          return;
        }
        imported = result.entries;
        // Synced entries lead this list once the catalog library lands (F3).
        uiPort.send(CatalogReplaced(imported));
        uiPort.send(
          SshConfigImported(
            importedCount: result.entries.length,
            skippedCount: result.skippedCount,
          ),
        );
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
