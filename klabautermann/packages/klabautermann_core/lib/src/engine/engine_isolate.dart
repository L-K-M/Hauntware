import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../fleet/ssh_config_entries.dart';
import '../fleet/ssh_config_import_store.dart';
import '../sampling/subscriptions.dart';
import 'protocol.dart';

/// What the engine isolate starts with, sent once by `Isolate.spawn`
/// (D18): the port it answers on and the app's support directory, where it
/// keeps the files it owns (03 §4.10). Plain data; the app resolves the
/// directory through Flutter's `path_provider`, which this pure-Dart
/// package cannot reach.
@immutable
final class EngineStart {
  const EngineStart({required this.uiPort, required this.supportDirectory});

  /// The client isolate's port.
  final SendPort uiPort;

  /// The absolute path of the app's support directory.
  final String supportDirectory;
}

/// The engine isolate's entry point (03 D18): one isolate owns the SSH links,
/// samplers, parsers, Docker calls, sync and rule evaluation so the UI isolate
/// never blocks on a host.
///
/// [start] names the client isolate's port and the support directory. The
/// engine first returns its command port, then answers requests on the
/// client's port: [Hello] gets [EngineReady] and the fleet it started with
/// in a [CatalogReplaced], [Subscribe], [Unsubscribe] and
/// [SetCadenceProfile] update the sampling subscriptions (silently: no
/// sampler runs them yet), [ImportSshConfig] gets
/// [CatalogReplaced] and [SshConfigImported], [CloseStream] does nothing
/// (no log stream is open), [Shutdown] exits, and every other 03 §10.1
/// row, [OpenLogStream] included, gets [RequestRejected] until its
/// milestone lands.
void engineMain(EngineStart start) {
  final uiPort = start.uiPort;
  final commands = ReceivePort('klabautermann engine commands');
  uiPort.send(commands.sendPort);

  // Which streams each server's surfaces subscribed, and the cadence
  // profile (D45). Nothing samples them yet; the scheduler of 03 §6.4
  // reads them once the samplers are wired.
  final sampling = SamplingSubscriptions();

  // FL-02's imported entries, in D13's device-local store (03 §4.10),
  // opened before the first request is handled. Each import replaces the
  // last; the engine keeps them so its later fleet snapshots (sync rounds,
  // F3) carry them after the synced entries. The store hands them out
  // unmodifiable, so building a snapshot cannot edit them in place.
  late final SshConfigImportStore imports;

  Future<void> handle(Object? message) async {
    switch (message) {
      case Hello(:final protocolVersion):
        if (protocolVersion != kEngineProtocolVersion) {
          uiPort.send(
            RequestRejected(
              'Hello',
              'protocol $protocolVersion; engine speaks '
                  '$kEngineProtocolVersion',
            ),
          );
          return;
        }
        uiPort.send(
          EngineReady(kEngineProtocolVersion, importStoreIssue: imports.issue),
        );
        // The fleet as the engine starts: the imports an earlier run saved
        // (none when the store was empty or unusable), so the rail shows
        // them before the user does anything.
        uiPort.send(CatalogReplaced(imports.entries));
      case Subscribe():
        sampling.subscribe(message);
      case Unsubscribe():
        sampling.unsubscribe(message);
      case SetCadenceProfile(:final profile):
        sampling.profile = profile;
      case CloseStream():
        // Closing a stream that is not open does nothing (03 §10.1), and
        // none is: until the log service lands, OpenLogStream gets
        // RequestRejected, since no answer would leave its view waiting.
        break;
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
        // Saved before the fleet changes, so a restart after the answer
        // finds the import. A failed save still shows it for this run, and
        // the answer says it was not kept.
        final saved = await imports.replace(result.entries);
        // Synced entries lead this list once the catalog library lands (F3).
        uiPort.send(CatalogReplaced(imports.entries));
        uiPort.send(
          SshConfigImported(
            importedCount: result.entries.length,
            skippedCount: result.skippedCount,
            saved: saved,
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
  }

  // One request at a time, in arrival order, each to completion: an
  // import's save finishes before the next request runs, so answers keep
  // request order and saves never overlap, and nothing is handled before
  // the store is open.
  Future<void> queue =
      SshConfigImportStore.open(
        File(
          '${start.supportDirectory}${Platform.pathSeparator}'
          '$sshConfigImportsFileName',
        ),
      ).then((store) {
        imports = store;
      });
  commands.listen((message) {
    queue = queue.then((_) => handle(message));
  });
}
